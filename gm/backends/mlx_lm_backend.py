"""mlx_lm 推理后端（v1 内置）。

用系统 python 环境的 mlx / mlx_lm 进程内加载 MLX 权重并生成。
"""
from __future__ import annotations

import threading
import time
from typing import Iterator, List

from .base import Backend, Chunk, GenMeta, GenOptions
from ..registry import ModelEntry

SAMPLE_ARGS_CANDIDATES = ("temp", "top_p", "top_k", "repetition_penalty")


class MlxLmBackend(Backend):
    def __init__(self, entry: ModelEntry):
        super().__init__(entry)
        self.model = None
        self.tokenizer = None
        # 推测解码（speculative decoding）状态。
        # 由 models.json 的 params.speculative 驱动，缺省关闭。
        # {"enabled": true, "draft_model": "...", "num_draft_tokens": 4}
        self.draft_model = None
        self._spec_cfg = self._read_spec_cfg(entry)
        # 投机解码被禁用的原因（None = 正常）。tokenizer 不兼容、draft 加载
        # 失败等都会写到这里，并经 spec_status() 暴露给 /stats。
        self._spec_error = None
        # 跨请求 prefix（KV）cache。见 gm/backends/prefix_cache.py 的实据：
        # 多轮对话下 TTFT 5.7-6.2x、墙钟 2.9-3.1x（两轮独立 campaign）。
        self._prefix_cfg = self._read_prefix_cfg(entry)
        self._prefix_store = None

    @staticmethod
    def _read_spec_cfg(entry: ModelEntry) -> dict:
        raw = (entry.params or {}).get("speculative") or {}
        if not isinstance(raw, dict):
            raw = {}
        enabled = bool(raw.get("enabled", False))
        return {
            "enabled": enabled,
            "draft_model": raw.get("draft_model"),
            "num_draft_tokens": int(raw.get("num_draft_tokens", 2)),
            # 高温下用更短的草稿（实测：temp=0.7 且 nd=4 是 0.904x 负收益，
            # 但 nd=1/2 两轮 campaign 均 >=1.10）。0 或缺省 = 不区分温度。
            "num_draft_tokens_high_temp": int(
                raw.get("num_draft_tokens_high_temp", 2)),
            # 温度闸门。>0 表示仍启用（只切 n_draft）；<=0 表示高温完全关闭。
            # 见 _spec_enabled_for 的实测依据。
            "max_temp": float(raw.get("max_temp", 0.5)),
            # 接受规则："exact"（mlx_lm 原生，精确匹配）或
            # "rejection"（Leviathan 拒绝采样）。两者都保分布，
            # 但 rejection 接受率更高 —— 见 gm/backends/spec_rejection.py
            # 顶部注释的实据。默认 exact，`rejection` 作为 opt-in。
            "accept_rule": str(raw.get("accept_rule", "exact")).lower(),
            # 长上下文下收敛草稿长度的阈值（prompt token 数）。0 = 关闭。
            "long_ctx_tokens": int(raw.get("long_ctx_tokens", 0) or 0),
        }

    @staticmethod
    def _read_prefix_cfg(entry: ModelEntry) -> dict:
        """跨请求 prefix cache 配置，缺省关闭。

        {"enabled": true, "max_sessions": 8}

        kv_bits / kv_group_size 控制 KV cache 量化（TTFT 与长上下文 TPOT 的
        正交杠杆）。缺省 0 = 不量化，保持现网行为。
        """
        raw = (entry.params or {}).get("prefix_cache") or {}
        if not isinstance(raw, dict):
            raw = {}
        return {
            "enabled": bool(raw.get("enabled", False)),
            "max_sessions": int(raw.get("max_sessions", 8)),
            "kv_bits": int(raw.get("kv_bits", 0) or 0),
            # 所有会话缓存加起来允许占用的 token 总量（KV 字节 ∝ token 数）。
            # 只限会话条数不限长度会让长上下文把内存吃爆（实测 12GB）。
            "max_total_tokens": int(raw.get("max_total_tokens", 16384) or 0),
            "kv_group_size": int(raw.get("kv_group_size", 64) or 64),
            # 跨 session 共享公共前缀（TTFT 杠杆）。缺省 false。
            # shared_max_tokens=0 时即使 shared=true 也不共享（安全缺省）。
            "shared": bool(raw.get("shared", False)),
            "shared_slots": int(raw.get("shared_slots", 2) or 2),
            "shared_max_tokens": int(raw.get("shared_max_tokens", 0) or 0),
        }

    def _make_kv_cache(self):
        """按配置构造 KV cache（target + 可选 draft，可选量化）。

        ⚠️ 关键：投机解码路径下，传给 stream_generate 的 `prompt_cache` 是一个
        **合并列表**，mlx_lm 内部这样切分（generate.py `speculative_generate_step`）：

            model_cache = prompt_cache[: len(model.layers)]
            draft_cache = prompt_cache[len(model.layers):]

        所以列表必须 = [target 的 32 层] + [draft 的 N 层]。只给 target 的
        32 层会让 draft_cache 为空，draft 前向立刻 IndexError
        （`cache[self.fa_idx]`，实测踩到）。非投机路径则只给 target 层。

        KV 量化是唯一「不改权重、纯减字节」的 TTFT/长上下文杠杆：decode 已顶
        DRAM 屋顶线，而 KV 是这条字节账里最后一项未攻项。

            ctx=8192  KV 占总字节 11-19%，  结构预测 ~1.095x
            ctx=32768 KV 占 49%，           收益更大
            ctx=1024  KV 占 2.6%，          仅 1.013x（可忽略）

        质量侧实测无损（`kv_quant_ab.json`：两个上下文、6 对全部 token 与
        fp16-KV 参考 100% 逐一致，logprob 漂移 0.0010-0.0011）。

        ⚠️ 速度侧尚无可信实测：此前那轮因宿主 swap 13.4/14.3 GB 作废，按项目
        铁律（内存压力可污染 3-11x）必须重做。故该项**默认关闭**，绝不可把
        未验证收益当既成事实。
        """
        from mlx_lm.models.cache import make_prompt_cache

        bits = int(self._prefix_cfg.get("kv_bits", 0) or 0)
        if bits <= 0:
            caches = make_prompt_cache(self.model)
            if self.draft_model is not None:
                # 合并列表：target 层在前，draft 层在后（见上面的切分逻辑）。
                caches = caches + make_prompt_cache(self.draft_model)
            return caches

        from mlx_lm.models.cache import QuantizedKVCache

        gs = int(self._prefix_cfg.get("kv_group_size", 64) or 64)
        caches = [QuantizedKVCache(group_size=gs, bits=bits)
                  for _ in range(len(self.model.layers))]
        if self.draft_model is not None:
            caches += [QuantizedKVCache(group_size=gs, bits=bits)
                       for _ in range(len(self.draft_model.layers))]
        return caches

    def _spec_enabled_for(self, opts: GenOptions) -> bool:
        """温度闸门：决定本次请求是否启用推测解码。

        2026-09-13 夜修订：原来的「temp>0.5 直接关闭」被证明是过度保守。
        旧结论（nd=4、160 token）确实测到高温负收益：

            temp 0.0 -> 1.126x    temp 0.3 -> 1.181x
            temp 0.7 -> 0.904x    temp 1.0 -> 0.941x

        但那是在 num_draft_tokens=4 下测的。重扫后发现 temp=0.7 下
        nd=1/2 两轮 campaign 均为正收益（1.101/1.140 与 1.140/1.155）。
        即「高温负收益」是 nd 选错，不是温度本身的问题。

        因此闸门语义改为：max_temp > 0 时高温**仍然启用**，只是换成更短的
        草稿（num_draft_tokens_high_temp）；只有 max_temp <= 0 才真正关闭。
        """
        if self.draft_model is None:
            return False
        if not self._spec_cfg["enabled"]:
            return False
        try:
            temp = float(opts.temperature)
        except (TypeError, ValueError):
            return False
        # max_temp <= 0 表示高温完全关闭（保留旧行为的方式）。
        if self._spec_cfg["max_temp"] <= 0:
            return False
        return True

    def _spec_ndraft_for(self, opts: GenOptions) -> int:
        """按温度选择草稿长度（实测依据见下）。

        2026-09-13 夜，M5，target=Llama-3.1-8B-4bit，
        draft=Llama-3.2-1B-4bit（同 tokenizer），200 token，
        6 对/campaign，配对 + 顺序翻转，两轮独立 campaign：

            greedy (temp=0)  nd=2 -> 1.490 / 1.247   (胜 6/6, 5/6)
                             nd=4 -> 1.289 / 1.127   (胜 5/6, 5/6)
                             nd=6 -> 0.899           (胜 1/6)
                             nd=8 -> 0.796           (胜 1/6)
            temp=0.7         nd=1 -> 1.101 / 1.140   (胜 5/6, 6/6)
                             nd=2 -> 1.140 / 1.155   (胜 4/6, 6/6)
                             nd=4 -> 0.989 / 1.075   (胜 3/6, 4/6)

        两条结论：
          1) 最优点在 nd=2，不是网关此前用的 nd=4（草稿换血前的遗留值）；
          2) 接受率随 nd 单调升（0.59 -> 0.77）但提速单调降 —— 草稿变长的
             边际收益抵不过每轮 1B 草稿前向的固定成本。

        2026-09-15 补充（rejection 规则下重扫，proteus24，
        `spec_rejection_c{1,2,3}.json`，temp=0.7）：

            nd=3 -> 1.210 / 1.249 / 1.167   (rejection)
            nd=2 -> 1.181 / 1.192

        rejection 的接受率更高，把 nd 最优点从 2 抬到 3。因此分流应为：

            低温（<= max_temp）: nd = num_draft_tokens          （= 3）
            高温（>  max_temp）: nd = num_draft_tokens_high_temp （= 2）

        此前两个值都是 3，等于没有按温度分流。高温必须回落到更短草稿：
        高温下草稿分布偏离 target 更远、长草稿拒绝率上升。
        """
        base = self._spec_cfg["num_draft_tokens"]
        high = self._spec_cfg["num_draft_tokens_high_temp"]
        if high <= 0:
            return base
        try:
            temp = float(opts.temperature)
        except (TypeError, ValueError):
            return base
        if temp > self._spec_cfg["max_temp"]:
            return high
        return base

    def _spec_ndraft_for_ctx(self, opts: GenOptions, ctx_tokens: int) -> int:
        """在温度分流之上，再按上下文长度收敛草稿长度。

        动机（结构性，非猜测）：每个 verify round 的成本 = 一次 8B 前向
        （权重 4.517 GB 固定）+ 一次 KV 读取（随 ctx 线性增长）。ctx=8192 时
        KV 已占总字节 11-19%（`kv_quant_ab.json`），ctx=32768 占 49%。即
        「每轮固定成本」本身随上下文变大，而每轮接受数不同步上升，所以长
        上下文下更长的草稿净收益递减。

        保守且可回退：仅在显式配置 `long_ctx_tokens` 时生效
        （缺省 0 = 关闭），避免在没有实测支撑时改变现网行为。
        """
        nd = self._spec_ndraft_for(opts)
        thresh = int(self._spec_cfg.get("long_ctx_tokens", 0) or 0)
        if thresh > 0 and ctx_tokens >= thresh and nd > 2:
            return 2
        return nd

    # ---- lifecycle -------------------------------------------------------

    def spec_status(self) -> dict:
        """投机解码的实际启用状态（供 /stats 观测）。

        动机：换 target 模型时，tokenizer 不兼容会被闸门拦下并退回普通解码。
        这个退回是**安全的但静默的** —— 如果没有可观测出口，运维只会看到
        「换了模型之后变慢了」而不知道原因。所以把判定结果显式暴露出来。
        """
        return {
            "configured": bool(self._spec_cfg.get("enabled")
                               and self._spec_cfg.get("draft_model")),
            "active": self.draft_model is not None,
            "draft_model": self._spec_cfg.get("draft_model"),
            "accept_rule": self._spec_cfg.get("accept_rule"),
            "num_draft_tokens": self._spec_cfg.get("num_draft_tokens"),
            "num_draft_tokens_high_temp": self._spec_cfg.get(
                "num_draft_tokens_high_temp"),
            "disabled_reason": getattr(self, "_spec_error", None),
        }

    def load(self) -> None:
        if self._loaded:
            return
        import mlx.core as mx  # noqa: 延迟导入，未装 mlx 时其余功能仍可用
        from mlx_lm import load

        path = str(self.entry.resolve_path())
        self.model, self.tokenizer = load(path)

        # 草稿模型：仅当配置启用且路径可用时加载；失败则静默退回普通解码，
        # 绝不让一个可选优化把整个网关拖挂。
        if self._spec_cfg["enabled"] and self._spec_cfg["draft_model"]:
            try:
                self.draft_model, draft_tok = load(str(self._spec_cfg["draft_model"]))
            except Exception as exc:  # pragma: no cover - 环境相关
                self.draft_model = None
                self._spec_error = str(exc)
            else:
                # ---- tokenizer 兼容性闸门（必需，不是可选优化）------------
                # spec_rejection / mlx_lm 原生投机路径都直接用 draft 产出的
                # token id 去喂 target 前向。若两者不在同一 token id 空间，
                # id 的语义就是错的 —— 那不是「变慢」，是「输出错乱」。
                #
                # 实测依据（proteus24, PROTEUS_FINAL_TECHNICAL_REPORT §3.3）：
                #   Qwen2.5-0.5B 配 Llama target（异 tokenizer，vocab 151643
                #   vs 128256）测得 1.49x；换同 tokenizer 的 Llama-3.2-1B 后
                #   1.86x。关键是异 tokenizer 时**没有报错**，只是静默变慢/
                #   错乱 —— 换模型的人不会收到任何信号。因此必须显式拦截。
                ok, why = _tokenizers_compatible(self.tokenizer, draft_tok)
                if not ok:
                    self.draft_model = None
                    self._spec_error = f"tokenizer incompatible: {why}"
        self._loaded = True

    def unload(self) -> None:
        if not self._loaded:
            return
        import mlx.core as mx

        self.model = None
        self.tokenizer = None
        self.draft_model = None
        self._loaded = False
        try:
            mx.metal.clear_cache()
        except Exception:
            pass

    # ---- helpers ---------------------------------------------------------

    def _encode_chat(self, messages: List[dict]) -> List[int]:
        msgs = [_flatten_message(m) for m in messages]
        if not msgs:
            raise ValueError("messages is empty")
        return self.tokenizer.apply_chat_template(msgs, add_generation_prompt=True)

    # ---- prefix cache helpers -------------------------------------------

    @staticmethod
    def _prefix_key(opts: GenOptions) -> str:
        """按 session 键控。没有显式 session 时不做跨请求复用——
        否则不同用户的对话会互相命中，那是正确性事故。"""
        for attr in ("session", "session_id", "user"):
            v = getattr(opts, attr, None)
            if v:
                return str(v)
        return ""

    def _prefix_get(self, key, prompt_ids):
        if self._prefix_store is None:
            self._prefix_store = self._make_prefix_store()
        # session 键为空时给一个占位键，让共享槽仍然可用：旧行为是
        # 「key 为空 -> 永不复用」，而 session 缺省就是空，等于线上前缀
        # 缓存默认失效（每个新会话 100% 重 prefill 整段 system prompt）。
        k = key or "__shared_default__"
        return self._prefix_store.get(k, list(prompt_ids))

    def _prefix_put(self, key, cache, full_ids):
        if self._prefix_store is None:
            self._prefix_store = self._make_prefix_store()
        self._prefix_store.put(key or "__shared_default__", cache, full_ids)

    def _make_prefix_store(self):
        """按配置构造前缀缓存存储。

        shared=true 时用 SharedPrefixCacheStore：在 session 精确键之外再匹配
        「逐 token 相同的公共前缀」，使新会话也能复用 system prompt 那一段
        ——这是 TTFT 里最大的一块可消除重复 prefill。

        ⚠️ 缺省 false，且**不建议在未设 shared_max_tokens 时开启**：不限长的
        跨 session 复用会把上一个会话的对话内容带进新会话（已实测复现：
        A 会话存密码、B 会话提问，B 直接答出密码）。见 prefix_cache.py。
        """
        if self._prefix_cfg.get("shared"):
            from .prefix_cache import SharedPrefixCacheStore

            return SharedPrefixCacheStore(
                max_sessions=self._prefix_cfg["max_sessions"],
                shared_slots=int(self._prefix_cfg.get("shared_slots", 2) or 2),
                max_shared_tokens=int(
                    self._prefix_cfg.get("shared_max_tokens", 0) or 0),
                max_total_tokens=self._prefix_cfg.get("max_total_tokens", 16384),
            )
        from .prefix_cache import PrefixCacheStore

        return PrefixCacheStore(self._prefix_cfg["max_sessions"])

    def _make_sampler(self, opts: GenOptions):
        from mlx_lm.sample_utils import make_sampler

        kwargs = {
            "temp": float(opts.temperature),
            "top_p": float(opts.top_p),
        }
        if opts.top_k and opts.top_k > 0:
            kwargs["top_k"] = int(opts.top_k)
        if opts.repetition_penalty is not None:
            kwargs["repetition_penalty"] = float(opts.repetition_penalty)
        try:
            return make_sampler(**kwargs)
        except TypeError:
            # 老版 mlx_lm 不认识个别参数时逐级退化
            for drop in ("repetition_penalty", "top_k"):
                kwargs.pop(drop, None)
            return make_sampler(**kwargs)

    def _stream_ids(
        self, prompt_ids: List[int], opts: GenOptions, meta: GenMeta
    ) -> Iterator[Chunk]:
        import mlx.core as mx
        from mlx_lm.generate import stream_generate

        cap = max(1, min(int(opts.max_tokens), self.entry.max_output_tokens))
        meta.prompt_tokens = len(prompt_ids)
        # 延迟埋点起点：用户在等的是「请求发出 -> 首字可见」。
        req_t0 = time.time()
        last_chunk_t = req_t0
        first_chunk_seen = False

        def _mark(text: str):
            """交付一个 chunk，并记录 TTFT/ITL。

            首 chunk 的到达时刻 = TTFT（剩余 prefill + 首个 decode step）。
            之后每个 chunk 的到达间隔 = ITL 的一个样本。

            """
            nonlocal last_chunk_t, first_chunk_seen
            now = time.time()
            if not first_chunk_seen:
                meta.ttft_s = now - req_t0
                meta.prefill_s = meta.ttft_s
                first_chunk_seen = True
            else:
                meta.itl_ms.append((now - last_chunk_t) * 1000.0)
            last_chunk_t = now
            return Chunk(text=text)

        if opts.seed is not None:
            try:
                mx.random.seed(int(opts.seed))
            except Exception:
                pass

        sampler = self._make_sampler(opts)
        stops = [s for s in (opts.stop or []) if s]
        stop_hold = max((len(s) for s in stops), default=0)
        buf = ""
        emitted = 0
        finish = "length"
        t0 = time.time()
        # ---- 跨请求 prefix cache ----------------------------------------
        # 命中时只把「未缓存后缀」喂给 stream_generate（见 prefix_cache.py：
        # mlx_lm 会把你给的 prompt 全部 prefill，传全量等于没省）。
        prefix_key = self._prefix_key(opts)
        feed_ids = prompt_ids
        pcache = None
        prefix_hit = 0
        cached_obj = None  # 本次生成实际用的 cache（命中=复用/未命中=新建）
        if self._prefix_cfg["enabled"] and prefix_key:
            try:
                pcache, feed_ids, prefix_hit = self._prefix_get(prefix_key, prompt_ids)
            except Exception as exc:
                # 缓存是纯优化：任何异常都必须退回全量 prompt，绝不污染输出
                pcache, feed_ids, prefix_hit = None, prompt_ids, 0
                self._spec_error = f"prefix cache get failed: {exc}"
            # ⚠️ 必须至少留 1 个 token 给下游：缓存全覆盖时 feed_ids 为空，
            # 而 mlx_lm 的 prefill 会把它 reshape 成空数组并报
            # `[reshape] Cannot infer the shape of an empty array`（实测）。
            # 回退 1 个 token 只重算最后一个位置，代价可忽略，却保证
            # 「完全命中」不会变成 400。
            if not feed_ids:
                if prefix_hit > 0:
                    feed_ids = list(prompt_ids[-1:])
                    prefix_hit -= 1
                else:
                    feed_ids = list(prompt_ids)
        meta.prefix_cached_tokens = prefix_hit

        gen_kwargs = {}
        use_spec = self._spec_enabled_for(opts)
        meta.speculative = use_spec
        nd = (
            self._spec_ndraft_for_ctx(opts, len(feed_ids)) if use_spec else 0
        )
        if use_spec:
            gen_kwargs["draft_model"] = self.draft_model
            gen_kwargs["num_draft_tokens"] = nd
        meta.num_draft_tokens = nd

        # 交给本次生成的 cache（命中=复用，未命中=新建，生成后回存）。
        # 必须在 gen_kwargs 初始化之后设置，否则会被覆盖。
        if self._prefix_cfg["enabled"] and prefix_key:
            if pcache is not None:
                gen_kwargs["prompt_cache"] = pcache
                cached_obj = pcache
            else:
                try:
                    cached_obj = self._make_kv_cache()
                    gen_kwargs["prompt_cache"] = cached_obj
                except Exception as exc:  # pragma: no cover
                    cached_obj = None
                    self._spec_error = f"prefix cache create failed: {exc}"

        # 拒绝采样路径（opt-in，见 models.json 的 accept_rule）。
        # 它输出 token id 而非 text，所以这里用 id 解码并重做 stop 匹配。
        use_rejection = (
            use_spec
            and self._spec_cfg.get("accept_rule") == "rejection"
            and self.draft_model is not None
        )
        if use_rejection:
            meta.accept_rule = "rejection"
            try:
                from .spec_rejection import stream_rejection

                # EOS 集合：命中即停且不把 EOS 文本吐出去。原生路径由
                # stream_generate 内部处理，这条分支必须自己处理。
                try:
                    eos_ids = set(self.tokenizer.eos_token_ids or [])
                except Exception:
                    eos_ids = set()
                if not eos_ids:
                    for attr in ("eos_token_id", "eos_id"):
                        v = getattr(self.tokenizer, attr, None)
                        if isinstance(v, int):
                            eos_ids.add(v)
                        elif isinstance(v, (list, tuple)):
                            eos_ids.update(int(x) for x in v)

                hit_stop = False
                # round_stats 必须在调用前初始化：下面 line ~598 会读它，
                # 而它原先只在 except 分支里被赋值 —— 一旦 stream_rejection
                # 正常返回（或中途 raise 后走到别的分支），读取处就会命中
                # UnboundLocalError。实测（2026-09-16）表现是：rejection 路径
                # 每个请求都抛 "cannot access local variable 'round_stats'"
                # 并静默回落到原生 exact 路径 —— 等于拒绝采样从未真正生效，
                # 而 /stats 里只看得到一个含糊的 disabled_reason。
                round_stats: List[dict] = []
                # ⚠️ 中文乱码（�）的根因与修法 ----------------------------
                # Llama 的 byte-level BPE 词表里存在**字节碎片** token，例如
                # id=33443 单独 decode 得到 U+FFFD（�）。它只是某个中文字符
                # UTF-8 编码的一部分，必须与**相邻** token 的字节拼起来才是
                # 完整字符。
                #
                # 实测（2026-09-17，id 序列 [116685,112086,248,45826,106,33443]）：
                #     decode(all)  = '浩瀚壮�'      ← 整段解码**仍**会带 �
                #     逐 token 拼接 = '浩�����'      ← 更糟
                # 因为 33443 是个**落单的**字节片段：前面的 token 已构成完整
                # 字符，它没有可配对的邻居。整段解码并不能救它。
                #
                # 所以正确的修法是**暂扣不完整的尾部**：
                #   · 保留已产出的 token id，每次解码整个序列；
                #   · 若解码结果以 U+FFFD 结尾，说明末尾字节还不完整（也可能
                #     它永远补不齐），此时**先不交付**这一小段；
                #   · 等后续 token 到来再一起解码——若补上了就正常交付，
                #     始终补不齐则这一两个字节被丢弃。
                # 效果：宁可少一两个字节，也不把 � 写给用户。
                # 这与 mlx_lm 原生路径的 detokenizer 行为一致（它也做增量
                # 拼接），但原生路径同样会在落单字节上吐出 �，因此这里更严。
                gen_ids: List[int] = []

                def _text_of(all_ids: List[int]) -> str:
                    """解码整个已生成序列。

                    返回值可能以 U+FFFD 结尾 —— 调用方负责暂扣（见上）。
                    """
                    try:
                        return self.tokenizer.decode(all_ids)
                    except Exception:
                        # 极端情况下退回逐 token 拼接，至少不中断生成
                        return "".join(self.tokenizer.decode([i]) for i in all_ids)



                for tid, _ in stream_rejection(
                    self.model, self.draft_model, feed_ids, cap,
                    float(opts.temperature), nd,
                    seed=(int(opts.seed) if opts.seed is not None else None),
                    abort=opts.abort,
                    prompt_cache=cached_obj,
                    round_stats=round_stats,
                ):
                    if opts.abort is not None and opts.abort.is_set():
                        finish = "aborted"
                        break
                    if tid in eos_ids:
                        finish = "stop"
                        break
                    gen_ids.append(int(tid))
                    # _stable_prefix 会暂扣末尾尚未拼齐的字节（见上面的说明）。
                    # 交付长度按**稳定前缀**算，因此不完整的尾巴永远不会被
                    # 当作已产出内容发出去。
                    buf = _stable_prefix(_text_of(gen_ids))
                    safe = len(buf) - (stop_hold - 1 if stop_hold else 0)
                    if safe > emitted:
                        yield _mark(buf[emitted:safe])
                        emitted = safe
                    if stops:
                        for s in stops:
                            # 允许尾部还差 stop_hold-1 个字符时就判定命中
                            probe = buf[max(0, len(buf) - len(s) - stop_hold):]
                            if s in probe:
                                hit_stop = True
                                break
                        if hit_stop:
                            finish = "stop"
                            break
            except Exception as exc:  # 任何异常回落到已验证的原生路径
                self._spec_error = f"rejection failed: {exc}"
                buf, emitted, finish = "", 0, "length"
                round_stats = []  # 回落路径的统计数据无意义，丢弃
                hit_stop = False
                for resp in stream_generate(
                    self.model, self.tokenizer, prompt=feed_ids,
                    max_tokens=cap, sampler=sampler, **gen_kwargs
                ):
                    if opts.abort is not None and opts.abort.is_set():
                        finish = "aborted"
                        break
                    # resp.text 来自 mlx_lm 的 detokenizer，同样的落单字节
                    # 问题它也存在，故一并暂扣尾部（见 _stable_prefix）。
                    buf = _stable_prefix(buf + resp.text)
                    safe = len(buf) - (stop_hold - 1 if stop_hold else 0)
                    if safe > emitted:
                        yield _mark(buf[emitted:safe])
                        emitted = safe
                    if resp.finish_reason:
                        finish = resp.finish_reason
                        break
        else:
            meta.accept_rule = "exact"
            for resp in stream_generate(
                self.model, self.tokenizer, prompt=feed_ids, max_tokens=cap,
                sampler=sampler, **gen_kwargs
            ):
                if opts.abort is not None and opts.abort.is_set():
                    finish = "aborted"
                    break
                # resp.text 来自 mlx_lm 的 detokenizer，落单字节问题同样存在，
                # 故一并暂扣尾部（见 _stable_prefix）。
                buf = _stable_prefix(buf + resp.text)
                # 留 stop_hold-1 字符在缓冲里跨块匹配 stop 串
                safe = len(buf) - (stop_hold - 1 if stop_hold else 0)
                if safe > emitted:
                    yield _mark(buf[emitted:safe])
                    emitted = safe
                if resp.finish_reason:
                    finish = resp.finish_reason
                    break

        if opts.abort is not None and opts.abort.is_set():
            finish = "aborted"
        # flush 残余；若命中 stop 串则截断
        # ⚠️ 这里的 buf 已是稳定前缀（末尾不完整字节在生成循环里被暂扣）。
        # 但若生成是**因错误跳出**而 buf 仍是原始值，仍要兜一道，
        # 保证任何路径都不会把 U+FFFD 交付给用户。
        tail = _stable_prefix(buf)[emitted:]
        cut = None
        for s in stops:
            i = tail.find(s)
            if i >= 0 and (cut is None or i < cut):
                cut = i
        if cut is not None:
            tail = tail[:cut]
            finish = "stop"
        if tail:
            yield _mark(tail)
        # 用真实 token 计数（buf 全文的 token 数，含未输出部分）
        try:
            meta.completion_tokens = len(self.tokenizer.encode(buf))
        except Exception:
            meta.completion_tokens = 0
        meta.finish_reason = finish
        meta.elapsed_s = time.time() - t0
        # TPOT = 首 token 之后的每 token 平均耗时（不含 prefill/TTFT）。
        # 与 tps（含 TTFT 的端到端均值）分开，才能判断「首字快」和「后续快」
        # 各自被优化了多少。
        if meta.completion_tokens > 1 and meta.ttft_s > 0:
            meta.tpot_s = max(
                0.0, meta.elapsed_s - meta.ttft_s) / (meta.completion_tokens - 1)
        else:
            meta.tpot_s = 0.0
        # 投机解码的每轮接受长度（只有 rejection 分支有数据）。它是「nd 调优」
        # 与「ITL 锯齿」的共同解释量：每轮耗时固定，接受越长则 TPOT 越低。
        # round_stats 在 use_rejection=False 的路径上从未被赋值，因此必须用
        # locals() 探测而不是直接引用 —— 否则非 rejection 请求会撞
        # UnboundLocalError。这是 2026-09-16 修掉的第二个同类缺陷。
        _rs = locals().get("round_stats") or []
        if _rs:
            meta.accept_lens = [int(r["accepted"]) for r in _rs]


        # 回存：cache 现在覆盖 prompt_ids + 已生成 token。必须把本轮生成的
        # token 也算进去，否则下一轮公共前缀会被算短，退化成只命中到上轮
        # prompt 末尾。任何异常都不影响已产出的文本。
        if prefix_key:
            # 未命中（pcache is None）时也要建 cache 并存起来，否则第一轮
            # 永远不回存、后续永远命中不了（鸡生蛋）。命中时复用 pcache。
            #
            # ⚠️ 回存的 ids 必须**精确等于 cache 真正覆盖的 token**。rejection
            # 路径的 prefill 是 `_prefill(..., prompt_ids[:-1])` 后再喂最后一个
            # token，即 cache 实际只覆盖到 `feed_ids` 的倒数第二个位置；而
            # `cache[0].offset` 才是权威长度。早期版本直接记
            # `prompt_ids + gen_ids`，比真实覆盖多算 token，下一轮 get 时
            # cached_len 与 ids 长度不一致 -> 前缀比对错位 -> 复用了一个
            # 「多一个 token」的陈旧 KV，输出整体串位（实测：连问 alpha/beta
            # 会依次答出 beta/gamma）。这里以 offset 为准裁剪。
            try:
                gen_ids = self.tokenizer.encode(buf)
                full = list(prompt_ids) + list(gen_ids)
                obj = pcache if pcache is not None else cached_obj
                try:
                    covered = int(obj[0].offset)
                except Exception:
                    covered = len(full)
                # 只记录 cache 真正覆盖的那一段。
                if 0 < covered < len(full):
                    full = full[:covered]
                self._prefix_put(prefix_key, obj, full)
            except Exception as exc:  # pragma: no cover - 环境相关
                self._spec_error = f"prefix cache put failed: {exc}"

    # ---- generation ------------------------------------------------------

    def chat_stream(self, messages: List[dict], opts: GenOptions) -> Iterator[Chunk]:
        meta = GenMeta()
        # 提前把 meta 挂上去，使流式期间也能读出实时字段（TTFT 等）；收尾
        # 时再赋一次，保证 last_meta 始终指向最终对象。
        self.last_meta = meta
        ids = self._encode_chat(messages)
        if len(ids) > self.entry.max_prompt_tokens:
            raise ValueError(
                f"prompt too long: {len(ids)} tokens > max {self.entry.max_prompt_tokens}"
            )
        for c in self._stream_ids(ids, opts, meta):
            yield c
        self.last_meta = meta

    def raw_stream(self, prompt: str, opts: GenOptions) -> Iterator[Chunk]:
        meta = GenMeta()
        self.last_meta = meta
        ids = self.tokenizer.encode(prompt)
        if len(ids) > self.entry.max_prompt_tokens:
            raise ValueError(
                f"prompt too long: {len(ids)} tokens > max {self.entry.max_prompt_tokens}"
            )
        for c in self._stream_ids(ids, opts, meta):
            yield c
        self.last_meta = meta


