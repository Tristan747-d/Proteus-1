# Proteus-2 Phase-0 — 可信基线审计

> **审计日期**：2026-09-17
> **审计者**：Proteus-2 Phase-0
> **范围**：只读。**未修改任何源码、配置或 plist。**
> **方法**：全部结论指向具体文件与行号，或指向本次会话的实机探测。
> 凡无法用代码或实测支撑的，一律标 `UNVERIFIED`，不做推测性补全。

---

## 0. 审计结论（三色）

🟥 **当前不存在可信基线。** 不是因为指标不好，而是因为**测量装置本身有三个已证实的缺陷**，且其中两个会让任何 A/B 得出反向结论。

🟥 **最严重发现：`gpu-baseline` 不是 baseline。** 它不是「关掉优化的原生 MLX」，它是「关掉优化 **并且** 同时把 KV 从 int8 降回 fp16 且禁用 prefix cache」的**另一个优化方案**。用它做分母会系统性高估 proteus-1 的收益。

🟨 **第二个发现：生产配置与已封版结论不一致**（`nd=2` 有效、`nd=3` 配置），且**实际运行的解释器与 plist 记录的完全不同**。

---

## 1. 当前架构

### 1.1 实际运行实体（探测得到，非文档转述）

| 项 | 实测值 | 来源 |
|---|---|---|
| PID | 36590，PPID=1（launchd 托管） | `ps -p 36590` |
| 启动时刻 | 2026-09-16 23:51:41 | `ps -o lstart` |
| **解释器** | `/Users/tristan/ANEProbe/P6Model/phase4/.venv/bin/python`（**3.11.15**） | `ps` + `python -V` |
| **工作目录** | `/Users/tristan/GeneralModel`（**本地**） | `launchctl print` |
| 生效 plist | `~/Library/LaunchAgents/com.tristan.gm.gateway.plist` | `launchctl print` |
| 监听 | `127.0.0.1:8320` | `curl` 200 |
| mlx / mlx_lm | mlx 0.32.2 / mlx_lm 0.31.3 | venv 内 `import` |
| 已加载模型 | `proteus-1`（`max_resident=1`） | `/stats` |

### 1.2 分层

```
server.py      ThreadingHTTPServer + daemon_threads（server.py:354-358）
               HTTP 连接处理并发；生成由 gen_lock 串行（server.py:227, 301）
engine.py      ModelManager：LRU(max_resident=1)、gen_lock、last_meta
registry.py    models.json → ModelEntry/ServerConfig，alias 解析
backends/
  mlx_lm_backend.py   生成主干：温度闸门 → nd 选择 → prefix cache → 分流
  spec_rejection.py   Leviathan 拒绝采样投机循环（自研）
  prefix_cache.py     跨请求 KV 复用，session 键控 + 可选共享槽
```

**关键结构事实**：`gen_lock` 是**全局单锁**，不分模型（`engine.py:19`）。即两个模型交替请求会互相排队——与 `max_resident=1` 叠加后，"双方案对照"在**同一个网关进程内不可能并行**。

---

## 2. `proteus-1` 到底实现了什么

`models.json`（`~/GeneralModel/models.json`）声明 + 代码路径核对：

| # | 优化 | 配置值 | 代码落点 | 是否真有分支 |
|---|---|---|---|---|
| 1 | 投机解码 | `enabled=true` | `mlx_lm_backend.py:448, 453-455` | ✅ |
| 2 | **拒绝采样接受规则** | `accept_rule="rejection"` | `mlx_lm_backend.py:474-535` → `spec_rejection.stream_rejection` | ✅ 自研，非 mlx_lm 原生 |
| 3 | 温度分流 nd | `nd=3` / `nd_high_temp=2` / `max_temp=0.5` | `_spec_ndraft_for` (`:164-208`) | ⚠️ **当前配置下失效，见 §6.1** |
| 4 | 长上下文收敛 nd | `long_ctx_tokens=4096` | `_spec_ndraft_for_ctx` (`:210-226`) | ✅ 生效 |
| 5 | prefix cache | `enabled=true, max_sessions=8` | `:427-445, 617-642` | ✅ |
| 6 | **KV int8 量化** | `kv_bits=8, kv_group_size=64` | `_make_kv_cache` (`:88-133`) | ✅ |
| 7 | tokenizer 兼容闸门 | 隐式 | `_tokenizers_compatible` (`:692-757`) | ✅ 正确性所必需 |
| 8 | TTFT/ITL/TPOT 埋点 | 隐式 | `base.py:87-101` | ✅ 观测 |

