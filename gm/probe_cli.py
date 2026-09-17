"""gm-probe CLI：为任意 MLX 模型推导并验证投机解码配置。

    python3 -m gm.autotune <模型路径>                # 探测 + 报告
    python3 -m gm.autotune <模型路径> --write        # 写回 models.json
    python3 -m gm.autotune <模型路径> --sweep        # 附带 n_draft 实测扫描

设计原则：
  - **只读探测默认安全**：不加 --write 绝不改 models.json。
  - **诚实报告**：无同族草稿时明确说「不支持加速」，不硬配草稿。
  - **不静默联网**：只在本地 HF cache 里找草稿；找不到就报告需要下载。
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from pathlib import Path


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="gm-probe",
        description="为任意 MLX 模型探测并验证投机解码配置",
    )
    p.add_argument("model", help="模型目录路径（含 config.json）")
    p.add_argument("--name", help="写入 models.json 时使用的模型名（默认取目录名）")
    p.add_argument("--alias", action="append", default=[],
                   help="别名，可重复")
    p.add_argument("--draft", help="手工指定草稿模型路径（跳过自动匹配）")
    p.add_argument("--write", action="store_true",
                   help="把推荐配置写回 models.json（默认只报告不修改）")
    p.add_argument("--sweep", action="store_true",
                   help="实测扫描 n_draft（较慢，需加载模型）")
    p.add_argument("--sweep-max", type=int, default=4,
                   help="n_draft 扫描上限（默认 4）")
    p.add_argument("--json", action="store_true", help="输出 JSON 而非文本")
    return p


def cmd_sweep(model_path: str, draft_path: str, max_nd: int,
              rounds: int = 3, gen_tokens: int = 96) -> dict:
    """实测扫描 n_draft，返回每个 nd 的统计与相对 best 的比值。

    ## 方法学（关键，且第一版曾做错）

    本机是无风扇 M5，持续负载下热态漂移可达 50%+。第一版按 nd=1→N
    **顺序**各测一块，结果把 nd=4 测成 8.69 tok/s（而 nd=2 是 22.08），
    看起来像「nd=4 灾难性变慢」—— 但交替复测的比值只有 **0.969**，即
    两者几乎一样。顺序扫描把后半段的 nd 测在了更热的机器上。

    这正是项目铁律「顺序扫描若测项本身会致热，必须交错 + 冷却」说的陷阱，
    所以本版改为：

      1. **轮转交错**：每一轮里把所有 nd 各测一次（nd=1,2,3,4,1,2,3,4…），
         使任何缓慢的热漂移对所有 nd 的影响均等。
      2. **逐个取样取中位**：每个 nd 收集 rounds 个样本，取中位。
      3. **报告比值而非绝对值**：以最高中位的 nd 为基准给出相对比值。
         绝对值仅供对照，跨运行不可比。

    仍然诚实标注：即使交错，本机测量精度有限，结论应结合 `accept_len`
    （纯算法量，不受热态影响）一起看 —— 若两个 nd 的 accept_len 接近而
    实测比值也接近，则它们实质等效。
    """
    from mlx_lm import load

    from .backends.spec_rejection import stream_rejection

    model, tokenizer = load(model_path)
    draft, _ = load(draft_path)

    prompt = "Write a short paragraph about the ocean."
    ids = tokenizer.apply_chat_template(
        [{"role": "user", "content": prompt}],
        add_generation_prompt=True, tokenize=True)
    ids = [int(x) for x in ids["input_ids"]] if hasattr(ids, "keys") else [int(x) for x in ids]

    nds = list(range(1, max_nd + 1))

    def one(nd: int) -> dict:
        t0 = time.time()
        stats: list = []
        n = sum(1 for _ in stream_rejection(
            model, draft, ids, gen_tokens, 0.0, nd, round_stats=stats))
        dt = time.time() - t0
        return {
            "tps": (n / dt) if dt > 0 else 0.0,
            "accept_len": (sum(s["accepted"] for s in stats) / len(stats)) if stats else 0.0,
            "rounds": len(stats),
        }

    # 预热：每个 nd 各跑一次短序列，把首次编译/分配成本排除在计时之外。
    for nd in nds:
        list(stream_rejection(model, draft, ids, 16, 0.0, nd))

    # 轮转交错采样（关键修正）。
    samples: dict = {nd: [] for nd in nds}
    for _ in range(rounds):
        for nd in nds:
            s = one(nd)
            if s["tps"] > 0:
                samples[nd].append(s)

    out: dict = {}
    for nd in nds:
        xs = samples[nd]
        if not xs:
            continue
        xs_t = sorted(x["tps"] for x in xs)
        out[nd] = {
            "tps": xs_t[len(xs_t) // 2],                       # 中位 tok/s
            "tps_min": xs_t[0], "tps_max": xs_t[-1],
            "accept_len": sum(x["accept_len"] for x in xs) / len(xs),
            "rounds": xs[len(xs) // 2]["rounds"],
            "n_samples": len(xs),
        }

    # 相对基准的比值：热态对所有 nd 的影响在交错下近似均等，
    # 因此比值比绝对值可信得多。
    if out:
        base_nd = max(out.items(), key=lambda kv: kv[1]["tps"])[0]
        base = out[base_nd]["tps"]
        for nd, v in out.items():
            v["ratio_vs_best"] = round(v["tps"] / base, 3) if base > 0 else 0.0

        # ---- 并列区间（关键，避免给出伪精确的「最优 nd」）------------
        # 实测发现：nd=1 与 nd=2 的比值在三次独立扫描间于 0.926–1.000
        # 之间来回翻转，最优值在 1 和 2 之间跳。若只报「最优=1」或
        # 「最优=2」，用户会以为这个数字是确定的 —— 其实是噪声。
        #
        # 判据：落在最优值 1 个百分点的统计噪声内的 nd 视为**并列**。
        # 本机热态漂移远超 1%，但轮转交错已把系统性偏差消掉，剩下的
        # 是比较噪声；用 1% 是保守取法（宽于观测到的翻转幅度）。
        # 实测（2026-09-16，四次独立扫描）发现：nd=1/2/3/4 的比值跨度
        # 分别达 0.080/0.190/0.165/0.086，**四次扫描给出四个不同的最优值**
        # （2,2,1,3）。即：本机在 96-token 短序列上**无法可靠区分** nd。
        # 因此不能只挑一个最大值当结论 —— 那是伪精确。改为报整个并列区间，
        # 只在有 nd 明确掉出噪声带时才给出真正的推荐。
        TIE_BAND = 0.95
        tied = sorted(nd for nd, v in out.items()
                      if v.get("ratio_vs_best", 0) >= TIE_BAND)
        # 并列时选 accept_len 更大的那个：它是纯算法量、不受热态影响，
        # 因此更能代表「真实效率」。若仍相同则取较小的 nd（草稿成本更低）。
        if len(tied) > 1:
            pick = max(tied, key=lambda n: (out[n]["accept_len"], -n))
            confidence = "LOW"
            conf_note = (
                f"nd={tied} 全部落在 5% 噪声带内，本机无法区分。"
                f"按 accept_len（不受热态影响）择优取 {pick}。"
                f"任何 nd∈{tied} 都是合理选择。"
            )
        else:
            pick = base_nd
            confidence = "MEDIUM"
            conf_note = (
                f"只有 nd={base_nd} 显著高于其余（超 5%）。"
                f"但本机单次扫描仍可能翻转，建议复扫确认。"
            )

        out["_meta"] = {
            "method": "round-robin interleaved",
            "rounds": rounds,
            "gen_tokens": gen_tokens,
            "best_nd": pick,
            "best_nd_by_raw_tps": base_nd,
            "tied_nds": tied,
            "tie_band": TIE_BAND,
            "confidence": confidence,
            "confidence_note": conf_note,
            "thermal_note": (
                "本机无风扇，热态漂移可达 50%+。已用轮转交错抵消，"
                "但绝对值仍不可跨运行比较，只看比值与 accept_len。"
            ),
        }
    return out


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    from . import autotune

    mp = str(Path(args.model).expanduser())
    if not (Path(mp) / "config.json").exists():
        print(f"错误：{mp} 下没有 config.json —— 不是有效的模型目录", file=sys.stderr)
        return 2

    if args.draft:
        dp = str(Path(args.draft).expanduser())
        ok, why = autotune.evaluate_draft(mp, dp)
        report = autotune.probe(mp)
        report["candidates"] = [{
            "repo": "(手工指定)", "local_path": dp,
            "usable": ok, "reason": why,
        }]
        report["speculative_supported"] = ok
        report["reason"] = "手工指定草稿" if ok else why
        if ok:
            report["recommendation"] = {
                "draft_model": dp,
                "draft_repo": "(手工指定)",
                "num_draft_tokens": 3,
                "num_draft_tokens_high_temp": 2,
                "max_temp": 0.5,
                "accept_rule": "rejection",
                "nd_is_default_not_measured": True,
            }
        else:
            autotune._fill_universal_levers(report)
    else:
        report = autotune.probe(mp)

    # ---- 扫描必须在渲染之前完成 ----------------------------------------
    # 第一版把扫描放在「渲染报告」之后，于是用户看到的顺序是：
    #   ① 完整报告（含「nd 未实测」的警告）
    #   ② 卡住 30–80 秒
    #   ③ 突然冒出一段实测结果
    # 报告刚说完「没实测」，又出现实测结果 —— 自相矛盾，且中间的静默
    # 让人以为卡死了。现在改为：先算完，再一次性渲染一份自洽的报告。
    if args.sweep and report["speculative_supported"]:
        rec = report["recommendation"]
        n_nd = args.sweep_max
        print(
            f"正在实测扫描 n_draft（1..{n_nd}，轮转交错，约需 "
            f"{n_nd * 20 + 30} 秒）...",
            file=sys.stderr, flush=True,
        )
        try:
            sw = cmd_sweep(mp, rec["draft_model"], args.sweep_max)
            meta = sw.pop("_meta", {})
            report["nd_sweep"] = {str(k): v for k, v in sw.items()}
            report["nd_sweep_meta"] = meta
            if sw:
                best_nd = meta.get("best_nd") or max(
                    sw.items(), key=lambda kv: kv[1]["tps"])[0]
                rec["num_draft_tokens"] = best_nd
                rec["nd_is_default_not_measured"] = False
                rec["nd_sweep_best"] = best_nd
            print("扫描完成。", file=sys.stderr, flush=True)
        except Exception as exc:
            report["nd_sweep_error"] = str(exc)
            print(f"扫描失败（不影响探测结果）: {exc}", file=sys.stderr, flush=True)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(autotune.format_report(report))
        if "nd_sweep" in report:
            meta = report.get("nd_sweep_meta", {})
            print(f"\n--- n_draft 实测扫描（{meta.get('method', '?')}）---")
            print(f"  {'nd':>3}  {'tok/s':>7}  {'比值':>6}  {'accept_len':>10}  rounds")
            for nd, v in sorted(report["nd_sweep"].items(),
                                key=lambda kv: int(kv[0])):
                print(f"  {nd:>3}  {v['tps']:>7.2f}  {v.get('ratio_vs_best', 0):>6.3f}"
                      f"  {v['accept_len']:>10.2f}  {v['rounds']}")
            if meta.get("thermal_note"):
                print(f"  ⚠️ {meta['thermal_note']}")
            conf = meta.get("confidence")
            if conf:
                icon = {"LOW": "🟨", "MEDIUM": "🟩"}.get(conf, "ℹ️")
                print(f"  {icon} 结论可信度: {conf}")
                if meta.get("confidence_note"):
                    print(f"     {meta['confidence_note']}")
            if report["recommendation"].get("nd_is_default_not_measured") is False:
                print(f"  → 推荐 nd={report['recommendation']['nd_sweep_best']}")

    if args.write:
        if not report["speculative_supported"]:
            print("\n未写入：该模型不支持投机解码加速（原因见上）。", file=sys.stderr)
            print("若仍要登记该模型，去掉 --write 后手工编辑 models.json。",
                  file=sys.stderr)
            return 1
        root, cfg, data = autotune.load_model_entry()
        name = args.name or Path(mp).name
        rec = report["recommendation"]
        entry = {
            "name": name,
            "aliases": list(args.alias),
            "runtime": "mlx_lm",
            "path": mp,
            "context": {"max_prompt_tokens": 32768, "max_output_tokens": 4096},
            "params": {
                "temperature": 0.7,
                "top_p": 1.0,
                "speculative": {
                    "enabled": True,
                    "draft_model": rec["draft_model"],
                    "num_draft_tokens": rec["num_draft_tokens"],
                    "num_draft_tokens_high_temp": rec["num_draft_tokens_high_temp"],
                    "max_temp": rec["max_temp"],
                    "accept_rule": rec["accept_rule"],
                },
            },
        }
        models = data.setdefault("models", [])
        for i, m in enumerate(models):
            if m.get("name") == name:
                models[i] = entry
                break
        else:
            models.append(entry)
        bak = cfg.with_suffix(f".json.bak.{time.strftime('%Y%m%d_%H%M%S')}")
        shutil.copy2(cfg, bak)
        cfg.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\n已写入 {cfg}")
        print(f"备份   {bak}")
        print("重启网关生效: launchctl kickstart -k gui/$(id -u)/com.tristan.gm.gateway")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