def _vocab_size(tok) -> int:
    """尽力取出 tokenizer 的词表大小；取不到返回 -1（未知）。"""
    for attr in ("vocab_size",):
        v = getattr(tok, attr, None)
        if isinstance(v, int) and v > 0:
            return v
    # HF fast tokenizer 走 get_vocab()；mlx_lm 用的是 tokenizers.Tokenizer
    try:
        n = tok.get_vocab_size()
        if isinstance(n, int) and n > 0:
            return n
    except Exception:
        pass
    try:
        return len(tok.get_vocab())
    except Exception:
        return -1


def _tokenizers_compatible(target_tok, draft_tok) -> tuple:
    """判定 draft 与 target 是否共享同一 token id 空间。

    投机解码把 draft 产出的 token id 直接喂给 target 前向。两者只要不在
    同一 id 空间，id 的语义就是错的 —— 表现不是崩溃，而是静默变慢或输出
    错乱（实测：异 tokenizer 1.49x vs 同 tokenizer 1.86x，且无任何报错）。

    判定顺序（从严到宽，任一条失败即判不兼容）：
      1. 词表大小必须相等 —— 不等则 id 空间必然错位，无例外。
      2. 探针编码：用固定文本对两边编码，**归一化 BOS 后**逐 id 比对。
         这是最强的证据，能抓住「vocab 大小碰巧相同但实际是不同词表」。

    **刻意不检查 chat_template**（2026-09-16 实测纠错）：
      第一版把「chat_template 字符串不等」也当作不兼容条件，结果把生产在用
      的 Llama-3.2-1B 草稿误判为不兼容。深挖后发现模板确实不同，但差异是：
        target (Llama-3.1): Today Date: 26 Jul 2024   （写死）
        draft  (Llama-3.2): Today Date: 16 Sep 2026   （strftime_now 取当天）
      即差异只在系统日期字符串，以及用不到的 tool/ipython 分支上。
      更关键的是：**这个差异在我们的调用路径上根本不发挥作用** ——
      `_encode_chat()` 只用 target 的 tokenizer 编码，draft 拿到的是 target
      已编码好的 token id，自己从不调用 chat_template。所以模板不一致不会
      造成 id 空间错位，只会让「双方各自独立编码同一对话」时结果不同，
      而那不是投机解码的路径。
      ⇒ 模板与 token id 空间**正交**，不应作为闸门条件。

    返回 (ok: bool, reason: str)。任何拿不准的情况一律返回 False（拒绝启用
    投机），因为投机只是可选优化，而错误启用会造成正确性事故。

    ---- 实测踩到的坑（2026-09-16，用真实 tokenizer 验证）-------------

    **不同 tokenizer 的 `encode()` 对 BOS 的处理不一致。**
      Llama-3.1-8B 的 tokenizer `encode("The capital")` -> [791, 6864]（无 BOS）
      Llama-3.2-1B 的 tokenizer `encode("The capital")` -> [128000, 791, 6864]（有 BOS）
      两者其实是**同一个词表**（vocab 都是 128000、去掉首位 BOS 后逐 id 一致）。
      若直接比对原始输出，闸门会把生产在用的合法草稿模型误判为不兼容 ——
      这正是第一版的 bug。故必须先剥掉开头的 bos_token_id 再比对。
    """
    tv, dv = _vocab_size(target_tok), _vocab_size(draft_tok)
    if tv > 0 and dv > 0 and tv != dv:
        return False, f"vocab size differs (target={tv}, draft={dv})"

    # ---- 探针编码（唯一实质判据）----------------------------------------
    # 取覆盖 ASCII、多语言、代码、标点与空白的样本。
    probe = (
        "The capital of France is Paris.",
        "水是生命之源，因为",
        "def fibonacci(n):\n    return n",
        "1, 2, 3, 4, 5 — 6 7 8",
        "  \n\t mixed   whitespace  ",
    )
    for text in probe:
        try:
            a = _normalize_ids(target_tok, text)
            b = _normalize_ids(draft_tok, text)
        except Exception as exc:
            return False, f"probe encode failed: {exc}"
        if a != b:
            return False, (
                f"probe encoding differs for {text!r} "
                f"(target={a[:8]}, draft={b[:8]})"
            )

    if tv <= 0 or dv <= 0:
        # 词表大小未知但探针全过：仍接受，但记录一下。
        return True, "probe passed (vocab size unknown)"
    return True, f"vocab={tv}, probe passed"


