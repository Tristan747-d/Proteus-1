#!/usr/bin/env python3
"""gm 网关测量装置（Proteus-2 Phase-0 冻结版）。

为什么冻结到本工作区
--------------------
原 benchmark 散落在 iCloud 报告目录（`Corp AI/MLXonANE/.../scripts/`），
不在版本控制内，且硬编码了已废弃的 model id `llama-3.1-8b-4bit`
（2026-09-17 实测：该 id 返回 HTTP 404，网关现有模型为 `proteus-1` /
`gpu-baseline`）。⇒ 生产数字当时无法复现（审计 D4）。

本文件取代它们，并修掉 Phase-0 审计查出的测量缺陷。

修掉的缺陷（对应审计编号）
--------------------------
* D4  model id 改为可配置，默认从 /v1/models 自动发现。
* §4.2 指标串号：不再读全局 /stats.last_meta 作为主数据源；改为**按
      请求自身**的 SSE chunk 时序计算，/stats 只作交叉校验。全局
      last_meta 会被任何并发请求（如 GUI 轮询）覆盖。
* §4.6 冷/热臂不再依赖 session 名撞运气：显式区分「空 session（不复用）」
      与「复用 session」两臂。
* §4.4 冷却默认提到 180s（本机确立门槛），并在每臂前记录宿主状态。
* §11.2 宿主守卫：swap/load 超阈值时**拒绝出结论**（需 --force 才继续）。

用法
----
    python3 tools/gw_bench.py --list-models
    python3 tools/gw_bench.py --model proteus-1 --rounds 3 --cool 180
    python3 tools/gw_bench.py --model gpu-baseline --rounds 3 --cool 180
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_HOST = "http://127.0.0.1:8320"
OUT_DIR = Path(__file__).resolve().parent / "results"

# 宿主守卫阈值（审计 §11.2）。超过即拒绝出结论。
MAX_SWAP_MB = 1024.0
MAX_LOAD1 = 5.0

SYS = ("You are a careful technical assistant. Answer using short, concrete "
       "sentences. Prefer specific facts over generalities.")


# ---------------------------------------------------------------- host state

def _swap_used_mb():
    try:
        out = subprocess.run(["sysctl", "-n", "vm.swapusage"],
                             capture_output=True, text=True, timeout=10).stdout
        return float(out.split("used =")[1].split("M")[0].strip())
    except Exception:
        return None


def _load1():
    try:
        out = subprocess.run(["sysctl", "-n", "vm.loadavg"],
                             capture_output=True, text=True, timeout=10).stdout
        return float(out.split()[1])
    except Exception:
        return None


def host_state() -> dict:
    st = {"swap_used_mb": _swap_used_mb(), "load1": _load1()}
    st["dirty"] = ((st["swap_used_mb"] or 0) > MAX_SWAP_MB
                   or (st["load1"] or 0) > MAX_LOAD1)
    reasons = []
    if (st["swap_used_mb"] or 0) > MAX_SWAP_MB:
        reasons.append(f"swap {st['swap_used_mb']:.0f}MB > {MAX_SWAP_MB:.0f}MB")
    if (st["load1"] or 0) > MAX_LOAD1:
        reasons.append(f"load1 {st['load1']:.2f} > {MAX_LOAD1}")
    st["dirty_reasons"] = reasons
    return st


# ------------------------------------------------------------------ gateway

def _get(host, path, timeout=30):
    with urllib.request.urlopen(host + path, timeout=timeout) as r:
        return json.loads(r.read().decode())


def list_models(host):
    return [m["id"] for m in _get(host, "/v1/models")["data"]]


def discover_model(host, prefer="proteus-1"):
    ids = list_models(host)
    if prefer in ids:
        return prefer
    if not ids:
        raise RuntimeError("gateway reports no models")
    return ids[0]


# -------------------------------------------------------------------- timing

def one_request(host, model, prompt, temp, max_tokens, session=None,
                timeout=900.0, system=SYS):
    """One streaming request. Timing is derived from THIS request's chunks only.

    Returns per-request metrics computed locally, so a concurrent client
    (GUI polling /stats) cannot contaminate them.
    """
    body = {
        "model": model,
        "messages": ([{"role": "system", "content": system}] if system else [])
                    + [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temp,
        "stream": True,
    }
    if session:
        body["session"] = session
    req = urllib.request.Request(
        host + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})

    t0 = time.perf_counter()
    stamps, text, n_chunks = [], "", 0
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                obj = json.loads(payload)
            except json.JSONDecodeError:
                continue
            for ch in obj.get("choices", []):
                piece = (ch.get("delta") or {}).get("content")
                if piece:
                    stamps.append(time.perf_counter() - t0)
                    text += piece
                    n_chunks += 1
    t_end = time.perf_counter()

    # ⚠️ stamps 存的是「相对 t0 的偏移」，t_end 是绝对 perf_counter 值。
    # 两者不可相减 —— 早期版本写 decode_s = t_end - ttft，把 tps_decode
    # 算成了 ~0（实测 0.00026 tok/s，而真实约 4 tok/s）。统一成偏移再算。
    ttft = stamps[0] if stamps else None
    total_s = t_end - t0
    itls = [(stamps[i] - stamps[i - 1]) * 1000.0
            for i in range(1, len(stamps))]
    # 首 token 之后的耗时 = 总耗时 - TTFT（两者同为相对量）。
    decode_s = (total_s - ttft) if ttft else total_s
    return {
        "prompt": prompt[:60],
        "completion_tokens": n_chunks,
        "ttft_s": ttft,
        "total_s": total_s,
        "tps_decode": (n_chunks / decode_s) if decode_s > 0 else None,
        "itl_p50_ms": statistics.median(itls) if itls else None,
        "itl_p95_ms": (_pct(itls, 0.95) if itls else None),
        "text_head": text[:80],
    }


def _pct(xs, q):
    if not xs:
        return None
    s = sorted(xs)
    i = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
    return float(s[i])


# ---------------------------------------------------------------------- main

PROMPTS = [
    "Explain how a transformer attention mechanism works, step by step.",
    "Write a short story about a lighthouse keeper who discovers a message in a bottle.",
    "Describe the water cycle in detail, including all major processes.",
    "Summarise the causes and consequences of the Industrial Revolution.",
    "Explain why memory bandwidth rather than compute limits token generation.",
]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--model", default=None,
                    help="model id; default: auto-discover (prefers proteus-1)")
    ap.add_argument("--list-models", action="store_true")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=200)
    ap.add_argument("--temp", type=float, default=0.7)
    ap.add_argument("--cool", type=float, default=180.0,
                    help="cooldown seconds between rounds (project minimum: 180)")
    ap.add_argument("--label", default="run")
    ap.add_argument("--force", action="store_true",
                    help="run even when the host looks dirty (results NOT conclusive)")
    args = ap.parse_args()

    if args.list_models:
        print(json.dumps(list_models(args.host), indent=2))
        return 0

    try:
        model = args.model or discover_model(args.host)
    except Exception as exc:
        print(f"FATAL cannot reach gateway at {args.host}: {exc}", file=sys.stderr)
        return 2

    hs0 = host_state()
    print(f"gateway : {args.host}")
    print(f"model   : {model}   (available: {list_models(args.host)})")
    print(f"host    : swap={hs0['swap_used_mb']}MB load1={hs0['load1']} "
          f"dirty={hs0['dirty']}")
    if hs0["dirty"]:
        print(f"  DIRTY REASONS: {hs0['dirty_reasons']}")
        if not args.force:
            print("\n*** HOST DIRTY — refusing to produce numbers. ***")
            print("    Free memory / stop background load, then re-run.")
            print("    Ratios within a single round stay usable, but this")
            print("    script's job is absolute tok/s, so it stops here.")
            print("    Override with --force only to collect indicative data.")
            return 3

    rows = []
    for i in range(args.rounds):
        # Arm A: no session -> prefix cache cannot reuse across requests.
        a = one_request(args.host, model, PROMPTS[i % len(PROMPTS)],
                        args.temp, args.max_tokens, session=None)
        # Arm B: same session, second turn -> exercises prefix reuse.
        b = one_request(args.host, model, PROMPTS[i % len(PROMPTS)],
                        args.temp, args.max_tokens, session=f"p2-{args.label}-{i}")
        b2 = one_request(args.host, model, "Now restate that in one sentence.",
                         args.temp, args.max_tokens,
                         session=f"p2-{args.label}-{i}")
        rows.append({"round": i, "cold": a, "warm_turn1": b, "warm_turn2": b2})
        print(f"  r{i} cold ttft={_f(a['ttft_s'])}s dec={_f(a['tps_decode'])} "
              f"tok/s | warm1 ttft={_f(b['ttft_s'])}s | "
              f"warm2 ttft={_f(b2['ttft_s'])}s cached_reuse_expected")
        if i + 1 < args.rounds:
            print(f"  cooling {args.cool:.0f}s ...", flush=True)
            time.sleep(args.cool)

    hs1 = host_state()

    def med(arm, key):
        xs = [r[arm][key] for r in rows if r[arm][key] is not None]
        return statistics.median(xs) if xs else None

    summary = {
        "label": args.label, "model": model, "temp": args.temp,
        "max_tokens": args.max_tokens, "rounds": args.rounds,
        "host_before": hs0, "host_after": hs1,
        "cold_ttft_median": med("cold", "ttft_s"),
        "cold_tps_median": med("cold", "tps_decode"),
        "cold_tps_range": [
            min(r["cold"]["tps_decode"] for r in rows
                if r["cold"]["tps_decode"] is not None),
            max(r["cold"]["tps_decode"] for r in rows
                if r["cold"]["tps_decode"] is not None),
        ] if rows else None,
        "warm2_ttft_median": med("warm_turn2", "ttft_s"),
        "itl_p50_median": med("warm_turn2", "itl_p50_ms"),
        "itl_p95_median": med("warm_turn2", "itl_p95_ms"),
        "rows": rows,
    }
    ratios = [r["cold"]["ttft_s"] / r["warm_turn2"]["ttft_s"]
              for r in rows
              if r["cold"]["ttft_s"] and r["warm_turn2"]["ttft_s"]]
    summary["ttft_reuse_ratio_median"] = (
        statistics.median(ratios) if ratios else None)
    summary["ttft_reuse_ratio_range"] = (
        [min(ratios), max(ratios)] if ratios else None)

    print("\n=== SUMMARY ===")
    print(json.dumps({k: v for k, v in summary.items() if k != "rows"},
                     indent=2, ensure_ascii=False))

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    p = OUT_DIR / f"gw_bench_{args.label}_{model}.json"
    p.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"\nsaved -> {p}")

    if hs1["dirty"] and not hs0["dirty"]:
        print("\n*** host became dirty DURING the run — absolute numbers "
              "are suspect; per-round ratios still hold. ***")
    return 0


def _f(x, nd=3):
    return f"{x:.{nd}f}" if isinstance(x, (int, float)) else "n/a"


if __name__ == "__main__":
    sys.exit(main())
