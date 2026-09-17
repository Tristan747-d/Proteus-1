"""Cross-request prefix (KV) cache for the gm gateway.

Why this exists
---------------
Measured on this machine (proteus24, `prefix_matched.json`): in a multi-turn
chat, re-prefilling the whole history every turn dominates the request. At
ctx~4286 with 600 new tokens:

    TTFT   scratch 6.66s  ->  warm 1.17s     (5.72x)
    wall   scratch 8.50s  ->  warm 2.99s     (2.91x)

and prefill share grows with context (`ctx_sweep.json`): 30% at ctx 459 but
**88% at ctx 7179**. The gateway currently passes no `prompt_cache` at all, so
every turn re-prefills the entire history (O(N^2) work over a conversation).

How mlx_lm expects it to work (verified in source)
--------------------------------------------------
`generate_step`/`stream_generate` accept `prompt_cache` and forward it to
`generate_step`, which does:

    while total_prompt_tokens - prompt_processed_tokens > 1:   # prefill loop
        ...feed prompt[:n] into the cache...
    y, logprobs = _step(input_tokens=prompt)                  # last token

Crucially it prefills **whatever you hand it**. So when a cache already holds
the common prefix, the caller MUST pass only the UNCACHED suffix. Passing the
full prompt would re-prefill the prefix (no crash, but no saving either) and
would additionally desynchronise the cache.

Therefore:
    cached_len   = cache[0].offset        # authoritative, not arithmetic
    common       = true common prefix length between cached ids and new ids
    keep         = min(cached_len, common)
    trim by      = cached_len - keep      # if cache overshot the new prompt
    feed         = prompt_ids[keep:]      # only the uncached suffix

Using `cache[0].offset` (the real cache length) rather than assuming
"history is append-only" matters: a user can edit an earlier message, and
off-by-one here silently corrupts output.

Correctness expectation
-----------------------
Reusing a KV prefix is mathematically identical to prefilling it, so the
output distribution is unchanged. Empirically (`cache_diag_t1/t2.json`,
`prefix_long.log`) the tokens matched 10/10 and 6/6; the only observed
differences were floating-point tie flips at top1-top2 gap ~0.0156.

Thread-safety / lifetime
------------------------
One cache per session key, capped by `max_sessions` with simple FIFO eviction.
The backend is called from the server's request threads, so access is guarded
by a lock. Caches are dropped on model unload.
"""
from __future__ import annotations

import threading
from collections import OrderedDict


