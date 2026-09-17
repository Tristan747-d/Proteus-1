"""模型接入自动化：为任意 MLX 模型找到并验证最优投机解码配置。

## 为什么需要这个模块

网关本身是模型无关的（`base.py` 的 `register_backend` + `models.json` 路由，
`spec_rejection.py` 只用 `model(...)` / `model.layers` / `make_prompt_cache`
这些 mlx_lm 通用接口）。真正让「换模型」变麻烦的是**配置的推导**：

  1. 这个模型有没有可用的同族草稿？
  2. 草稿与 target 的 tokenizer 是否兼容？（不兼容会静默出错乱输出）
  3. n_draft 取多少？（它取决于 target/draft 的相对速度，换模型必须重测）
  4. 加速是否真的为正？（本机无风扇，热态漂移可达 50%+，必须配对比值）

以前这四步全靠手工。本模块把它们自动化成一条命令。

## 诚实的边界（必须写在最前面）

**投机解码在数学上无法加速所有模型。** 收益取决于草稿成本比
`c = draft_time / target_time`：

    8B target + 1B draft  ->  c ≈ 0.125  ->  实测 1.245-1.284x  ✅
    0.5B target + ?       ->  c >= 1     ->  必然更慢            ❌

小模型没有「更小的同族草稿」可用（没有 0.1B 的 Qwen）。此时本模块会
**明确报告「该模型不支持投机加速」并给出原因**，而不是硬配一个草稿让用户
以为有加速。这是本模块与「无脑开投机」的根本区别。

对这类模型，仍有两个**模型无关**的杠杆可用（但它们加速的是 TTFT 与内存，
不是 decode 吞吐）：

    - prefix cache（多轮对话复用）—— 只用 trim_prompt_cache，完全通用
    - KV cache 量化（kv_bits）    —— 模型无关

## 用法

    python3 -m gm.autotune /path/to/model              # 探测 + 报告
    python3 -m gm.autotune /path/to/model --write      # 写回 models.json
    python3 -m gm.autotune /path/to/model --sweep      # 附带 n_draft 扫描
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# 同族草稿候选：按 model_type 分组，从快到慢排列。
# 只列「确认与 target 同 tokenizer 族」的小模型。匹配时仍会做实测校验，
# 这里的表只是缩小搜索范围，不是信任来源。
DRAFT_CANDIDATES: Dict[str, List[str]] = {
    "llama": [
        "mlx-community/Llama-3.2-1B-Instruct-4bit",
        "mlx-community/Llama-3.2-3B-Instruct-4bit",
    ],
    "qwen2": [
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
        "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
    ],
    "qwen3": [
        "mlx-community/Qwen3-0.6B-4bit",
        "mlx-community/Qwen3-1.7B-4bit",
    ],
    "gemma2": ["mlx-community/gemma-2-2b-it-4bit"],
    "gemma3": ["mlx-community/gemma-3-1b-it-4bit"],
    "phi3": ["mlx-community/Phi-3.5-mini-instruct-4bit"],
    "mistral": ["mlx-community/Mistral-7B-Instruct-v0.3-4bit"],
    "granite": ["mlx-community/granite-3.1-2b-instruct-4bit"],
}


@dataclass
class ModelInfo:
    """从 config.json + tokenizer 提取的模型指纹。"""

    path: str
    model_type: str = ""
    architectures: List[str] = field(default_factory=list)
    vocab_size: int = -1
    hidden_size: int = -1
    num_layers: int = -1
    rope_theta: float = -1.0

    @property
    def size_class(self) -> str:
        """粗粒度规模档位，用于草稿可行性判断。"""
        h = self.hidden_size
        if h < 0:
            return "unknown"
        if h <= 1024:
            return "tiny(<=1B)"
        if h <= 2048:
            return "small(1-3B)"
        if h <= 4096:
            return "mid(7-9B)"
        if h <= 6144:
            return "large(13-14B)"
        return "xlarge(30B+)"


def read_model_info(path: str) -> ModelInfo:
    """读 config.json 得到模型指纹。任何字段缺失都不致命。"""
    p = Path(path).expanduser()
    cfg = p / "config.json"
    info = ModelInfo(path=str(p))
    if not cfg.exists():
        return info
    try:
        d = json.loads(cfg.read_text(encoding="utf-8"))
    except Exception:
        return info
    info.model_type = str(d.get("model_type", "") or "")
    info.architectures = list(d.get("architectures", []) or [])
    for key, attr in (
        ("vocab_size", "vocab_size"),
        ("hidden_size", "hidden_size"),
        ("num_hidden_layers", "num_layers"),
    ):
        v = d.get(key)
        if isinstance(v, int):
            setattr(info, attr, v)
    rt = d.get("rope_theta")
    if isinstance(rt, (int, float)):
        info.rope_theta = float(rt)
    return info


def is_complete_snapshot(path: str) -> Tuple[bool, str]:
    """检查模型目录是否是**完整**的快照。

    动机（2026-09-16 实测踩到）：HF cache 里可能存在只下载了 config.json
    的半成品快照（下载中断）。这种目录 read_model_info 能读出全部指纹、
    看起来完全正常，但 tokenizer 加载会得到一个 vocab=1 的空壳 —— 于是
    兼容性检查会报出「vocab size differs (target=151643, draft=1)」这种
    **误导性的错误信息**，让人以为是词表不兼容，实际只是文件没下完。

    一个可加载的 HF/MLX 模型目录至少要有 config.json + 权重 + tokenizer。
    权重格式有 safetensors 与 npz 两种，tokenizer 有 tokenizer.json 或
    tokenizer.model（SentencePiece）两种，都要认。
    """
    p = Path(path).expanduser()
    if not p.is_dir():
        return False, "目录不存在"
    if not (p / "config.json").exists():
        return False, "缺少 config.json"

    weight_globs = ("*.safetensors", "*.npz", "*.gguf", "*.bin")
    if not any(any(p.glob(g)) for g in weight_globs):
        return False, "缺少权重文件（*.safetensors / *.npz）"

    tok_files = ("tokenizer.json", "tokenizer.model", "tokenizer_config.json")
    if not any((p / f).exists() for f in tok_files):
        return False, "缺少 tokenizer 文件（tokenizer.json / tokenizer.model）"

    return True, "完整"


def _load_tokenizer_safe(path: str):
    """加载 tokenizer；失败返回 None（不抛，探测流程要继续）。"""
    try:
        from transformers import AutoTokenizer

        return AutoTokenizer.from_pretrained(str(Path(path).expanduser()))
    except Exception:
        try:
            from mlx_lm import load as _mlx_load

            _, tok = _mlx_load(str(Path(path).expanduser()))
            return tok
        except Exception:
            return None


def candidate_drafts(info: ModelInfo) -> List[str]:
    """按 model_type 给出同族草稿候选（可能为空）。"""
    return list(DRAFT_CANDIDATES.get(info.model_type, []))


def resolve_cached(repo_or_path: str) -> Optional[str]:
    """把 HF repo id 解析成本地可加载路径（优先 HF cache 快照）。

    不联网下载：只在本地缓存里找。找不到返回 None，由调用方决定是否提示
    用户先下载。这符合「不静默产生网络副作用」的原则。
    """
    p = Path(repo_or_path).expanduser()
    if p.is_dir():
        return str(p)
    if "/" not in repo_or_path:
        return None
    org, name = repo_or_path.split("/", 1)
    base = Path.home() / ".cache" / "huggingface" / "hub"
    cand = base / f"models--{org}--{name}" / "snapshots"
    if not cand.is_dir():
        return None
    snaps = sorted([d for d in cand.iterdir() if d.is_dir()])
    for s in snaps:
        if (s / "config.json").exists():
            return str(s)
    return None


def evaluate_draft(target_path: str, draft_path: str) -> Tuple[bool, str]:
    """判定草稿是否可用：tokenizer 兼容 + 规模关系合理。

    规模检查是「诚实」的关键：若 draft 不比 target 小，投机必然亏。
    这里用 hidden_size 做粗判（比参数量稳，因为量化不改变 hidden）。
    """
    t_tok = _load_tokenizer_safe(target_path)
    d_tok = _load_tokenizer_safe(draft_path)
    if t_tok is None or d_tok is None:
        return False, "tokenizer 加载失败"

    # 复用后端里已实现的权威判据，避免两处逻辑漂移。
    try:
        from .backends.mlx_lm_backend import _tokenizers_compatible

        ok, why = _tokenizers_compatible(t_tok, d_tok)
    except Exception as exc:
        return False, f"兼容性检查异常: {exc}"
    if not ok:
        return False, why

    ti = read_model_info(target_path)
    di = read_model_info(draft_path)
    if ti.hidden_size > 0 and di.hidden_size > 0:
        if di.hidden_size >= ti.hidden_size:
            return False, (
                f"draft 不比 target 小 "
                f"(hidden {di.hidden_size} >= {ti.hidden_size})："
                f"投机必然亏损，不应启用"
            )
    return True, f"vocab={getattr(t_tok, 'vocab_size', -1)}, 兼容且更小"


def load_model_entry(params_root: Optional[str] = None):
    """读 models.json（便于 CLI 写回）。"""
    root = Path(params_root) if params_root else _default_gm_root()
    cfg = root / "models.json"
    return root, cfg, (json.loads(cfg.read_text(encoding="utf-8")) if cfg.exists() else {})


def _default_gm_root() -> Path:
    """gm 项目根目录（含 models.json）。"""
    env = os.environ.get("GM_ROOT")
    if env:
        return Path(env).expanduser()
    # 本文件位于 <root>/gm/autotune.py
    return Path(__file__).resolve().parent.parent


def probe(
    model_path: str,
    *,
    allow_download_hint: bool = True,
) -> dict:
    """对一个模型做完整探测，返回结构化报告（不修改任何文件）。

    步骤：
      1. 读模型指纹
      2. 按 model_type 找同族草稿候选（本地缓存内）
      3. 逐个做兼容性 + 规模校验
      4. 给出推荐配置；无可用时诚实说明原因
    """
    # 先查完整性：半成品快照会产出误导性的「词表不兼容」报错。
    complete, why_incomplete = is_complete_snapshot(model_path)
    if not complete:
        return {
            "model_path": str(Path(model_path).expanduser()),
            "model_type": "", "architectures": [], "vocab_size": -1,
            "hidden_size": -1, "num_layers": -1, "size_class": "unknown",
            "candidates": [], "recommendation": None,
            "speculative_supported": False,
            "blocker": "incomplete_snapshot",
            "reason": f"模型目录不完整：{why_incomplete}",
        }

    info = read_model_info(model_path)
    report: dict = {
        "model_path": str(Path(model_path).expanduser()),
        "model_type": info.model_type,
        "architectures": info.architectures,
        "vocab_size": info.vocab_size,
        "hidden_size": info.hidden_size,
        "num_layers": info.num_layers,
        "size_class": info.size_class,
        "candidates": [],
        "recommendation": None,
        "speculative_supported": False,
        "reason": "",
    }

    if not info.model_type:
        report["reason"] = "读不到 config.json —— 不是有效的 MLX/HF 模型目录"
        return report

    cands = candidate_drafts(info)
    if not cands:
        report["reason"] = (
            f"model_type='{info.model_type}' 没有内置的同族草稿候选。"
            f"投机解码需要与 target 同 tokenizer 族的小模型，"
            f"该族目前未收录 —— 可手工在 DRAFT_CANDIDATES 中补充。"
        )
        _fill_universal_levers(report)
        return report

    for repo in cands:
        path = resolve_cached(repo)
        entry = {"repo": repo, "local_path": path, "usable": False,
                 "reason": "", "missing": False}
        if path is None:
            entry["reason"] = "本地缓存中没有（需先下载）"
            entry["missing"] = True
            report["candidates"].append(entry)
            continue
        cok, cwhy = is_complete_snapshot(path)
        if not cok:
            entry["reason"] = f"快照不完整（{cwhy}）—— 下载中断，需重新下载"
            report["candidates"].append(entry)
            continue
        ok, why = evaluate_draft(report["model_path"], path)
        entry["usable"] = ok
        entry["reason"] = why
        if ok:
            entry["draft_info"] = {
                "hidden_size": read_model_info(path).hidden_size,
                "num_layers": read_model_info(path).num_layers,
            }
        report["candidates"].append(entry)

    usable = [c for c in report["candidates"] if c["usable"]]
    if usable:
        # 选最小的可用草稿（hidden 最小 -> 最快 -> 收益最大）。
        best = min(usable, key=lambda c: c.get("draft_info", {}).get("hidden_size", 1 << 30))
        report["speculative_supported"] = True
        report["recommendation"] = {
            "draft_model": best["local_path"],
            "draft_repo": best["repo"],
            # nd 只是起点：它取决于 target/draft 相对速度，换模型必须重扫。
            # 3 是 Llama-3.1-8B + 3.2-1B 上实测出的 rejection 规则最优值。
            "num_draft_tokens": 3,
            "num_draft_tokens_high_temp": 2,
            "max_temp": 0.5,
            "accept_rule": "rejection",
            "nd_is_default_not_measured": True,
        }
        report["reason"] = "找到可用同族草稿"
    else:
        # 区分两种「不可用」，因为给用户的行动完全不同：
        #   结构性不可用 —— 下载也救不了，要换思路
        #   尚未下载     —— 下载后重跑即可
        # 混为一谈会让人以为「这模型没救」，而实际只是少个模型文件。
        incomplete = [c for c in report["candidates"]
                      if "快照不完整" in c.get("reason", "")]
        if incomplete:
            report["reason"] = (
                "候选草稿的快照不完整（下载中断），需重新下载："
                + ", ".join(c["repo"] for c in incomplete)
            )
            report["blocker"] = "not_downloaded"
            _fill_universal_levers(report)
            return report
        missing = [c for c in report["candidates"] if c.get("missing")]
        evaluated = [c for c in report["candidates"] if not c.get("missing")]
        if evaluated and all(not c["usable"] for c in evaluated):
            # 有候选、且实测判定不可用 -> 结构性原因
            structural = "; ".join(f"{c['repo']}: {c['reason']}" for c in evaluated)
            report["reason"] = (
                f"候选草稿经实测判定不可用（结构性原因，下载也无效）：{structural}"
            )
            report["blocker"] = "structural"
        elif missing:
            # 只是没下载 -> 可操作
            report["reason"] = (
                "本地缓存中没有可用的同族草稿。"
                f"需先下载候选之一后重跑：{', '.join(c['repo'] for c in missing)}"
            )
            report["blocker"] = "not_downloaded"
        else:
            report["reason"] = "找不到同族草稿候选"
            report["blocker"] = "no_candidate"
        _fill_universal_levers(report)
    return report


def _fill_universal_levers(report: dict) -> None:
    """投机不可用时，指出仍然通用的两个杠杆（诚实且有用）。"""
    report["universal_levers"] = {
        "prefix_cache": {
            "usable": True,
            "why": "多轮对话复用 KV 前缀；只用 trim_prompt_cache，与模型族无关",
            "note": "加速的是 TTFT（首 token），不是 decode 吞吐",
        },
        "kv_quant": {
            "usable": True,
            "why": "QuantizedKVCache 是 mlx_lm 通用能力，与模型族无关",
            "note": "主要收益是内存 footprint，不是吞吐",
        },
    }


def format_report(report: dict) -> str:
    """把探测结果渲染成人可读文本。"""
    L = []
    A = L.append
    A("=" * 62)
    A("gm-probe —— MLX 模型接入探测")
    A("=" * 62)
    A(f"模型      : {report['model_path']}")
    A(f"架构      : {report['model_type']}  {report['architectures']}")
    A(f"规模      : hidden={report['hidden_size']}  layers={report['num_layers']}"
      f"  vocab={report['vocab_size']}  ({report['size_class']})")
    A("")
    A("--- 同族草稿候选 ---")
    if not report["candidates"]:
        A("  (无候选)")
    for c in report["candidates"]:
        mark = "✅ 可用" if c["usable"] else "❌ 不可用"
        A(f"  {mark}  {c['repo']}")
        A(f"          {c['reason']}")
    A("")
    if report["speculative_supported"]:
        r = report["recommendation"]
        A("--- 推荐配置 ---")
        A(f"  draft_model : {r['draft_model']}")
        A(f"  nd          : {r['num_draft_tokens']} (低温) / "
          f"{r['num_draft_tokens_high_temp']} (高温)")
        A(f"  accept_rule : {r['accept_rule']}")
        # nd 的来源决定这句话 —— 实测过了就不该再说「未实测」，
        # 否则报告自相矛盾（第一版就是先打印这句、再打印实测结果）。
        if r.get("nd_is_default_not_measured", True):
            A("  🟨 nd 是**默认起点、尚未在本机实测**。最优 nd 取决于")
            A("     target/draft 的相对速度，换模型后应加 --sweep 重扫，")
            A("     否则可能踩到负收益（实测过 nd=4 在某些组合上会掉速）。")
        else:
            A(f"  ✅ nd 已在本机实测扫描得出（最优值为 {r.get('nd_sweep_best')}）。")
            A("     说明：本机无风扇、热态漂移大，扫描用轮转交错抵消，")
            A("     但绝对值不可跨运行比较 —— 判定依据是比值与 accept_len。")
    else:
        blocker = report.get("blocker", "structural")
        A("--- 结论 ---")
        if blocker == "incomplete_snapshot":
            A("  🟥 模型目录不完整，无法使用。")
            A(f"     {report['reason']}")
            A("")
            A("     这通常是下载中断导致的。若来自 HF cache，")
            A("     删除该快照目录后重新下载即可。")
        elif blocker == "not_downloaded":
            # 可操作的情况：不要说成「模型没救」，否则会误导。
            A("  🟨 暂时无法判定 —— 同族草稿尚未下载。")
            A(f"     {report['reason']}")
            A("")
            A("     下载后重跑本命令即可。这**不是**「该模型不支持加速」")
            A("     的结论 —— 只是本地缺一个模型文件。")
        elif blocker == "structural":
            A("  🟥 该模型不支持投机解码加速（结构性原因）。")
            A(f"     {report['reason']}")
            A("")
            A("     这是投机解码的数学前提，不是实现缺陷：")
            A("     收益 = 接受长度 / (1 + 草稿成本比 c)。")
            A("     若草稿不比 target 小，c >= 1，硬开投机一定更慢。")
        else:
            A("  🟥 没有可用的同族草稿候选。")
            A(f"     {report['reason']}")
        if "universal_levers" in report:
            A("")
            A("     仍有两个与模型族无关的杠杆可用（但加速的是 TTFT/内存）：")
            for k, v in report["universal_levers"].items():
                A(f"       - {k}: {v['why']}")
                A(f"         {v['note']}")
    A("=" * 62)
    return "\n".join(L)