**真正区别于 vanilla mlx_lm 的是 2、5、6、7 四项**（1 是 mlx_lm 原生能力；3/4 是参数策略）。

### 2.1 实测确认这些确实在跑

```
turn 1: prompt_tokens 55  prefix_cached_tokens  0  ttft 0.6778s  spec True  nd 2  rule rejection
turn 2: prompt_tokens 55  prefix_cached_tokens 54  ttft 0.0698s  spec True  nd 2  rule rejection
```
→ prefix cache **命中 54/55**，TTFT **9.7×**。`accept_rule=rejection` 与 `speculative=true` 均已在 `/stats` 中回报，非静默降级。

---

## 3. `gpu-baseline` vs `proteus-1` 的真实差异

### 🟥 3.1 核心结论：这不是「优化 on/off」，是「方案 A vs 方案 B」

| 维度 | `proteus-1` | `gpu-baseline` | 差异性质 |
|---|---|---|---|
| `speculative.enabled` | true | **false** | **优化开关** ✅ |
| `prefix_cache.enabled` | true | **false** | **优化开关** ✅ |
| `prefix_cache.kv_bits` | **8** | **0**（fp16 KV） | 🟥 **不是开关，是改变了数值精度与 KV 字节数** |
| `draft_model` / `num_draft_tokens` / `max_temp` 等 | 有值 | **仍有值**（完整保留） | 死配置，仅因 `enabled=false` 未被读取 |

`kv_bits: 0 → 8` 不是"关掉一个优化"，而是把 KV cache 从 fp16 换成 int8。这**同时**改变：
1. **KV 的字节数**（int8 = fp16 的一半）→ 影响内存流量，而 decode 是本项目认定的 DRAM 带宽受限区间；
2. **KV 的数值内容**（量化误差）。

⇒ 二者之差**同时**包含「投机收益」和「KV 量化收益」两个不可分离的量。**用 `gpu-baseline` 做分母算出的任何 speedup 都系统性偏高。**

**旁证**：HANDOFF/README 宣称的 `~32 tok/s` vs `~24 tok/s`（≈1.33×）**高于**报告 §18.1 对同一改动给出的 `1.284×`。这个差额与"分母被削弱"的方向一致。（此关联为**推断**，非实测归因，故标 🟨。）

### 3.2 缺失的第三臂

要做「优化的净贡献」必须有一个真 baseline：

| 臂 | speculative | prefix_cache | kv_bits | 用途 |
|---|---|---|---|---|
| `gpu-baseline`（现有） | off | off | **0** | 🟥 混入 KV 差异 |
| **`gpu-fp16kv`（缺失）** | off | off | **8** | 隔离投机收益所必需 |
| **`gpu-noprefix`（缺失）** | off | off | 8，但走全程 prefill | 隔离 prefix cache 收益 |
| `proteus-1` | on | on | 8 | — |

**当前 2×2 因子设计缺 3 格中的至少 2 格，主效应与交互项完全不可分离。**

---

## 4. 当前 benchmark 的混淆

### 🟥 4.1 现役脚本**跑不起来**（已实测）

生产 benchmark 脚本（`.../04_Proteus24_更正链/scripts/gw_bench_nd2.py:41`、`gw_bench_ttft.py:36`）硬编码：

```python
"model": "llama-3.1-8b-4bit",
```

实机探测：
```
model='llama-3.1-8b-4bit' -> HTTP 404
model='proteus-1'         -> HTTP 200
model='default'           -> HTTP 200
```
⇒ 模型的 name 已从 `llama-3.1-8b-4bit` 改为 `proteus-1`/`gpu-baseline`，**脚本未同步**。
**当前不存在一个能直接跑出生产数字的 benchmark。** 所有历史 `gw_bench_*.json` 都是在旧 name 下产出的。

