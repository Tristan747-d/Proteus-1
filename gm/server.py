"""OpenAI 兼容 HTTP 服务（stdlib，零第三方依赖）。

端点：
  GET  /healthz                健康检查
  GET  /v1/models              模型列表
  GET  /stats                  运行统计
  POST /v1/chat/completions    对话（stream: SSE / 非流式 JSON）
  POST /v1/completions         原始 prompt 补全
"""
from __future__ import annotations

import json
import logging
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
from typing import Any, Dict, Optional
from urllib.parse import urlparse

from .backends.base import Chunk, GenOptions
from .engine import ModelManager
from .registry import Registry

log = logging.getLogger("gm.server")


def _error_body(message: str, etype: str = "invalid_request_error") -> Dict[str, Any]:
    return {"error": {"message": message, "type": etype, "code": None}}


def _weight_name(path: str) -> str:
    """从权重路径取一个人类可读的名字（最后一节目录名）。

    同一路径的多条 entry 会得到同一个 weight_name —— 这正是界面用来判断
    「这两项其实是同一个模型」的依据。
    """
    try:
        return str(path).rstrip("/").split("/")[-1] or str(path)
    except Exception:
        return str(path)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "gm/0.1"

    # 注入项（partial）
    manager: ModelManager
    registry: Registry

    # ---- plumbing --------------------------------------------------------

    def log_message(self, fmt, *args):  # noqa: N802
        log.debug("%s - %s", self.address_string(), fmt % args)

    def _send_json(self, code: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> Optional[Dict[str, Any]]:
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n <= 0:
                return {}
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            self._send_json(400, _error_body("invalid JSON body"))
            return None

    def do_OPTIONS(self):  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- GET -------------------------------------------------------------

    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        m: ModelManager = self.manager
        if path == "/healthz":
            self._send_json(
                200,
                {
                    "status": "ok",
                    "service": "gm",
                    "models": m.registry.list_ids(),
                    "loaded": m.loaded_names(),
                },
            )
        elif path == "/v1/models":
            # 除 OpenAI 标准字段外，额外暴露两条「本网关特有」的信息，
            # 因为客户端无法从别处得知它们：
            #
            #   weight  —— 权重模型标识（config 里的 path）。
            #              同一个 weight 可以配成多条 entry（同一个 8B 权重，
            #              一条开投机、一条关，就产生两个 id）。GUI 要按
            #              「权重模型」分组选择，就必须能看出这一点，
            #              否则只能把所有 id 平铺成一个列表，把「换模型」
            #              和「换运行配置」混为一谈。
            #   params  —— 该 entry 的运行时参数，供界面显示当前跑的是哪套
            #              （投机是否开、nd、KV 位宽）。只读投影，不含路径
            #              之外的本机敏感信息 —— path 本来就是本机路径，
            #              而本服务只监听 127.0.0.1。
            data = [
                {
                    "id": e.name,
                    "object": "model",
                    "owned_by": "local",
                    "aliases": e.aliases,
                    "runtime": e.runtime,
                    "weight": e.path,
                    "weight_name": _weight_name(e.path),
                    "params": {
                        "speculative": bool(
                            ((e.params or {}).get("speculative") or {})
                            .get("enabled", False)),
                        "num_draft_tokens": int(
                            ((e.params or {}).get("speculative") or {})
                            .get("num_draft_tokens", 0) or 0),
                        "prefix_cache": bool(
                            ((e.params or {}).get("prefix_cache") or {})
                            .get("enabled", False)),
                        "kv_bits": int(
                            ((e.params or {}).get("prefix_cache") or {})
                            .get("kv_bits", 0) or 0),
                    },
                }
                for e in m.registry.entries
            ]
            self._send_json(200, {"object": "list", "data": data})
        elif path == "/stats":
            self._send_json(200, m.stats())
        else:
            self._send_json(404, _error_body(f"no such endpoint: {path}"))

    # ---- POST ------------------------------------------------------------

    def do_POST(self):  # noqa: N802
        path = urlparse(self.path).path.rstrip("/")
        if path == "/v1/chat/completions":
            self._chat_completions()
        elif path == "/v1/completions":
            self._completions()
        else:
            self._send_json(404, _error_body(f"no such endpoint: {path}"))

    def _session_key(self, body: Dict[str, Any]) -> str:
        """跨请求 prefix cache 的会话键。

        OpenAI 兼容接口没有这个概念，gm 从三处取，优先请求体：
          body.session / body.user / HTTP 头 X-Session-Id
        取不到就返回 ""，此时 prefix cache 不复用（不同用户不会串号）。
        """
        for key in ("session", "session_id", "user"):
            v = body.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
        hdr = self.headers.get("X-Session-Id") if hasattr(self, "headers") else None
        if isinstance(hdr, str) and hdr.strip():
            return hdr.strip()
        return ""

    def _gen_options(self, body: Dict[str, Any], entry) -> GenOptions:
        return GenOptions(
            max_tokens=int(body.get("max_tokens") or 512),
            temperature=float(body.get("temperature", 0.7)),
            top_p=float(body.get("top_p", 1.0)),
            top_k=int(body.get("top_k") or 0),
            repetition_penalty=body.get("repetition_penalty"),
            stop=[str(s) for s in (body.get("stop") or []) if s]
            if isinstance(body.get("stop"), list)
            else ([str(body["stop"])] if body.get("stop") else []),
            seed=body.get("seed"),
            abort=threading.Event(),
            session=self._session_key(body),
        )

    def _chat_completions(self) -> None:
        body = self._read_json()
        if body is None:
            return
        try:
            entry, backend = self.manager.backend_for(body.get("model"))
        except KeyError as e:
            self._send_json(404, _error_body(str(e.args[0])))
            return
        messages = body.get("messages")
        if not isinstance(messages, list) or not messages:
            self._send_json(400, _error_body("messages must be a non-empty list"))
            return
        opts = self._gen_options(body, entry)
        req_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
        created = 0  # 占位，下面统一取
        import time as _t

        created = int(_t.time())
        stream = bool(body.get("stream", False))

        if not stream:
            try:
                with self.manager.gen_lock:
                    chunks = []
                    for c in backend.chat_stream(messages, opts):
                        chunks.append(c.text)
                    text = "".join(chunks)
                    meta = getattr(backend, "last_meta", None)
            except ValueError as e:
                self._send_json(400, _error_body(str(e)))
                return
            except Exception as e:  # noqa: BLE001
                log.exception("generation failed")
                self._send_json(500, _error_body(str(e), "internal_error"))
                return
            self.manager.last_meta = {
                "prompt_tokens": meta.prompt_tokens,
                "completion_tokens": meta.completion_tokens,
                "tps": round(meta.tps, 2),
                "finish_reason": meta.finish_reason,
                "speculative": getattr(meta, "speculative", False),
                "num_draft_tokens": getattr(meta, "num_draft_tokens", 0),
                "accept_rule": getattr(meta, "accept_rule", "exact"),
                "prefix_cached_tokens": getattr(meta, "prefix_cached_tokens", 0),
                **meta.latency_stats(),
            }
            self._send_json(
                200,
                {
                    "id": req_id,
                    "object": "chat.completion",
                    "created": created,
                    "model": entry.name,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": text},
                            "finish_reason": meta.finish_reason,
                        }
                    ],
                    "usage": {
                        "prompt_tokens": meta.prompt_tokens,
                        "completion_tokens": meta.completion_tokens,
                        "total_tokens": meta.prompt_tokens + meta.completion_tokens,
                    },
                },
            )
            return

        # ---- SSE 流式 ----
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        def sse(payload: Dict[str, Any]) -> bytes:
            return b"data: " + json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n\n"

        try:
            with self.manager.gen_lock:
                first = True
                for c in backend.chat_stream(messages, opts):
                    delta: Dict[str, Any] = {"content": c.text} if c.text else {}
                    if first:
                        delta = {"role": "assistant", **delta}
                        first = False
                    chunk = {
                        "id": req_id,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": entry.name,
                        "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
                    }
                    # 注意：ITL 平滑不在这里做。backend 会把同一轮的多 token
                    # 合并成一个 chunk 交上来，在这一层 sleep 只会「延迟一个
                    # 已经包含 3 个 token 的包」，实测把 p95 从 63ms 推到 316ms。
                    # 正确位置是 backend 内部、逐 token 交付之前。
                    self.wfile.write(sse(chunk))
                    self.wfile.flush()
                meta = getattr(backend, "last_meta", None)
            final = {
                "id": req_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": entry.name,
                "choices": [
                    {
                        "index": 0,
                        "delta": {},
                        "finish_reason": meta.finish_reason if meta else "stop",
                    }
                ],
            }
            self.wfile.write(sse(final))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            if meta:
                self.manager.last_meta = {
                    "prompt_tokens": meta.prompt_tokens,
                    "completion_tokens": meta.completion_tokens,
                    "tps": round(meta.tps, 2),
                    "finish_reason": meta.finish_reason,
                    "speculative": getattr(meta, "speculative", False),
                    "num_draft_tokens": getattr(meta, "num_draft_tokens", 0),
                    "accept_rule": getattr(meta, "accept_rule", "exact"),
                    "prefix_cached_tokens": getattr(meta, "prefix_cached_tokens", 0),
                }
                self.manager.last_meta.update(meta.latency_stats())
        except (BrokenPipeError, ConnectionResetError):
            opts.abort.set()
            log.info("client disconnected, generation aborted")
        except Exception as e:  # noqa: BLE001
            log.exception("stream failed")
            try:
                self.wfile.write(sse({"error": str(e)}))
            except Exception:
                pass

    def _completions(self) -> None:
        body = self._read_json()
        if body is None:
            return
        try:
            entry, backend = self.manager.backend_for(body.get("model"))
        except KeyError as e:
            self._send_json(404, _error_body(str(e.args[0])))
            return
        prompt = body.get("prompt")
        if not isinstance(prompt, str) or not prompt:
            self._send_json(400, _error_body("prompt must be a non-empty string"))
            return
        opts = self._gen_options(body, entry)
        try:
            with self.manager.gen_lock:
                text = "".join(c.text for c in backend.raw_stream(prompt, opts))
                meta = getattr(backend, "last_meta", None)
        except ValueError as e:
            self._send_json(400, _error_body(str(e)))
            return
        except Exception as e:  # noqa: BLE001
            log.exception("generation failed")
            self._send_json(500, _error_body(str(e), "internal_error"))
            return
        self._send_json(
            200,
            {
                "id": f"cmpl-{uuid.uuid4().hex[:12]}",
                "object": "text_completion",
                "model": entry.name,
                "choices": [{"index": 0, "text": text, "finish_reason": meta.finish_reason}],
                "usage": {
                    "prompt_tokens": meta.prompt_tokens,
                    "completion_tokens": meta.completion_tokens,
                    "total_tokens": meta.prompt_tokens + meta.completion_tokens,
                },
            },
        )


