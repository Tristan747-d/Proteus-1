# Third-Party Notices

Proteus Studio is licensed under the **MIT License** (see `LICENSE`).

This project was informed by, and in part built upon, the work listed below.
Each entry states precisely **how** it was used, because the distinction
between "studied for methodology" and "code incorporated" matters for
compliance.

---

## ANEForge

- **License**: MIT License — Copyright (c) 2026 Spencer H. Bryngelson
- **Upstream**: https://github.com/sbryngelson/ANEForge
- **Used for**: Direct Apple Neural Engine (ANE) access research.

**How it was used.** During the Proteus-1 / Proteus-2 investigation, ANEForge
provided the only practical path to drive the Apple Neural Engine **without**
going through CoreML. Its `e5rt` dispatch shim (which loads Apple's private
`Espresso.framework`) made it possible to test whether a real `group_q4`
quantized GEMM could be expressed on the ANE at all, and to measure the ANE's
weight-streaming bandwidth independently of CoreML's scheduling decisions.

**What this means for the release.** ANEForge is **not** a runtime dependency
of the shipped gateway or GUI — no ANEForge code is bundled, imported, or
required. It is credited here because the *experimental conclusions* recorded
in the accompanying technical report (in particular the ANE bandwidth and
compute-ceiling measurements) could not have been obtained without it.

> ⚠️ **Note on private frameworks.** ANEForge relies on private Apple symbols
> that may change without notice. If you build on that part of this work,
> review ANEForge's own documentation and disclaimers first.

---

## Swiftlet

- **License**: Apache License 2.0
- **Upstream**: https://github.com/leonickson1/Swiftlet
- **Used for**: Cross-project validation of the "data movement, not compute"
  bottleneck thesis.

**How it was used.** Swiftlet is a Swift + Metal runtime for Qwen MoE models
that streams routed experts from SSD. It was **not** incorporated into this
project — it targets a different architecture (sparse MoE) on a different
execution path (pure GPU, no ANE). It is credited because it independently
reached the same conclusion this project did by a different route: that
inference throughput is bound by **data movement**, not arithmetic.

Two of its findings cross-validate measurements made here:

- Swiftlet's lineage (colibrì) measured that a spinning CPU can throttle the
  GPU by ~39% through the shared power envelope; this project independently
  measured ~29% from a pure host CPU busy-wait.
- Swiftlet's design notes list quantized KV cache as a dead end; this project's
  own measurements reached the same conclusion independently (structural
  ceiling of 1.013× at 1K context).

**What this means for the release.** No Swiftlet code is bundled or required.
Attribution is given because its published findings were used as corroborating
evidence in the project's methodology documentation.

---

## mlx-lm

- **License**: MIT License — Copyright Apple Inc.
- **Upstream**: https://github.com/ml-explore/mlx-lm

**How it is used.** This **is** a genuine runtime dependency. The gateway
loads models and generates text through `mlx_lm`; the speculative-decoding
loop and the prefix-cache implementation call `mlx_lm` primitives
(`make_prompt_cache`, `trim_prompt_cache`, `stream_generate`). Install it via
`pip install mlx-lm`.

---

## pypdf

- **License**: BSD 3-Clause License
- **Upstream**: https://github.com/py-pdf/pypdf

**How it is used.** This is an **optional** dependency, used only by the
attachment feature (`gm/attachments.py`) to extract text from PDFs.

**What this means for the release.** No pypdf code is bundled. Without it, PDF
attachments are refused with a message telling you to install it; every other
attachment type (text, code, CSV/JSON, docx/rtf via macOS `textutil`) keeps
working. `install.sh` reports whether it is present. The other extraction paths
use only the Python standard library and macOS built-ins.

---

## Apple frameworks

This project uses **CoreML / coremltools** (Apple) and **MLX** (Apple) as
platform dependencies. They are not bundled. Their own terms apply.

The Apple Neural Engine is accessed in the historical research described in
`docs/` via private, undocumented interfaces. **Nothing in the shipped
gateway depends on those interfaces.**

---

## Models

No model weights are distributed with this project. You supply your own
`Llama-3.1-8B-Instruct-4bit` (and optionally a small same-family draft model
such as `Llama-3.2-1B-Instruct-4bit`). Model licenses are governed by their
respective publishers — see the Meta Llama license for Llama models.

---

## Summary table

| Project | License | Relationship |
|---|---|---|
| **mlx-lm** | MIT | **Runtime dependency** |
| **pypdf** | BSD 3-Clause | **Optional** — PDF attachments only |
| MLX | MIT | Platform dependency |
| CoreML / coremltools | Apple terms | Platform dependency |
| **ANEForge** | MIT | Research tool — conclusions credited, **no code bundled** |
| **Swiftlet** | Apache 2.0 | Reference — conclusions credited, **no code bundled** |
