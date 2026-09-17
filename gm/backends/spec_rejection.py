"""Speculative decoding with Leviathan-style REJECTION SAMPLING.

Why this exists
---------------
`mlx_lm/generate.py:624-630` accepts a draft token on an exact id match:

    tn, dtn, lpn = tokens[n], draft_tokens[n], logprobs[n]
    if tn != dtn: break

Textbook rejection sampling accepts with probability min(1, p(x)/q(x)) and, on
rejection, resamples from the residual (p - q)_+.

Both rules leave the target distribution UNCHANGED -- the emitted token is
always a genuine draw from p; the draft only decides how far ahead we get per
round. Their acceptance rates differ though:

    exact match        : sum_x p(x) q(x)
    rejection sampling : sum_x min(p(x), q(x))

and since p,q in [0,1],  p*q <= min(p,q)  ALWAYS. Measured on this machine
(proteus24 `accept_rule_headroom.json`, 120 teacher-forced positions):

    exact-match accept : median 0.724
    rejection accept   : median 0.872        <- gap +0.148

CAVEAT (measured, not assumed): at temperature 0 the distribution p degenerates
to one-hot, so rejection sampling collapses onto the same rule as exact match
(gap on greedy-agreeing positions: +0.010, i.e. noise). The gain lives at
temperature > 0 -- which is exactly the gateway default (0.7).

Measured benefit (proteus24, two independent campaigns, temp=0.7, 200 tokens,
paired + order-flipped, `spec_rejection_c{1,2}.json`):

    nd=2   exact 1.126 / 1.094   ->  rejection 1.181 / 1.192
    nd=3   exact 1.004 / 1.007   ->  rejection 1.210 / 1.249   <- best
    nd=4   exact 1.031 / 1.036   ->  rejection 1.101 / 1.118

Distribution fidelity verified empirically (600 trials, single position):
    baseline  max|emp - p0| = 0.0049   (pure sampling noise)
    rejection max|emp - p0| = 0.0101   (same order => unbiased)

Implementation notes
--------------------
Cache bookkeeping mirrors mlx_lm exactly, which matters -- getting it wrong
silently corrupts output:
  * target cache is fed [prev] + k draft tokens   (k+1 positions)
  * draft  cache is fed prev, d_0 .. d_{k-2}      (k positions; d_{k-1} is
    generated but NOT yet consumed)
  * on rejection at j : trim target by (k-j), trim draft by max(k-j-1, 0)
  * on full acceptance: trim 0; the draft must then re-consume [d_{k-1}, bonus]
    which is why a `lead` token is carried into the next round.

One subtlety that bit during development: in the exact-match branch we must
emit the ALREADY-DRAWN target token on rejection, never a fresh draw.
A fresh draw gives P(x) = p(x)(q(x) + 1 - A), which is biased (it moved
p=[.8618,.1382] to [.9094,.0906] in validation).
"""
from __future__ import annotations

import time

import numpy as np
import mlx.core as mx
from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache


def _sync(cache):
    states = [c.state for c in cache if getattr(c, "state", None) is not None]
    if states:
        mx.eval(states)


def _probs(logits_row, temp: float) -> np.ndarray:
    """Softmax of one logits row, optionally temperature-scaled."""
    lg = np.array(logits_row.astype(mx.float32))
    if temp > 0:
        lg = lg / temp
    lg = lg - np.max(lg)
    e = np.exp(lg)
    return e / e.sum()


def _draw(p: np.ndarray, temp: float, rng):
    if temp <= 0:
        return int(np.argmax(p))
    return int(rng.choice(p.shape[0], p=p))


def _prefill(model, cache, ids, step: int = 512):
    n = len(ids)
    i = 0
    while i < n:
        j = min(n, i + step)
        model(mx.array([ids[i:j]]), cache=cache)
        _sync(cache)
        i = j


