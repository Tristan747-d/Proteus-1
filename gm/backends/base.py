"""后端适配器接口与注册表。

扩展方式：实现 Backend 子类，用 @register_backend("runtime名") 注册，
然后在 models.json 里把某模型的 runtime 指向它。核心代码零改动。
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Callable, Dict, Iterator, List, Optional

from ..registry import ModelEntry


@dataclass
class GenOptions:
    """一次生成的全部采样参数（已按注册表默认值与上限收敛）。"""

    max_tokens: int = 512
    temperature: float = 0.7
    top_p: float = 1.0
    top_k: int = 0
    repetition_penalty: Optional[float] = None
    stop: List[str] = field(default_factory=list)
    seed: Optional[int] = None
    abort: Optional["object"] = None  # threading.Event，客户端断开时置位
    # 会话标识。跨请求 prefix cache 按它键控；为空则不复用（避免不同用户
    # 的对话互相命中，那是正确性事故）。OpenAI 兼容接口本无此字段，
    # 由 gm 从请求体 session/user 或 HTTP 头 X-Session-Id 取，缺省为空。
    session: Optional[str] = None


@dataclass
class Chunk:
    text: str
    finish_reason: Optional[str] = None  # None=未结束；stop/length/aborted


@dataclass
class GenMeta:
    prompt_tokens: int = 0
    completion_tokens: int = 0
    finish_reason: str = "stop"
    elapsed_s: float = 0.0
    # 推测解码（speculative decoding）观测字段。默认关闭即为 False/0，
    # 便于从 /stats 或响应元数据里直接判断本次生成走的哪条路径。
    speculative: bool = False
    num_draft_tokens: int = 0
    # 接受规则："exact"（mlx_lm 原生精确匹配）或 "rejection"（拒绝采样）。
    # 两者输出分布相同，仅接受率不同；便于 /stats 确认实际走了哪条路径。
    accept_rule: str = "exact"
    # 跨请求 prefix cache 观测：本轮复用了多少 prompt token（0=未命中）。
    prefix_cached_tokens: int = 0
    # ---- 延迟分解埋点 -------------------------------------------------
    # 用户感知的三个指标此前完全没有度量：网关只上报 token 数与均值 tps，
    # 而均值 tps 会把投机解码的「锯齿式 ITL」完全抹平（一个 verify round
    # 内 a+1 个 token 间隔≈0，round 之间隔一次完整 8B 前向）。没有埋点就
    # 无法判断 ITL/TTFT 的优化是否真的生效，所以先补齐再谈优化。
    #
    # ttft_s        : 请求开始 -> 首个可见文本 chunk。用户在等的就是它。
    # prefill_s     : 请求开始 -> 首 token 落地（含 prefix cache 命中后的
    #                 剩余 prefill），= ttft 的主体。
    # itl_ms        : 相邻 chunk 的间隔（Inter-Token Latency），按到达顺序。
    #                 投机解码下它不是常数，看 p50/p95 才有意义。
    # tpot_s        : (elapsed_s - ttft_s) / max(completion_tokens - 1, 1)，
    #                 即首 token 之后的每 token 平均耗时。
    ttft_s: float = 0.0
    prefill_s: float = 0.0
    tpot_s: float = 0.0
    itl_ms: List[float] = field(default_factory=list)
    # 投机解码的每轮接受长度（accepted tokens per verify round）。它与
    # ITL 锯齿直接相关：接受越长，一次前向摊薄的 token 越多。
    accept_lens: List[int] = field(default_factory=list)

    @property
    def tps(self) -> float:
        return self.completion_tokens / self.elapsed_s if self.elapsed_s > 0 else 0.0

    @staticmethod
    def _pct(xs: List[float], q: float) -> float:
        if not xs:
            return 0.0
        s = sorted(xs)
        i = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
        return float(s[i])

    def latency_stats(self) -> dict:
        """TTFT/ITL/TPOT 汇总，供 /stats 与 benchmark 直接读取。"""
        return {
            "ttft_s": round(self.ttft_s, 4),
            "prefill_s": round(self.prefill_s, 4),
            "tpot_s": round(self.tpot_s, 6),
            "itl_p50_ms": round(self._pct(self.itl_ms, 0.50), 3),
            "itl_p95_ms": round(self._pct(self.itl_ms, 0.95), 3),
            "itl_max_ms": round(max(self.itl_ms), 3) if self.itl_ms else 0.0,
            "itl_n": len(self.itl_ms),
            "accept_len_median": (
                self._pct([float(x) for x in self.accept_lens], 0.50)
            ),
            "accept_rounds": len(self.accept_lens),
        }


class Backend(ABC):
    """单个已配置模型的运行时适配器。"""

    def __init__(self, entry: ModelEntry):
        self.entry = entry
        self._loaded = False

    @property
    def loaded(self) -> bool:
        return self._loaded

    @abstractmethod
    def load(self) -> None: ...

    @abstractmethod
    def unload(self) -> None: ...

    @abstractmethod
    def chat_stream(self, messages: List[dict], opts: GenOptions) -> Iterator[Chunk]:
        """OpenAI 风格 messages → 流式 Chunk。"""

    @abstractmethod
    def raw_stream(self, prompt: str, opts: GenOptions) -> Iterator[Chunk]:
        """原始 prompt 文本 → 流式 Chunk（/v1/completions 用）。"""


BACKENDS: Dict[str, Callable[[ModelEntry], Backend]] = {}


def register_backend(runtime: str) -> Callable:
    def deco(cls):
        BACKENDS[runtime] = cls
        return cls

    return deco


def create_backend(entry: ModelEntry) -> Backend:
    if entry.runtime not in BACKENDS:
        raise KeyError(
            f"no backend registered for runtime '{entry.runtime}' "
            f"(available: {', '.join(sorted(BACKENDS))})"
        )
    return BACKENDS[entry.runtime](entry)