### 🟥 4.2 静默降级：benchmark 读的是「全局最后一条」

`gw_bench_ttft.py:106` 在请求后读 `/stats` 的 `last_meta`。而 `engine.py:21` 的 `last_meta` 是**整个 manager 的唯一字段**，任何并发请求都会覆盖它。

⇒ 在网关有其它客户端（**当前 GUI `Proteus Studio.app` 正在运行**，见 §4.6）时，benchmark 会把**别人的请求指标**记成自己的。`gen_lock` 只串行化生成，**不隔离指标**。

### 🟥 4.3 HTTP 层与生成层已解耦，结论**未经验收**

`server.py:354` 改成 `ThreadingHTTPServer` 后，必须重新验证「生成仍串行」。代码上 `gen_lock` 覆盖了全部生成路径（`:227, :301`），**但没有任何已发布的测试或实测记录**（`~/Proteus-Release` 内 `find -name '*test*'` 为空）。

⇒ README 声称"✅ 网关端到端验证，含长流式期间并发访问"，**该验证没有随包留下可复现产物**（`UNVERIFIED`）。

### 🟨 4.4 热态混淆：协议已确立，但**装置未实现**

报告 §2.3 / §14.2 与 Mnemon 项目空间均已确立：无风扇 M5 有**可逆 ~2× 功耗塌缩**，`burst probe` 不能当门禁，须持续 probe + 交替 A/B + **冷却 ≥180s**。

但：
- `gw_bench_ttft.py:117` 的 `--cool` **默认 120s**，低于本机确立的 180s 门槛；
- 脚本**不记录热态**（无持续 probe、无 GPU 频率/功耗读数，`powermetrics` 需 sudo 且当前不可用）；
- 无「冷却完成」的任何客观校验。

⇒ **装置上无法证明一次测量是冷态。** 热态仍是最未受控的混淆源。

### 🟨 4.5 进程复用

`engine.py:16-21` 单进程常驻，`max_resident=1`。所有模型切换都是**同进程内**的 load/unload。

报告铁律 #2 明确要求「每配置必须独立进程」（同进程交替污染可达 2.75×）。**当前测 prefill 必然违反该铁律**，因为 `ThreadingHTTPServer` 架构下无法为不同方案起独立进程。

### 🟨 4.6 其它未受控项（逐条）

| 混淆源 | 状态 | 证据 |
|---|---|---|
| **宿主内存压力** | 🟥 **当前极脏** | swap `used=9968MB / total=11264MB`、`PhysMem 15G used / 174M unused`、compressor 7026M、`load avg 14.81` |
| **GUI 并发轮询** | 🟥 存在 | `Proteus Studio.app` 在运行（`launchctl list` PID 34914），会周期性打 `/stats` |
| **cache warmup** | ⚠️ 未隔离 | `PrefixCacheStore` 无 reset 接口（`prefix_cache.py:156-163` 有 `drop()` 但未暴露到 HTTP）；同一 `session` 键跨轮次持续命中，冷/热臂只能靠换 session 名 |
| **串行 HTTP** | ✅ 已修复 | `ThreadingHTTPServer`（`server.py:354`） |
| **max_tokens 冲突** | ⚠️ 未受控 | 脚本传 `max_tokens=200`；GUI 硬编码 `maxTokens: 2048`（`ChatEngine.swift:75`） |
| **stop 串** | ✅ 无害 | 脚本未传 stop，`stop_hold=0` 路径 (`mlx_lm_backend.py:414`) |

**结论：报告铁律要求的 6 项控制，当前装置满足 2 项。**

---

## 5. 指标可测性分级

### 5.1 ✅ 当前可可靠测量

| 指标 | 依据 |
|---|---|
| prompt_tokens / completion_tokens | `mlx_lm_backend.py:382, 591` |
| ttft_s / prefill_s | `_mark()` (`:397-400`) |
| tpot_s | `:599-603` |
| itl p50/p95/max | `base.py:93-95` |
| **prefix_cached_tokens** | `:445`，本次实测已确认非零 |
| accept_len_median / accept_rounds | `:609-611` |
| finish_reason | `:594` |
| **单请求 TTFT 比值（同轮内冷/热）** | 本次实测 0.0475s → 0.6778/0.0698 |