class PrefixCacheStore:
    """Session-keyed KV caches for cross-request prefix reuse."""

    def __init__(self, max_sessions: int = 8, max_total_tokens: int = 16384):
        self._max = max(1, int(max_sessions))
        self._store: "OrderedDict[str, list]" = OrderedDict()
        self._ids: "OrderedDict[str, list[int]]" = OrderedDict()
        self._lock = threading.Lock()
        # ⚠️ 必须同时限制**总 token 量**，不能只限制会话条数。
        # 实测事故：max_sessions=8 且每个会话是 ~5.6k token 的长上下文时，
        # 网关 phys_footprint 涨到 **12 GB**（`footprint <pid>` 实测），
        # 16 GB 机器被压进 swap。会话条数上限对「每条能有多长」毫无约束。
        # 这里按 token 数记账（KV 字节 ∝ token 数），超预算按 LRU 淘汰到
        # 预算内为止。0 = 不限制（旧行为）。
        self._max_total_tokens = max(0, int(max_total_tokens))

    def _tokens_of(self, key: str) -> int:
        ids = self._ids.get(key) or []
        return len(ids)

    def _total_tokens(self) -> int:
        return sum(len(v) for v in self._ids.values())

    def _evict_to_budget(self):
        """在持有锁的前提下，按 LRU 淘汰直到满足条数与 token 预算。"""
        while len(self._store) > self._max:
            k, _ = self._store.popitem(last=False)
            self._ids.pop(k, None)
        if self._max_total_tokens <= 0:
            return
        while self._store and self._total_tokens() > self._max_total_tokens:
            k, _ = self._store.popitem(last=False)
            self._ids.pop(k, None)

    # ---------------------------------------------------------------- lookup
    def get(self, key: str, prompt_ids: list[int]):
        """Return (cache, feed_ids, cached_len) or (None, prompt_ids, 0).

        `feed_ids` is the suffix that still needs prefill.
        """
        if not key:
            return None, prompt_ids, 0
        with self._lock:
            cache = self._store.get(key)
            old_ids = self._ids.get(key)
        if cache is None or old_ids is None:
            return None, prompt_ids, 0

        # authoritative cache length
        try:
            cached_len = int(cache[0].offset)
        except Exception:
            cached_len = 0
        if cached_len <= 0:
            return None, prompt_ids, 0

        # ⚠️ offset 是权威长度；old_ids 可能比它长（存的是「本应覆盖」的
        # 序列）。二者不一致时前缀比对会整体错位，从而复用一个长度对不上
        # 的陈旧 KV —— 实测表现为输出串位（问 alpha 答 beta）。这里统一
        # 以 offset 截断 old_ids 再比对。
        if len(old_ids) > cached_len:
            old_ids = old_ids[:cached_len]

        # real common prefix
        common = 0
        limit = min(cached_len, len(old_ids), len(prompt_ids))
        while common < limit and old_ids[common] == prompt_ids[common]:
            common += 1
        if common == 0:
            return None, prompt_ids, 0

        keep = min(cached_len, common)
        # ⚠️ 必须把 cache 裁回公共前缀长度！cache 里除了 prompt 还包含上一轮
        # **已生成的 token**（offset = prompt + generated），直接复用会让模型
        # 从「上一轮答案之后」继续写，而不是回答本轮问题。实测症状：同一个
        # 问题连问 4 次，第 1 次答 "Paris."，之后每次都在续写上一轮的 filler
        # 文本。裁剪后 cache 的尾部正好落在公共前缀处，与「重新 prefill 该
        # 前缀」严格等价。
        if cached_len > keep:
            try:
                trim_to(cache, cached_len, keep)
            except Exception:
                return None, prompt_ids, 0
        return cache, prompt_ids[keep:], keep

    # ---------------------------------------------------------------- update
    def put(self, key: str, cache, full_ids: list[int]):
        if not key:
            return
        with self._lock:
            self._store[key] = cache
            self._ids[key] = list(full_ids)
            self._store.move_to_end(key)
            self._ids.move_to_end(key)
            self._evict_to_budget()

    def drop(self, key: str | None = None):
        with self._lock:
            if key is None:
                self._store.clear()
                self._ids.clear()
            else:
                self._store.pop(key, None)
                self._ids.pop(key, None)

    def __len__(self):
        with self._lock:
            return len(self._store)


