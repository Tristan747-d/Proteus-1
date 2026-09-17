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
| **Attachments** | Send text, code, CSV/JSON, PDF or docx alongside a message. Extraction happens **gateway-side**, so any OpenAI-compatible client gets it. |
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
from a template, adds the `proteus` command to your PATH, and optionally
builds the app. It is idempotent.

If you'd rather do it by hand:

```bash
pip install mlx-lm
cp models.json.template models.json   # then edit the @MODEL_DIR@ placeholder
python3 -m gm --config models.json
```

> ⚠️ **Keep this directory on a local disk, not iCloud.** A launchd service
> whose `WorkingDirectory` is inside iCloud deadlocks in fileprovider
> (`Errno 11 Resource deadlock avoided`) — running the same code from a
> terminal works fine, so the problem only appears *after* you install the
> service. `install.sh` and `proteus doctor` both check for this.

---

## Use

**Start everything (gateway + app)**

```bash
proteus startup
# → installs the launchd service on first run, starts it, opens the app
```

**The `proteus` command**

| Command | What it does |
|---|---|
| `proteus startup` | Start the gateway service **and** open the app |
| `proteus stop` | Stop the service (`KeepAlive` is released, so it stays down) |
| `proteus restart` | Restart the service |
| `proteus status` | Service state, available models, loaded model, recent request |
| `proteus logs [-f]` | Show (or follow) the gateway log |
| `proteus port [N]` | Show or change the gateway port (prompts to restart) |
| `proteus gui` | Open the app only |
| `proteus doctor` | Environment self-check (interpreter, model paths, plist) |
| `proteus install [--adopt]` | Install/refresh the launchd service |
| `proteus uninstall` | Remove the launchd service |

### Changing the port

Port **8320** is the default, not a constant. `models.json` → `server.port`
is the single source of truth; the CLI, the app and `tools/gw_bench.py` all
read it from there, so there is no second copy to drift out of sync.

```bash
proteus port              # show the current port and where it came from
proteus port 9000         # change it (validates + checks availability)
                          # then offers to restart the gateway
```

A port change does **not** take effect until the gateway restarts, since the
running process still holds the old socket — `proteus port` prompts for it
rather than leaving you with a gateway on a port you no longer expect. The app
re-reads `models.json` on launch, so it follows automatically; no GUI setting
to update.

Changing the port at install time:

```bash
PROTEUS_PORT=9000 ./install.sh
```

### Attachments

In the app, the paperclip button attaches files to your next message. You can
also send them from any client, since extraction is done **by the gateway**:

```python
import base64
data = base64.b64encode(open("report.pdf", "rb").read()).decode()
c.chat.completions.create(model="default", messages=[{
    "role": "user",
    "content": [
        {"type": "text", "text": "Summarise this."},
        {"type": "file", "file": {"name": "report.pdf", "data": data}},
    ],
}])
```

| Type | How it is handled |
|---|---|
| Text, code, CSV, JSON, YAML, Markdown, XML, HTML, … | Read directly (UTF-8, with GB18030/Big5 fallback) |
| `docx`, `doc`, `rtf`, `odt` | `textutil` (built into macOS — no extra dependency) |
| `pdf` | `pypdf` if installed, else a clear error telling you to install it |
| Anything else | Rejected **with a reason** — never silently dropped |

Limits: 20 MB per file, 16 000 characters per attachment and 24 000 characters
total per request. When a limit truncates content, the prompt says so
explicitly rather than quietly cutting your document in half.

> ⚠️ **This needs a text-capable model.** `Llama-3.1-8B-Instruct-4bit` has no
> vision, so images are refused rather than silently ignored. For images you
> would need a vision model (e.g. a Qwen-VL build) served by the same gateway.

Install PDF support into the gateway's interpreter:

```bash
$(dirname $(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' \
  ~/Library/LaunchAgents/com.tristan.gm.gateway.plist))"/pip" install pypdf
```

The gateway runs as a **launchd** service, so `KeepAlive` restarts it if it
crashes, and it starts at login. `proteus install` refuses to silently
overwrite a running service whose configuration differs — pass `--adopt` to
switch deliberately.

**Connect any agent client**

```bash
export OPENAI_BASE_URL="http://127.0.0.1:8320/v1"   # check `proteus port` if you changed it
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
  attachments.py         attachment text extraction (pdf/docx/text)
  autotune.py            model inspection + draft matching
  probe_cli.py           gm-probe implementation
ProteusStudio/         macOS app (SwiftUI)
  Sources/
project.yml            xcodegen manifest
Info.plist             app metadata (explicit; icon key needs it)
AppIcon-source.png     icon source (1254x1254); run ./make-icon.sh
AppIcon.icns           generated icon (do not edit by hand)
models.json.template   config template (paths are placeholders)
install.sh             one-shot setup
proteus                service CLI (startup/stop/status/logs/doctor)
make-icon.sh           rebuild AppIcon.icns from the source PNG
rebuild-app.sh         rebuild + install the app
tools/
  gw_bench.py          gateway benchmark with host-state guard
docs/                  the research record
```

---

## Documentation

| Document | Contents |
|---|---|
| [`docs/`](docs/) | The full Proteus research report — every phase, every negative result, every correction |
| [`docs/PROTEUS2_PHASE0_AUDIT.md`](docs/PROTEUS2_PHASE0_AUDIT.md) | **Proteus-2 Phase-0 audit** — what the current baseline actually is, which measurements can be trusted, and which cannot |

The research record is deliberately kept in full, including the conclusions
that were later overturned. If you want to know *why* this project does not
attempt ANE offload, or *why* it distrusts short benchmark runs on a fanless
Mac, that is where the evidence lives.

### Measuring

`tools/gw_bench.py` measures through the real HTTP surface and **refuses to
produce numbers when the host looks dirty** (swap > 1 GB or load1 > 5), because
memory pressure on this machine has been measured to pollute a benchmark
3–11×. Pass `--force` for indicative data only.

```bash
proteus startup
python3 tools/gw_bench.py --model proteus-1 --label baseline --rounds 3
```

### ⚠️ Known baseline caveat

`gpu-baseline` is **not** a bare MLX baseline: it also drops `kv_bits` from 8
to 0 (fp16 KV), so a `proteus-1` vs `gpu-baseline` difference mixes the
speculative-decoding gain together with the KV-quantisation gain. They cannot
be separated without an additional arm. See the Phase-0 audit, §3.

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