**注意**：这些都是**单请求自洽量**。它们的可靠性来自"分母和分子在同一次请求内"，不依赖跨 campaign 比较——这正是本机唯一可信的形态。

### 5.2 🟥 缺少可靠实现

| 指标 | 缺什么 |
|---|---|
| **端到端 speedup（proteus-1 vs baseline）** | 上述 §3 的第三臂 + §4.5 的独立进程 |
| **冷态绝对 tok/s** | 无热态记录、无冷却校验、当前宿主脏 |
| **KV int8 的净收益** | 明确记于代码：`_make_kv_cache` docstring `:111-113`「⚠️ 速度侧尚无可信实测…必须重做」 |
| **prefix cache 的净收益（网关侧）** | 报告 §18.4 列为「⚠️ 判定中」 |
| **能耗/功耗** | 全项目无数据（报告 §18.4），`powermetrics` 当前需 sudo 不可用 |
| **热态代理量** | 无持续 probe 集成 |
| **成本模型：每 token 字节数** | 无运行时计量；报告中的 4.517 GB/token 是 offline 算的 |

---

## 6. 代码中的静态假设

### 6.1 🟥 **温度分流当前完全失效**（`nd` 恒为 base）

```python
# mlx_lm_backend.py:198-208
base = self._spec_cfg["num_draft_tokens"]              # 3
high = self._spec_cfg["num_draft_tokens_high_temp"]    # 2
if high <= 0: return base
temp = float(opts.temperature)
if temp > self._spec_cfg["max_temp"]:                  # max_temp = 0.5
    return high
return base
```

当前 `models.json`：`num_draft_tokens=3`，`num_draft_tokens_high_temp=2`，`max_temp=0.5`。

⇒ 任何 `temp > 0.5` 的请求走 **nd=2**，`temp <= 0.5` 走 **nd=3**。

**但代码内嵌的实测结论（`:184-193`）说得很清楚**：rejection 规则下 `nd=3` 得 1.210/1.249/1.167，`nd=2` 得 1.181/1.192 —— **nd=3 更好**。而网关默认 `temperature=0.7`（`server.py:134`）。

⇒ **生产默认路径恰好落在被实测判定为次优的 nd=2 上。** 代码注释把 `high=2` 的理由写成"高温必须回落到更短草稿"，但这与同一段引用的 rejection 数据**方向相反**——那段数据是在 **temp=0.7（高温）下**测的，结论是 **nd=3 更优**。

**这是一个 report-vs-code 不一致，单列于 §7。**

### 6.2 🟥 固定 execution path

| 假设 | 位置 | 后果 |
|---|---|---|
| 设备恒为 GPU/MLX | `mlx_lm_backend.py:252-256` 只 `import mlx_lm` | 无 device 选择；ANE 路线已关闭，但**没有任何机制禁止将来误配** |
| **后端由字符串硬拼** | `engine.py:31-33` `__import__(f"gm.backends.{entry.runtime}_backend")` | `runtime` 可被 models.json 任意注入；`BACKENDS` 注册表（`base.py:130`）**已定义但从未被使用** — 死代码 |
| 单进程单模型 | `engine.py:19` 全局 `gen_lock` | 见 §4.5 |
| 固定 `max_tokens` 默认 | `server.py:133` `512`；`ChatEngine.swift:75` `2048` | 客户端不一致 |

### 6.3 ⚠️ 固定 cache policy

- `max_sessions=8`、`max_total_tokens=32768`、`kv_group_size=64`、`kv_bits=8` —— **全部静态**，无自适应。
- `shared=false`（`:83`）→ `SharedPrefixCacheStore` **从未启用**。其存在意义（跨会话共享 system prompt）与网关默认 `session=""` 的现实相冲突：`_prefix_get` 用 `"__shared_default__"` 兜底（`:323`），**绕过了作者自己写的安全缺省**。这是当前有效的 TTFT 杠杆，但也是 §7 里记的那个"ZEBRA42 泄露"事故的**同一机制**。