def make_server(registry: Registry, manager: ModelManager):
    """多线程 HTTP server。

    为什么必须是多线程（2026-09-16 实测修正）
    ----------------------------------------
    这里原先是单线程 HTTPServer，理由是「生成要落在同一线程，否则 MLX 的
    KV cache 跨线程会抛 no Stream(gpu,1)」。

    但这个理由已经被 `manager.gen_lock` 完全覆盖 —— 所有生成路径都在
    `with self.manager.gen_lock:` 里跑，同一时刻只有一个前向。
    于是单线程 HTTP 带来的**额外**后果纯粹是坏处：

        · 一次 SSE 流式请求会独占唯一的处理线程几十秒；
        · 期间的 /stats、/v1/models 全部卡在 accept 队列里；
        · 长流式（实测 120 token、200 秒）进行时，任何并发探测都超时
          （实测 HTTP 000 / 15s 超时 ×3）。
        · GUI 每几秒轮询 /stats 判断网关存活 → 全部超时 → 显示「网关离线」，
          而网关其实一直好好地跑着。这就是用户报的「一次对话后自动离线」。

    改回 ThreadingHTTPServer 后：连接处理并发、生成仍由 gen_lock 串行，
    两个目标同时满足。daemon_threads=True 保证退出时不被连接线程拖住。
    """
    handler = type(
        "BoundHandler",
        (Handler,),
        {"manager": manager, "registry": registry},
    )
    srv = ThreadingHTTPServer(
        (registry.server.host, registry.server.port), handler)
    srv.daemon_threads = True
    # 允许端口快速重用，避免重启时偶发 "Address already in use"。
    srv.allow_reuse_address = True
    return srv