class SharedPrefixCacheStore(PrefixCacheStore):
    """跨 session 共享的公共前缀缓存（TTFT 的最大一块空白）。

    为什么需要它
    ------------
    线上的 `PrefixCacheStore` 按 session 键控，而网关的 session 缺省为空
    （OpenAI 兼容接口本无该字段）——即**默认不复用**。但真实聊天里
    system prompt / 工具说明 / 固定开头是**所有会话共享**的，每次新会话都
    把它整段重新 prefill 一遍。这是当前 TTFT 里最大的一块可消除重复计算：
    它不是「算得更快」，而是「根本不用再算」。

    与 session 键控的关系（安全性）
    ------------------------------
    共享缓存只在**前缀逐 token 完全相同**时命中，判定沿用父类的
    `old_ids[common] == prompt_ids[common]` 逐位比较。但仅靠「逐 token 相同」
    不够——这是本项目实测踩到的事故：

        A 会话: "Remember codeword: ZEBRA42. Reply OK."
        B 会话: "What codeword did I ask you to remember?"   (不同 session)
        => B 直接答出 "ZEBRA42"

    原因是两次请求的 chat template + 提问句式相似，公共前缀足够长，而共享槽
    存的是**整段会话**（prompt + 已生成 token），于是 A 的对话内容整个被 B
    复用。「前缀相同」不等于「可以共享」——前缀里只要含上一个会话的用户内容，
    复用就是泄露。

    ⇒ 本类**必须**配合 `max_shared_tokens` 使用：共享槽只允许覆盖前缀的前
    N 个 token（正确用法是设成 system prompt 的长度），超出 N 一律截断、只按
    session 精确键复用。`max_shared_tokens=0`（缺省）= **禁止共享**，此时本类
    退化为与父类完全一致的行为。

    风险控制三条：① 逐 token 前缀相等；② 共享长度硬上限 max_shared_tokens；
    ③ shared_slots 上限，避免长上下文吃满 16 GB 内存。
    """

    def __init__(self, max_sessions: int = 8, shared_slots: int = 2,
                 max_shared_tokens: int = 0, max_total_tokens: int = 16384):
        super().__init__(max_sessions=max_sessions,
                         max_total_tokens=max_total_tokens)
        # 全局共享槽：保存最近见过的公共前缀。slots>1 时按 LRU 保留多条，
        # 用于同时存在多个公共前缀（如两组不同 system prompt）的场景。
        self._shared: "OrderedDict[str, list]" = OrderedDict()
        self._shared_ids: "OrderedDict[str, list[int]]" = OrderedDict()
        self._shared_slots = max(1, int(shared_slots))
        # 0 = 禁止共享（安全缺省）。>0 = 共享槽最多覆盖前 N 个 token。
        self._max_shared = max(0, int(max_shared_tokens))

    def get(self, key: str, prompt_ids: list[int]):
        """先试 session 键，未命中再试共享前缀；返回命中最长者。"""
        cache, feed, hit = super().get(key, prompt_ids)

        best = (cache, feed, hit)
        if self._max_shared <= 0:
            return best  # 共享被禁用，退化为父类行为
        with self._lock:
            cands = list(self._shared.items())
            cand_ids = list(self._shared_ids.items())
        for (sk, scache), (_, sids) in zip(cands, cand_ids):
            c, f, h = self._match(scache, sids, prompt_ids)
            # 硬上限：共享命中长度绝不可超过 max_shared_tokens，否则就是用
            # 上一个会话的内容回答本次请求。
            if h > self._max_shared:
                h = self._max_shared
                f = prompt_ids[h:]
            if h > best[2]:
                best = (c, f, h)
        return best

    @staticmethod
    def _match(cache, old_ids, prompt_ids):
        """与父类 get 相同的命中逻辑，抽出以便在共享槽上复用。"""
        if cache is None or old_ids is None:
            return None, prompt_ids, 0
        try:
            cached_len = int(cache[0].offset)
        except Exception:
            cached_len = 0
        if cached_len <= 0:
            return None, prompt_ids, 0
        if len(old_ids) > cached_len:
            old_ids = old_ids[:cached_len]
        common = 0
        limit = min(cached_len, len(old_ids), len(prompt_ids))
        while common < limit and old_ids[common] == prompt_ids[common]:
            common += 1
        if common == 0:
            return None, prompt_ids, 0
        keep = min(cached_len, common)
        if cached_len > keep:
            try:
                trim_to(cache, cached_len, keep)
            except Exception:
                return None, prompt_ids, 0
        return cache, prompt_ids[keep:], keep

    def put(self, key: str, cache, full_ids: list[int]):
        super().put(key, cache, full_ids)
        if cache is None:
            return
        # 共享槽只保留「公共前缀最长」的那条：它对新请求的覆盖率最高。
        longest = max(self._shared_ids.values(), key=len, default=None)
        if longest is not None and len(full_ids) <= len(longest):
            return
        with self._lock:
            sk = f"__shared_{len(self._shared_ids)}"
            self._shared[sk] = cache
            self._shared_ids[sk] = list(full_ids)
            self._shared.move_to_end(sk)
            self._shared_ids.move_to_end(sk)
            while len(self._shared) > self._shared_slots:
                k, _ = self._shared.popitem(last=False)
                self._shared_ids.pop(k, None)

    def drop(self, key: str | None = None):
        super().drop(key)
        if key is None:
            with self._lock:
                self._shared.clear()
                self._shared_ids.clear()


def trim_to(cache, cached_len: int, keep: int):
    """Trim a cache that overshot the new prompt (in place)."""
    from mlx_lm.models.cache import trim_prompt_cache

    n = cached_len - keep
    if n > 0:
        trim_prompt_cache(cache, n)
    return cache