### 6.4 ✅ 无固定 seed

`server.py:141` 透传 `body.get("seed")`；缺省 `None` → 每次随机。**benchmark 不可复现**，这一条是设计选择而非缺陷，但意味着逐请求比对必须配对。

---

## 7. 🟥 报告 / 文档 与 代码 不一致清单

单列。每条都指向具体位置。

| # | 类型 | 文档说 | 代码/实机是 | 影响 |
|---|---|---|---|---|
| **D1** | 🟥 plist 双份矛盾 | `~/GeneralModel/com.tristan.gm.gateway.plist`：Python **3.14**，WorkingDirectory = **iCloud** | 生效的是 `~/Library/LaunchAgents/...`：Python **3.11 venv**，WorkingDirectory = **`/Users/tristan/GeneralModel`**（本地） | **任何人按 `~/GeneralModel/` 那份 plist 重装服务，会同时踩 Python 3.14 与 iCloud EDEADLK 两个坑；而报告铁律 #7 正是反对 iCloud。** `~/GeneralModel/` 那份是**陈旧副本**，应删除或标注 |
| **D2** | 🟥 README「Two execution schemes」 | "**GPU** — the bare MLX baseline" | `gpu-baseline` 的 `kv_bits=0`（fp16 KV），而 proteus-1 是 int8。**不是 bare baseline**，见 §3.1 | 对外文档误导；分母被削弱 |
| **D3** | 🟥 nd 默认路径 | 代码注释 `:184-193` + 报告：rejection 下 **nd=3 最优**（temp=0.7） | `max_temp=0.5` 使 temp=0.7 落到 **nd=2** | 生产默认可能未处于最优；且 `max_temp=0.5` 的**唯一**依据（`:141-146`，nd=4 时代的旧数据）已被同一函数内更新的数据推翻 |
| **D4** | 🟥 benchmark 不可运行 | 报告 §27.2 以 `gw_bench_nd2.py` 为验证工具 | 脚本硬编码 `model="llama-3.1-8b-4bit"`，实机 **404** | 生产数字**当前无法复现** |
| **D5** | 🟨 README 测试状态 | "✅ 网关：端到端验证，含长流式期间并发访问" | `~/Proteus-Release` 内无任何测试文件 | 声称的验证**无随包产物**，不可复核 |
| **D6** | 🟨 冷却参数 | 报告 §2.3 / Mnemon：冷却 **≥180s** | `gw_bench_ttft.py:117` 默认 **120s** | 低于本机已确立门槛 |
| **D7** | 🟨 死代码 | `base.py:130-146` 定义 `BACKENDS` / `register_backend` / `create_backend` | `engine.py:31` 走 `__import__` 字符串拼接，**从不使用注册表** | 两套后端发现机制并存，注册表是死的；文档说的"扩展方式"未生效 |
| **D8** | 🟨 registry.py 内容 | `~/Proteus-Release/gm/registry.py:11` 是模板占位 `"/path/to/your/model"` | 部署版 `:11` 是 `/Users/tristan/Models/...`；**此差异只是 docstring，非行为差异** | 确认发布包已正确 genericize；**唯一差异项，行为等价** |
| **D9** | ⚠️ `run_with_gateway_stopped.sh` | 脚本存在（`04_.../scripts/`） | 说明作者**知道**同进程测量有问题 | 但网关日常常驻 + launchd `KeepAlive`，实际测量仍在同进程 |

---

## 8. 已关闭路线（Proteus-2 不得重复）

以下每条都有 ≥1 个可复现的数据链，详见 `docs/Proteus_全集技术报告.md` 与 Mnemon 项目空间。