def stream_rejection(model, draft, prompt_ids, max_tokens, temperature,
                     num_draft_tokens, seed=None, abort=None,
                     prompt_cache=None, round_stats=None):
    """Generate with rejection-sampled speculative decoding.

    Yields (token_id, from_draft). Output is distributed exactly as the
    target model's own sampling at `temperature`.

    If `prompt_cache` is given, it is used for the TARGET instead of a fresh
    cache, and `prompt_ids` MUST then contain only the uncached suffix (the
    caller has already trimmed to the common prefix). The draft still gets a
    fresh cache seeded from that same suffix: the draft's prefix state is not
    reused, which costs one extra draft prefill of the suffix but keeps the
    two caches trivially consistent and avoids a subtle trim bug.

    `round_stats` (optional list) receives one entry per verify round with the
    round's accepted length and wall time. This is what makes ITL interpretable:
    ITL under speculative decoding is not a constant, it is a sawtooth whose
    period IS the verify round, so the round timing is the diagnostic.
    """
    rng = np.random.default_rng(seed)
    temp = float(temperature or 0.0)
    greedy = temp <= 0
    k0 = max(1, int(num_draft_tokens))
    _r0 = time.time()

    tcache = prompt_cache if prompt_cache is not None else make_prompt_cache(model)
    # 本函数自己管 draft cache，故只取 target 那部分。调用方可能传
    # 「target+draft 合并列表」（mlx_lm 原生投机路径要求该布局，见
    # mlx_lm_backend._make_kv_cache 的说明），这里按层数切掉 draft 尾巴；
    # 否则 target 前向会拿到多余的层。短于层数时按原样使用。
    if tcache is not None and len(tcache) > len(model.layers):
        tcache = tcache[: len(model.layers)]
    dcache = make_prompt_cache(draft)
    # prompt_ids 至少要有 1 个 token：下面用 prompt_ids[:-1] 和 prompt_ids[-1]
    # 两段，空输入会让 prefill reshape 报错（[reshape] Cannot infer the shape
    # of an empty array）。
    if not prompt_ids:
        raise ValueError("stream_rejection: prompt_ids is empty")
    _prefill(model, tcache, prompt_ids[:-1])
    _prefill(draft, dcache, prompt_ids[:-1])

    prev = prompt_ids[-1]
    lead = []
    emitted = 0

    while emitted < max_tokens:
        if abort is not None and abort.is_set():
            return
        k = min(k0, max_tokens - emitted)

        # ---- draft proposes k tokens, keeping each proposal distribution
        if lead:
            draft(mx.array([lead]), cache=dcache)
            _sync(dcache)
        cur = prev
        d_toks, d_probs = [], []
        for _ in range(k):
            dl = draft(mx.array([[cur]]), cache=dcache)
            mx.eval(dl)
            q = _probs(dl[0, -1], temp)
            t = _draw(q, temp, rng)
            d_toks.append(t)
            d_probs.append(q)
            cur = t
        lead = []

        # ---- target scores the whole window in ONE forward
        seq = mx.array([[prev] + d_toks])
        tl = model(seq, cache=tcache)
        mx.eval(tl)

        j = 0
        rejected = False
        last = prev
        # 本轮产出的 token 先攒起来，等本轮结束再一次性交出去。
        # 理由（ITL 锯齿）：验证阶段各 token 的接受判定是纯主机端计算，几乎
        # 不耗时；真正的成本是上面那一次 8B 前向（数十 ms）。边验证边 yield
        # 会让用户先收到一个「瞬时连发 a+1 个 token」的脉冲，再干等下一次
        # 前向 —— ITL 表现为 p50≈1ms / p95≈60ms 的锯齿。按 round 边界对齐
        # 交付后，token 的到达节拍与该 round 的真实计算成本对齐，锯齿被抹平。
        pending = []
        for i in range(k):
            p = _probs(tl[0, i], temp)
            x = d_toks[i]
            if greedy:
                ok = (int(np.argmax(p)) == x)
            else:
                ok = rng.random() < min(1.0, p[x] / max(d_probs[i][x], 1e-12))
            if ok:
                j += 1
                emitted += 1
                last = x
                pending.append(x)
                if emitted >= max_tokens:
                    break
                continue
            # rejected -> resample from the residual so the draw is exactly ~p
            if greedy:
                tok = int(np.argmax(p))
            else:
                resid = np.maximum(p - d_probs[i], 0.0)
                s = resid.sum()
                if s <= 1e-12:
                    resid = p
                    s = resid.sum()
                tok = int(rng.choice(resid.shape[0], p=resid / s))
            emitted += 1
            last = tok
            rejected = True
            pending.append(tok)
            break

        if not rejected and emitted < max_tokens:
            # all k accepted -> bonus token from the (k+1)-th distribution
            p = _probs(tl[0, k], temp)
            tok = _draw(p, temp, rng)
            emitted += 1
            last = tok
            pending.append(tok)

        # ---- rewind both caches to the end of the accepted prefix
        trim_prompt_cache(tcache, k - j)
        trim_prompt_cache(dcache, max(k - j - 1, 0))
        prev = last
        if not rejected and k > 0:
            lead = [d_toks[-1]]

        # 先记本轮的**纯计算耗时**再 yield：若在 yield 之后读 time.time()，
        # 调用方为平滑而做的 sleep 会被算进「轮耗时」，形成正反馈、越睡越久
        # （实测把 TPOT 从 29ms 推成 214ms、墙钟 3.5s → 15.5s）。这个
        # 先记后 yield 的顺序必须保留，它是轮耗时统计正确的前提。
        round_ms = (time.time() - _r0) * 1000.0

        # ---- round 边界交付：本轮 token 一次性交出
        for _tok in pending:
            yield (_tok, False)

        # 记录本轮接受长度与**纯计算**耗时（不含调用方的平滑 sleep）。
        if round_stats is not None:
            round_stats.append({
                "accepted": int(j) + (0 if rejected else 1),
                "k": int(k),
                "ms": round_ms,
                "rejected": bool(rejected),
            })
        _r0 = time.time()