def _normalize_ids(tok, text: str) -> list:
    """编码并把开头的 BOS 剥掉，消除不同 tokenizer 的 BOS 行为差异。

    见 _tokenizers_compatible 的坑：同一个词表的不同 tokenizer 配置可能对
    BOS 的处理不同，而 token id 空间其实一致。
    """
    ids = list(tok.encode(text))
    bos = getattr(tok, "bos_token_id", None)
    if bos is not None and ids and ids[0] == bos:
        ids = ids[1:]
    return ids



def _stable_prefix(s: str) -> str:
    """去掉末尾不完整的字节（表现为连续的 U+FFFD）。

    为什么需要它（2026-09-17 实测定位）：Llama 的 byte-level BPE 词表里有
    **落单的字节碎片** token，例如 id=33443 单独 decode 就是 U+FFFD。序列
    [116685,112086,248,45826,106,33443] 整段解码得到 '浩瀚壮�' —— 即 33443
    没有可配对的邻居，解码器只能吐 �。

    逐 token 拼接更糟（'浩�����'）。唯一可靠的办法是**暂扣尾部**：如果解码
    结果以 U+FFFD 结尾，就先不交付这一段，等后续 token 到来再一起解码；
    若始终补不齐，这一两个字节被丢弃。

    取舍：宁可少一两个字节，也不把 � 写给用户。中间的 �（模型真产出的非法
    字节）不做处理 —— 那不是拼接问题，无从恢复。
    """
    return s.rstrip("\ufffd")

def _flatten_message(m: dict) -> dict:
    """OpenAI message 兼容：content 可为 str 或 content parts 数组。

    ⚠️ 附件（{"type": "file"}）在这里提取成文本注入。
    旧实现对非 text 的 part 是**静默跳过** —— 用户附一个 PDF 或一张图，
    模型什么都没收到，而且没有任何报错，用户只会觉得「模型没看我的文件」。
    现在改为：能提取就提取，不能提取就抛 AttachmentError，由 server 层
    转成 400 并把原因回给客户端。
    """
    role = m.get("role", "user")
    content = m.get("content", "")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        parts = []
        for p in content:
            if isinstance(p, dict) and p.get("type") == "text":
                parts.append(str(p.get("text", "")))
        text = "\n".join(parts)

        from ..attachments import build_attachment_block

        block = build_attachment_block(content)
        if block:
            text = f"{text}\n\n{block}" if text else block
    else:
        text = str(content)
    return {"role": role, "content": text}


def create(entry: ModelEntry) -> Backend:
    return MlxLmBackend(entry)