| # | 路线 | 关闭依据 |
|---|---|---|
| 1 | **CoreML → ANE 的 group64 lowering** | `COMPILER_LOWERING`；编译器静默忽略 ANE 请求 |
| 2 | **Direct ANE / 权重卸载** | `PERFORMANCE DEAD END`；17 配置 × 2 campaign **0/17 胜**；decode 上零和（ane/dram=0.906） |
| 3 | **「ANE 权重流 ~20 GB/s」旧表述** | 🟥 **已被推翻**：真因是 **16 MiB 字节大小律**（字节数落 2^24 整数倍 ±0.4% → ~21 GB/s，带外 ~54 GB/s；23/23 命中）。**引用旧结论即引用已被推翻的结论** |
| 4 | **零填充 K 逃逸** | 单 op 有效（q/o_proj 2.58×，maxdiff=0）但**总字节账不变**（int8 8.13 GB/token vs group_q4 4.52），救不活卸载 |
| 5 | **自研 Metal kernel（Proteus-2B）** | ❌ **实测证伪，非"未试"**：E2E `G = 0.988/0.990/0.998`（3 campaign）；FFN 已达 ALU 峰值 **86.5%**，理论上限 9.23% < 10% Low 阈值 |
| 6 | **MLX runtime 深度优化（Phase-2A）** | 未触发：`R_overall=0.823` ⇒ MLX 与成熟 Metal runtime **同级** |
| 7 | **3-bit / 2-bit 量化** | 权重 rel_rmse 崩到 **0.221 / 0.414** |
| 8 | **用草稿量化压 c** | 已封死 |
| 9 | **KV cache 量化救聊天** | 结构上限 **1.013×**（ctx=1024） |
| 10 | **ANE int8-per-channel** | 单投影 9.16e-03 看似过关，穿完整 FFN 后 **1.53e-02 > 1e-2**，未过保真 Gate |
| 11 | **GPU 维度补零** | 那是 ANE 特有效应，GPU 在 K=4096 正常 50.2 GB/s，**不可移植** |

> ⚠️ **D3 特别提醒**：`PROTEUS2_ROADMAP.md` 中"下一步 = Proteus-2B"是 Gate P2-1 当时的**处方**，其后已被 #5 实测证伪。**照搬该路线 = 重复已关闭路线。**

---

## 9. 未决问题

| # | 问题 | 为何未决 |
|---|---|---|
| Q1 | `proteus-1` 的净收益到底是多少？ | §3.2 缺臂 + §4.5 同进程 |
| Q2 | KV int8 的速度收益？ | 代码自述无可信实测（`:111-113`） |
| Q3 | prefix cache 的网关侧收益？ | 报告 §18.4「判定中」；本次实测**观察到 54/55 命中**，但未做 A/B |
| Q4 | 温度分流应否存在？ | §7 D3 |
| Q5 | 宿主洁净时数字是多少？ | 当前 swap 9.97/11.26 GB、load 14.81 |
| Q6 | 热态如何客观标注？ | 无持续 probe 集成，`powermetrics` 不可用 |
| Q7 | `shared=true` 的安全边界能否形式化？ | 已有实测泄露事故（ZEBRA42），但 `"__shared_default__"` 兜底绕过了 `max_shared_tokens` 安全缺省 |
| Q8 | n_draft 是否真的可测量？ | 报告称"四次扫描四个最优值（2/2/1/3），跨度 0.190" |

---

## 10. Proteus-2 候选切口

按「是否能产出可信结论」排序，而非按潜在收益。

| 优先级 | 切口 | 为什么是它 | 依赖 |
|---|---|---|---|
| **P0** | **建立可运行的测量装置** | 修 D4（model id）、加第三/第四臂（§3.2）、加宿主/热态守卫、独立进程网关、指标隔离（§4.2） | 无 |
| **P1** | **量化 `proteus-1` 各组件净贡献** | 唯一能回答 Q1–Q3 的路径；2×2 因子设计（spec × prefix × kv） | P0 |
| **P2** | **解 D3：nd 策略的正确形式** | 纯配置/策略问题，成本低，可能直接产出产品收益（生产默认路径当前可能次优） | 可用 P0 装置 |
| **P3** | **prefix cache 判定收尾** | 报告 §18.4 唯一标"判定中"的产品杠杆；直击 ctx 大时 88% 的 prefill 占比 | P0 |
| **P4** | **KV int8 可信实测** | 代码作者明确标记为未验证；是"减少 bytes/token"三杠杆之一 | P0 |
| **P5** | 能耗维度 | 全项目零数据；需 sudo `powermetrics` | 你授权 |
| — | ~~ANE / Metal kernel / 低位宽~~ | **已关闭，见 §8** | — |

