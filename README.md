# Proteus Studio

**A local LLM gateway for Apple Silicon, with a native macOS app.**

Proteus Studio serves any MLX model over an OpenAI-compatible HTTP endpoint,
and gives you a desktop app to chat with it. It comes out of the Proteus
research project, which spent considerable effort establishing what *doesn't*
work on the Apple Neural Engine — see [`docs/`](docs/) for the full record.

---

## What it does

| | |
|---|---|
| **OpenAI-compatible API** | `POST /v1/chat/completions` with SSE streaming. Any agent client that supports a custom `base_url` can connect — no changes needed. |
| **Two execution schemes** | **Proteus-1** (speculative decoding + prefix cache + int8 KV) and **GPU** (the bare MLX baseline), switchable per request. |
| **Model onboarding** | `gm-probe` inspects a model, finds a compatible draft, verifies tokenizer compatibility, and measures the best `n_draft` — in one command. |
| **Native GUI** | SwiftUI app: chat with message bubbles and live metrics, model setup, and a service page showing how external clients connect. |

**Measured on M5 / 16 GB** — decode throughput, `proteus-1` vs `gpu-baseline`:

```
proteus-1      ~32 tok/s      speculative=True
gpu-baseline   ~24 tok/s      speculative=False
```

---

## Requirements

- Apple Silicon Mac (arm64 — MLX and ANE both require it)
- macOS 14+
- Python 3.11+
- `pip install mlx-lm`
- For the GUI: Xcode 15+ and `xcodegen`

---

## Install

```bash
./install.sh
```

The script checks dependencies, finds your model, generates `models.json`
from a template, and optionally builds the app. It is idempotent.

If you'd rather do it by hand:

```bash
pip install mlx-lm
cp models.json.template models.json   # then edit the @MODEL_DIR@ placeholder
python3 -m gm --config models.json
```

---

## Use

**Start the gateway**

```bash
python3 -m gm --config models.json
# → http://127.0.0.1:8320
```

**Connect any agent client**

```bash
export OPENAI_BASE_URL="http://127.0.0.1:8320/v1"
export OPENAI_API_KEY="local"      # the gateway is local-only; no key check
```

```python
from openai import OpenAI
c = OpenAI(base_url="http://127.0.0.1:8320/v1", api_key="local")
c.chat.completions.create(model="default", messages=[...])
```

**Probe a new model**

```bash
./gm-probe /path/to/model             # read-only inspection
./gm-probe /path/to/model --sweep     # also measure n_draft
./gm-probe /path/to/model --write     # write the config (backs up first)
```

---

## An honest limitation

**Speculative decoding cannot speed up every model.** The gain is

```
speedup = accepted_tokens / (1 + c),    c = draft_time / target_time
```

so it requires `c < 1` — the draft must be **smaller** than the target. Large
models (8B and up) have small same-family siblings and benefit. **Small models
(0.5B–3B) do not**: there is no smaller draft to use, so `c ≥ 1` and enabling
it makes things slower.

`gm-probe` reports this plainly instead of configuring a draft that looks like
a speedup but isn't. For models in that category it points at the two levers
that *do* apply to any model — prefix caching and int8 KV — while noting that
they improve TTFT and memory, not decode throughput.

---

## Layout

```
gm/                    gateway (Python, stdlib HTTP + mlx-lm in-process)
  server.py              HTTP layer
  engine.py              model lifecycle, generation lock
  backends/
    mlx_lm_backend.py    the workhorse
    spec_rejection.py    rejection-sampling speculative loop
    prefix_cache.py      cross-request KV reuse
  autotune.py            model inspection + draft matching
  probe_cli.py           gm-probe implementation
ProteusStudio/         macOS app (SwiftUI)
  Sources/
project.yml            xcodegen manifest
models.json.template   config template (paths are placeholders)
install.sh             one-shot setup
docs/                  the research record
```

---

## Documentation

| Document | Contents |
|---|---|
| [`docs/`](docs/) | The full Proteus research report — every phase, every negative result, every correction |

The research record is deliberately kept in full, including the conclusions
that were later overturned. If you want to know *why* this project does not
attempt ANE offload, or *why* it distrusts short benchmark runs on a fanless
Mac, that is where the evidence lives.

---

## Testing status

Be aware of what has and hasn't been verified before you rely on this:

- ✅ Gateway: exercised end-to-end, including concurrent access during long
  streaming responses.
- ✅ `gm-probe`: verified against real tokenizers, with positive and negative
  controls.
- ⚠️ **GUI: compiled and smoke-tested, but not visually verified.** Layout
  issues may remain.

---

## License

**MIT** — see [`LICENSE`](LICENSE).

Third-party attribution is in [`NOTICE.md`](NOTICE.md). Notably, ANEForge
(MIT) and Swiftlet (Apache 2.0) informed the research but **no code from
either is bundled** — see the notice for specifics.