---

## 11. 下一实验建议

### 11.1 立即（不依赖宿主洁净，今天可做）

1. **修 `gw_bench` 的 model id** —— 把 `llama-3.1-8b-4bit` 改成 `proteus-1` / `gpu-baseline`，或走 `default`。**这是解除 D4 的唯一阻塞。**
2. **删除或标注 `~/GeneralModel/com.tristan.gm.gateway.plist`** —— 解除 D1。生效的是 `~/Library/LaunchAgents/` 那份。
3. **冻结一组测量脚本到本工作区** `tools/`，与生产网关解耦（当前脚本散落在 iCloud 报告目录，非版本控制）。

### 11.2 装置（P0，必须先于任何数字）

4. **扩 `models.json` 到 4 臂**：`proteus-1` / `gpu-baseline` / **`gpu-fp16kv`**（spec off, prefix off, kv 8）/ **`gpu-noprefix`**（spec off, kv 8, 每请求新 session）。
5. **加冷态校验**：脚本启动前断言 `swap_used < 1GB` 且 `load1 < 5`，否则**拒绝出结论**（`gw_bench_ttft.py:151` 已有雏形，但默认 `--force` 可绕过，且阈值只在总结里打印）。
6. **冷却提到 ≥180s**，并要求冷却后复测一个固定 probe 确认回到基线。
7. **测量时停 GUI**（`Proteus Studio.app` 在轮询 `/stats`）与 `dsh web`，避免 §4.2 的指标覆盖。

### 11.3 实验（装置就绪后）

8. **2×2 因子 A/B**：`{spec on/off} × {prefix on/off}` @ `kv_bits=8` 固定。**报告主效应与交互项，不只报总比。**
9. **口径要求**（沿用项目铁律）：每配置 ≥2 轮独立 campaign、交替 + 顺序翻转、报 **range** 而非单点、逐轮配对比值。
10. **nd 策略重扫**：在 rejection + kv8 + prefix 的**真实生产组合**下重测 nd ∈ {2,3,4}，据此决定 `max_temp` 是否应保留、`num_draft_tokens_high_temp` 是否应为 3（解 D3）。

### 11.4 预期产出与诚实边界

- 若 §11.2 的宿主条件**始终无法满足**（本机常年 swap > 1GB），则应**承认本机不具备产出端到端绝对 speedup 的条件**，退而只产出**同轮内配对比值**（如本次实测的 TTFT 9.7×），并明确标注该比值**不可外推为端到端加速**。
- **不得**在没有独立进程 + 干净宿主的情况下，给出任何形如"proteus-1 是 X 倍"的绝对结论。

---

## 附录：本次审计的实机探测记录

| 探测 | 命令/方法 | 结果 |
|---|---|---|
| 网关存活 | `curl :8320/v1/models` | 200，2 个模型 |
| 运行实体 | `ps -p 36590` / `launchctl print` | venv 3.11，cwd=`~/GeneralModel` |
| 生效 plist | `cat ~/Library/LaunchAgents/...plist` | 与 `~/GeneralModel/` 副本矛盾（D1） |
| model id 解析 | `curl` × 3 | `proteus-1`/`default` 200；`llama-3.1-8b-4bit` **404**（D4） |
| prefix cache | 同 session 连发 2 次 | turn2 `prefix_cached_tokens=54/55`，TTFT **9.7×** |
| 投机状态 | `/stats` | `speculative=true, rule=rejection, nd=2` |
| 宿主状态 | `sysctl vm.swapusage` / `top` | swap **9968/11264 MB**；load **14.81**；PhysMem 15G used / 174M free |
| powermetrics | `sudo -n powermetrics` | **不可用**（需密码） |
| 发布包 vs 部署 | `diff` × 11 文件 | **仅 `registry.py` docstring 不同**（行为等价，D8） |

---

*本审计未修改任何源码、配置或 plist。所有写入仅限本文件 `docs/PROTEUS2_PHASE0_AUDIT.md`。*
