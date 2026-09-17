# Proteus-1 与 Proteus 项目全集技术报告

## 从 ANEProbe 的探索到 Speculative Decoding 的落地

> **项目**：Proteus Hybrid Adaptive Compute Architecture（Proteus 混合自适应计算架构）
> **总目标**：**小内存 · 大模型 · 高速度**
> **硬件**：Apple M5（Mac17,3）MacBook Air / 16 GB 统一内存 / **无风扇**
> **模型**：Llama-3.1-8B-Instruct-4bit（真实 MLX `group_q4`，group_size=64，非对称带 zero-point）
> **工具链**：MLX 0.32.x（Metal/GPU）· coremltools 9.0 · ANEForge（私有 e5rt 直连）· Swiftlet（Swift + Metal）
> **报告生成日期**：2026-09-16
> **覆盖范围**：`/Users/tristan/ANEProbe/` 与 iCloud `Corp AI/MLXonANE/` 下全部 ~96 份报告文件

---

# 阅读指南

本报告是这个项目**全部阶段的完整叙述**，从最早的猜想一直到最终落地的方案。它不是摘要集的拼盘，而是一条有时间顺序、有因果关系、**包含所有错误与被推翻结论**的完整链条。

| 你想了解 | 跳到 |
|---|---|
| 一句话结论 | [§0 执行摘要](#0-执行摘要) |
| 项目最初想做什么、为什么 | [§1 最早的猜想与目标](#1-最早的猜想与目标) |
| 每个阶段遇到什么问题、怎么解决 | §3 – §14（按时间顺序） |
| 哪些结论被推翻了、被谁推翻 | [§15 更正链全图](#15-更正链全图) |
| 所有实测数字 | [§16 数据总表](#16-数据总表) |
| 方法论铁律（最有迁移价值的部分） | [§17 方法论铁律](#17-方法论铁律) |
| 最终成果与技术实现 | [§13 找到的方案](#13-找到的方案speculative-decoding) · [§18 最终成果](#18-最终成果) |
| 所有文件的清单与去向 | [附录 A 文件清单](#附录-a-文件清单) |

**诚实性声明**：本报告中所有数字均来自项目原始报告文件的实测记录。凡属推断、模型化反事实（MODELLED）或引自外部项目的数据，均在正文中明确标注。项目全程**没有任何能量/功耗的直接测量**（无 ANE 功耗计数器，`powermetrics` 需 sudo 且本会话无法提权）——这一点在各阶段报告中都被诚实标注，本报告同样如实转述，未做任何补全或估算。

---

# 0. 执行摘要

> 🟥🟩🟨 **核心结论**：**Proteus 用 11 条被严格证伪的技术路线，换来了一张完整的 M5 硬件能力边界图，并最终在唯一幸存的杠杆上取得了产品级成果：Speculative Decoding 在真实网关上线，默认温度路径端到端提速 1.284×（离线严格配对 1.145–1.249×）。整个 ANE（神经引擎）路线，从"未开发的算力金矿"这一最初猜想出发，被三阶段、四份 frontier map、上百个实验逐步否定到零和。**

## 0.1 三个子目标的真实状态

| 目标 | 状态 | 依据 |
|---|---|---|
| **小内存** | ✅ **已实现** | `group_q4` 让 8B 模型只占 **4.21 GB** 活跃内存（16 GB 机器），无 swap 增长 |
| **大模型** | ✅ **已实现** | 8B 全管线跑通，与 `mlx_lm` 数值等价（corr = 1.0000） |
| **高速度** | 🟨 **部分达成** | decode 已顶 DRAM 屋顶线（~123 GB/s）；唯一有效杠杆 = 投机解码 **1.284×（网关）/ 1.145–1.249×（离线配对）** |

> **关键认知**：「小内存」与「大模型」**是 MLX 4-bit 生态的功劳，不是 Proteus 的**。Proteus 真正要啃的是「高速度」，而它的瓶颈是一条物理算术：`每 token 时间 ≥ 权重总字节 ÷ 可用内存带宽`。

## 0.2 最终成果速览

| 指标 | 基线 | 最终 | 变化 |
|---|---|---|---|
| **decode 吞吐（网关，temp=0.7 默认路径）** | 29.43 tok/s | **37.78 tok/s** | **1.284×** |
| decode 吞吐（离线严格配对，temp=0.7） | 1.004× | **1.210×** | 三 campaign 19/22 对胜出 |
| decode 吞吐（离线配对，greedy） | — | **1.247–1.490×** | 两 campaign |
| 逐 token 一致率 | — | **91.80%**（7/8 prompt 完全一致） | 近似无损 |
| 输出分布 | — | **严格不变**（拒绝采样保证） | 理论无损 |
| 权重保真度 | group_q4 原生 | **完全不变** | 零改动 |
| 额外内存 | — | +1B 草稿模型（4-bit ≈ 0.7 GB） | — |

## 0.3 被证伪的路线总清单（11 条）

| 路线 | 阶段 | 否定方式 |
|---|---|---|
| FP32 on ANE | Proteus-1 | GPU 赢 20/21 算子，geomean 0.68× |
| CoreML per-block64 lowering | Proteus-1 Phase-3E | `linear.supported=[CPU]` 独占 |
| CoreML block-wise ANE lowering（表示转译） | Proteus-1 Phase-3F | 原生 MIL 手写同样失败，双重证伪 |
| FP16 FFN on ANE（含整图融合） | Proteus-1 P5A/4A | 每个 S 都是 GPU 最快 |
| 单阈值 GPU↔ANE crossover | Proteus-1 Phase-3B | 实际是 4 区域非单调面，S=96/128 是派发失败而非交叉点 |
| MLX runtime 优化 | Proteus-2.2 | R_overall=0.823，与 llama.cpp 同级 |
| GPU Metal kernel（SwiGLU fusion） | Proteus-2.2 | headroom 9.23% E2E < 10% 门槛；E2E ≈ 1.0× |
| CoreML 绕过即解锁 | Proteus-2.3 | 绕过成功但性能仍输 |
| ANE 单 op 分组 4-bit dequant | Proteus-2.3 | 3 op × 3 位宽 × 3 组结构穷尽拒绝（6/6 vs 0/6 复现） |
| **ANE dense compute 路线** | **Proteus-2.4** | **0/34 配置 ANE 胜；~6.5–7.75 vs ~8–11.5 TFLOP/s** |
| int8 per-channel 替代表示 | Proteus-2.4 | 单投影 9.2e-3 过 Gate，穿真实 FFN 放大到 **1.53e-02 > 1e-2** |
| ANE 权重卸载（含字节律填充逃逸） | Proteus-2.4+ | 持续 decode 上零和：ANE/DRAM = **0.906**，结构化必然净损 |

## 0.4 真正留下的成果（5 条可迁移发现）

1. **ANE 权重取数的「16 MiB 字节大小律」** —— 纯原创发现。取数速率只由权重张量字节数决定，与 K/N 无关（23/23 命中，慢带 21.2 vs 带外 54.3 GB/s，惩罚 2.57×）。
2. **「表示可行」与「性能可行」必须分开验证** —— 单 op 被拒绝 ≠ 计算不可表达。
3. **保真度误差会在复合算子中放大** —— 逐算子门禁会产生假阳性通过。
4. **无风扇机器上的持续功耗塌缩与 burst probe 假阴性** —— 完整可复用的测量协议。
5. **decode 下限由内存带宽决定，且当前 runtime 已贴住它** —— 把"还能不能更快"变成一道算术题。

---

# 1. 最早的猜想与目标

## 1.1 问题的起点

在 Apple Silicon 上跑大模型，有三个诉求同时成立才叫"能用"：

```
小内存  —— 16 GB 机器要装得下 8B 模型，且不能把系统拖进 swap
大模型  —— 要真的是"大"模型，不是玩具
高速度  —— 要快到能当产品用，不是能跑就算
```

到项目开始时，前两个已经被 MLX 生态解决了：`group_q4` 量化让 8B 模型只占 4.21 GB 活跃内存。**第三个"高速度"，就是 Proteus 全部工作的目标。**

## 1.2 最早的猜想（三个假设）

项目最初的技术信念可以归结为三条假设。**这三条后来全部被证伪——而这正是项目的核心产出。**

| # | 假设 | 直觉来源 |
|---|---|---|
| **H1** | **ANE 是 LLM 推理的未开发算力，值得为它做表示转译** | ANE 是 Apple 专为神经网络设计的硬件，理论上比 GPU 省电；CoreML 生态里它长期"藏在后面"，看起来像没被用起来 |
| **H2** | **瓶颈在 CoreML 编译器 lowering，绕过它即可解锁** | 观察到 per-block 量化的算子拿不到 ANE，自然怀疑是"编译器不肯降级"，而非硬件不行 |
| **H3** | **GPU kernel 还有可观的优化空间** | MLX 是较新的 runtime，直觉上 kernel 还有打磨余地 |

**证伪结果**：

| # | 状态 | 证伪证据 |
|---|---|---|
| H1 | **证伪** | Proteus-2.4：34 配置 × 2 campaign，ANE dense **0/34 胜**；权重流仅 ~20 GB/s vs GPU ~100 GB/s |
| H2 | **证伪** | Proteus-2.3 成功绕过 CoreML（零 CoreML 链接），group64 仍需分解、仍慢 6×；2.4 证明瓶颈是**算力与带宽**，不是前端 |
| H3 | **证伪** | Proteus-2.2：MLX FFN 已达同热态 matmul 峰值 **86.5%**；自研 SwiGLU fusion E2E ≈ 1.0× |

## 1.3 为什么"假设被证伪"不等于项目失败

每一次证伪都花了真实的实验成本，并且每一项都有可复现的数据链。它们把"该往哪走"的搜索空间**收敛到了零**——这本身是这类硬件研究的主要产出。

> **项目最终的技术判决**：`FINAL_PROJECT_STATUS = 技术上成功（5 条普适发现 + 11 条路线被严格证伪 + 可复用工具链与测量协议）；产品目标未实现（未找到任何保真前提下超越 MLX GPU 的配置）`

## 1.4 速度的物理下限（项目后期才完全确立的算术）

大模型推理分两段，瓶颈完全不同：

```
prefill（读入整段 prompt）  ：算力受限 —— 一次算很多 token，算术强度高
decode （逐 token 生成）    ：带宽受限 —— 每生成 1 个 token 都要把全部权重读一遍
```

**decode 的墙钟下限是一条简单算术**：

```
每 token 时间 ≥ 权重总字节 ÷ 可用内存带宽

8B 模型 group_q4 权重 ≈ 4.4 GB
M5 GPU 实测权重流     ≈ 100 GB/s
⇒ 下限 ≈ 44 ms/token ≈ 23 tok/s

实测 MLX 达到 ~27 tok/s —— 已经贴住这个下限
```

**这条算术锁死了所有 compute-side 优化的上限**——无论 GPU kernel、ANE、还是异构调度。它解释了为什么项目后期所有"让 ANE 帮忙"的尝试都归于零和：**decode 已经跑在带宽屋顶线上，任何第二引擎都只能重排同一批字节，不能减少字节。**

---

# 2. 硬件与测量环境

## 2.1 测试平台

| 项 | 值 |
|---|---|
| 机型 | Apple M5（Mac17,3）MacBook Air，**无风扇** |
| 内存 | 16 GB 统一内存 |
| 系统 | macOS 27.0（报告原文如此） |
| MLX | 0.32.0 / 0.32.2（Metal/GPU） |
| coremltools | 9.0 |
| Python | 3.11 / 3.14.5（不同阶段），NumPy 2.5.1 |
| 模型 | Llama-3.1-8B-Instruct-4bit（MLX `group_q4`，group_size=64，非对称带 zero-point，4.5 GB safetensors） |

## 2.2 本机最大的测量混淆源：无风扇功耗塌缩

这是**贯穿整个项目、也是最有方法论价值的发现**：

> 无风扇 MacBook Air 在持续负载下存在**可逆的功耗/热态塌缩，幅度可达 ~2×**，而**所有常规环境检查（swap、memory pressure、thermal state）全部读作正常**。

**证据链（Proteus-2.2）**：

- 同代码跨进程：S=512 prefill **768 → 831 → 1170 ms**，同时 swap 平稳 3.8 GB（delta 0）、pressure NORMAL、thermal NOMINAL
- 交替测量中 E2E 767.8 → 1364.6 ms 与持续吞吐 12081 → 5128 GFLOP/s **同向单调**；停止加热 **<180 s 完全恢复** ⇒ 纯功耗限频
- **假阴性证据**：58 ms 的 40-matmul burst 在"768 ms 态"与"878 ms 态"读出**相同的** ~11.8 kGFLOP/s
- **不对称混淆**：MLX GPU 计时跨 run 漂移 **2.2×**，而 ANE 计时稳定（1.01–1.17×）

**后果的严重程度**（各阶段实测漂移幅度）：

| 阶段 | 实测热态漂移 |
|---|---|
| Proteus-2.4 | 单配置绝对 tok/s 在 **6.4 – 27.1** 之间摆动 |
| PROTEUS_SPEEDUP_DIRECTIONS | drift 0.024 – **0.539（52%）** |
| PROTEUS_FINAL_TECHNICAL | 6 轮中最高 drift **0.512** |

> **若用跨轮中位数统计，投机解码的 1.61× 会被误读为 1.22×（错误）。必须用逐轮配对比值。**

## 2.3 测量协议（项目后期确立的强制规范）

经过多次被混淆源欺骗后，项目沉淀出一套**必须在每次测量中执行**的协议：

1. **持续 probe 门禁**（≥1 s 含 warmup）——burst probe 无效，会给出假阴性
2. **同进程交替 A/B + 逐轮配对比值**——用比值抵消热态
3. **每配置独立进程**——同进程交替测 GPU/ANE 互相污染可达 2.75×
4. **交错 + 冷却 ≥150 s**——顺序扫描若测项本身会致热，不能递增排列
5. **≥2 轮独立 campaign 并报告 range**——单轮数字不足以下结论
6. **宿主洁净门禁** `host_clean_gate.py`——decode 达屋顶线 0.96+ 才允许测
7. **每轮状态漂移校验**（≤5%），不合格轮次剔除

---

# 3. 阶段 P6.2 —— 冻结真实 Llama MLX 引擎（基线）

**日期**：~2026-08-28 之前 ｜ **状态**：✅ 完成，此后**只读**

## 3.1 目标

建立一个**可信、冻结、只读**的真实 Llama-3.1-8B-INT4 MLX 参考实现，作为后续**所有**正确性 Gate 的唯一基准。

## 3.2 方法

纯 MLX 实现（`P6Model/phase2/`：`phase2_runner.py` → `RealLlama`；`kv_decode.py` → `KVCacheLlama`）。架构：32 层 + GQA（**nkv=8**、head_dim=128、hidden=4096、intermediate=**14336**）+ **Llama-3 scaled RoPE** + KV cache。反量化 `W = nibble*scale + bias`（`mx.quantized_matmul`）。**后续阶段只 import，从不修改。**

## 3.3 结果

- 32 层前向：warm 首次 S=16 **0.498 s（32.1 tok/s）**；steady **0.146 s（109.9 tok/s）**
- **vs `mlx_lm` ground truth（5 位置）：corr = 1.0000**，rmse 0.0040 / 0.0047 / 0.0054 / 0.0052 / 0.0051，top-1 完全一致，top-5 交集 5/5
- 贪心生成 `Once upon a time,` → "in a small village nestled in the rolling hills of" —— 与 mlx_lm **逐 token 相同**
- Prefill：S=16 **498.0 ms（32.1 tok/s）**；S=128 **685.0 ms（186.8 tok/s）**
- KV-cache decode vs 重算前缀（pos 4–9）：logits_rmse 0.00000 / 0.00522 / 0.00481 / 0.00440 / 0.00549 / 0.00667，top-5 5/5，top-1 一致
- **decode ~39–45 ms/token steady（25.6–26.5 tok/s）**

## 3.4 发现的问题（贯穿全项目的根本限制）

> ⚠️ **MLX 只暴露 CPU 与 GPU（Metal），没有 ANE device。**
>
> 这意味着：**纯 MLX 无法做 GPU↔ANE 混合实验，所有 ANE 实验必须借道 CoreML（或后来的 ANEForge 私有通道）。**

**抓到的真实 bug**：最初用 plain-RoPE 生成出 " and and…" 的退化文本 → 根因是**缺 llama3 scaled RoPE（θ=500k, factor 8）**。

## 3.5 是否被后续修正

**否，始终冻结。** 它是全项目唯一可信的正确性基准。Phase-3C 实测 `embed_fast` vs frozen **max_abs 0.0 EQUIVALENT**，frozen 参考 prefill **rmse 0.0 PASS**。

---

# 4. 阶段 Phase-2 —— 单 Linear 验证，运行时受阻

**日期**：2026-08-29

## 4.1 目标

验证第一个真实 Llama CoreML Linear（**L0 `gate_proj`**）：MLX reference → CoreML 推理 → 数值正确性 → 计算单元验证。

## 4.2 结果：⚠️ PARTIALLY COMPLETE — RUNTIME VALIDATION BLOCKED

- CoreML 文件 **224 MB**；输入 `[1,4096]` → 输出 `[1,14336]`
- 量化权重 `[14336,512] uint32`，scales/biases `[14336,64] fp16`，反量化后 `[14336,4096] fp32`
- 权重统计 mean 8.29e-06、std 0.01282、min −0.597656、max 0.412109（无 NaN/Inf）
- **阻塞原因**：`Unable to load CoreML.framework` / `No module named 'coremltools.libcoremlpython'`；报告判断需 **GUI macOS 登录会话**

## 4.3 留下的铁律

> **「CoreML 模型文件生成 ≠ CoreML 运行时执行 ≠ ANE 执行」**

这条成为本项目的方法学铁律。**注意它同时也是一次误判**：次日（8-30）在 venv 下 coremltools 9.0 就能跑通，并成功用 `/usr/bin/sample` 验证 ANE 执行——**"BLOCKED" 的判定本身是错的**，但它留下的教训是对的。

---

# 5. 阶段 Phase-2B —— ★ INT4 立项验证（真实权重）

**日期**：2026-08-30 ｜ **这是"ANE 有希望"这一判断的源头**

## 5.1 目标

P5B 的「INT4→ANE 优势」在**真实 Llama 权重**上是否成立？

**答案**：**"Yes at prefill-scale S (≥512), No at decode-scale S=1."**

## 5.2 方法

真实 `group_q4` → FP32 反量化 → FP16 mlprogram Linear → coremltools **symmetric per-channel INT4** 重量化 → 得到 `constexpr_blockwise_shift_scale → linear`（**ANE-native dequant→matmul** 路径）。

协议：warmup 25 / measure 150 / median；一次只加载一个 (op, compute-unit) 模型（del + gc），避免 16 GB 机器 swap 污染。

## 5.3 结果

**① ANE 硬件执行已验证** `VERIFIED_ANE_EXECUTION`：`/usr/bin/sample` 抓到 `_ANEClient doEvaluateDirectWithModel`、`ANEServicesProgramProcessRequestDirect`、`ANE::ANEServicesDevice::ANE_ProgramSendRequest`。

**② 正确性**：**21 个算子 corr ≥ 0.96**（gate L0 0.984/0.150 … down L31 0.978/0.337）。

**③ S=1（decode 形状）：ANE 输**

| 分组 | GPU avg ms | ANE avg ms | Geomean (GPU/ANE) |
|---|---|---|---|
| MLP (gate/up/down) | ~0.48 | ~0.64 | **0.74×** |
| Attention (q/k/v/o) | ~0.17 | ~0.17 | **0.96×** |
| **全部 7 算子** | — | — | **0.87×** |

**④ S 扫描（MLP，GPU/ANE 加速比，>1 表示 ANE 赢）**

| Op (Layer) | S=1 | S=8 | S=32 | S=128 | S=512 |
|---|--:|--:|--:|--:|--:|
| gate_proj L15 | 0.55× | 0.49× | 0.66× | 0.99× | **1.60×** |
| up_proj L15 | 0.52× | 0.65× | 0.51× | 1.03× | **1.59×** |
| down_proj L15 | 1.01× | 0.70× | 0.85× | 0.14×※ | **1.39×** |
| gate_proj L0 | 0.50× | 0.48× | 0.61× | 1.05× | **2.00×** |
| up_proj L0 | 1.13× | 0.68× | 0.76× | 1.17× | **2.10×** |
| down_proj L0 | 0.63× | 0.64× | 0.72× | 0.15×※ | **1.27×** |

※ `down_proj S=128` 的 ANE = 36–38 ms（vs GPU 5.4 ms）——这是**已知的 P5B S=128 ANE 调度异常**（后来的 R3 黑名单），**不是 crossover**。

**⑤ 决定性读数**：

> **在 S=512，INT4-ANE 在全部 6 个真实 MLP 测试上击败 INT4-GPU：1.27× – 2.10×，geomean ≈ 1.61×**
> **Crossover GPU↔ANE 位于 S=128 与 S=512 之间**

**⑥ FP32 vs INT4 对照（S=1）**：MLP geomean FP32 **0.89×** / INT4 **0.74×**；全部算子 FP32 **0.68×** / INT4 **0.87×**。⇒ **量化本身缩小了 ANE 的差距**。

## 5.4 结论

支持 **prefill S=512 用 ALL-FFN-ANE、decode 保留 GPU**。本阶段不修改 placement map。

## 5.5 ⚠️ 后续修正（极其重要）

数值本身未被推翻，但 **Phase-3E/3F 揭示这个"优势"用的是 per-channel INT4（权重误差 0.18–0.21）**，而忠实的 per-block64 在 ANE 上慢 4–5.7×。

> **「INT4 ANE 有优势」成立；「忠实 INT4 ANE 有优势」不成立。**
>
> 这个区别是整个项目最重要的分水岭——它直到 Phase-3C 才被发现，中间隔了整整两个阶段。

---

# 6. FP32 孪生报告 —— FP32 不适合 ANE

**日期**：2026-08-30

## 6.1 方法

真实 `group_q4` → FP32 反量化 → CoreML `neuralNetwork` 单个 `innerProduct`，输入固定 `[1,4096]`；warmup 25 / measure 150 / median。

## 6.2 结果

- **20 个可靠对比 geomean 0.68×（ANE 慢 ~47%）**
- MLP：CPU 5.526 / GPU 5.063 / ANE 5.680 ms
- Attention：CPU 0.626 / GPU 0.925 / ANE **1.469** ms
- ANE 最差 **o_proj 0.47×**，q_proj **0.51–0.63×**

## 6.3 结论

> 「no operator shows a reliable ANE advantage at FP32/batch=1」
>
> **「FP32 不适合 ANE」** —— 这是**转向 INT4 路径的直接原因**。

**另注**：模型形状固定 `[1,4096]` → **无法建立 GPU↔ANE crossover**（更大 S 报 shape 不匹配）。这个局限直接催生了 Phase-3A/3B 的变长模型工作。

---

# 7. 阶段 Phase-3A —— 运行时优化（融合）

**日期**：2026-08-30 ｜ 又名 Phase-3 / Runtime Optimization

## 7.1 目标

消除 host↔CoreML 胶水开销，量化"零拷贝是否可行"。

## 7.2 结果 ①：零拷贝不可行

coremltools Python `MLModel` 只暴露 `predict` / `get_available_compute_devices` / MultiArray，**无 buffer surface**；Swift `MLModelProvider` / `MLComputePlan` 的 buffer path **从 Python 不可达**。

路径 `MLX→numpy→CoreML predict→numpy→MLX` 每次往返 **2–4 MB**，但 host 拷贝仅 **0.001–0.2 ms**。

## 7.3 结果 ②：FFN 融合有效

| S | GPU 基线 ms | ANE 三调用 ms | ANE 融合 ms | 融合 vs 三调用 | 融合 vs GPU |
|---|---|---|---|---|---|
| 1 | 1.86 | — | 1.40 | — | 1.33× |
| 32 | 3.63 | 4.40 | 1.50 | **2.93×** | 2.41× |
| 128 | 4.31 | 37.18 | 65.34 | 0.57× | 0.07× |
| 512 | **12.89** | 60.56 | 16.95 | **3.57×** | **0.76×** |

## 7.4 结果 ③：开销分解

融合后 **host% 仅 0.1–1.4%**，CoreML predict 占 **98.6–99.9%**。融合把每层 3 次调用降到 1 次：**32 层 prefill 调用数 96 → 32**；老路径 **37.4 s → 1.23 s @S=512**。

> **结论**：host 拷贝不是瓶颈，**真正的成本在 CoreML 内部执行**。

## 7.5 ⚠️ 发现的问题（重大）：GPU 基线测低了

本阶段称「fused-ANE 在 S=512 **输给** MLX-GPU（0.76×）」。

→ **Phase-3B 严格复测发现 MLX-GPU 基线被低估**：S=512 应为 **31.63 ms**（复检中位 **35.34 ms**），而非 **12.89 ms**。12.89 ms 隐含 **~14 TFLOPS fp16，超出 M5 GPU 实际能力**。

→ **修正后结论反转：fused-ANE 在 S=512 胜出 ≈1.70×。**

**本阶段 CSV 刻意保持未改**（保留错误痕迹以便追溯），修正记录见 `proteus1_phase3b_phase3a_baseline_correction.md`。其他发现（融合消除 host 胶水；host% 0.1–1.4%）**不受影响，仍然成立**。

---

# 8. 阶段 Phase-3B —— Crossover 映射（4 区域非单调面）

**日期**：2026-09-10

## 8.1 目标

系统测量"哪个 S 区间 ANE 赢"，建立 placement map。

## 8.2 方法

S ∈ {1,2,4,8,16,32,64,96,128,160,256,384,512,768,1024}；对比 (A) MLX-GPU 真实 group_q4 FFN 与 (B) fused-ANE（**一次** CoreML INT4 预测完成 `Gate→SiLU→Up→Mul→Down`）；每个形状独立测量。

## 8.3 完整 crossover surface

| S | MLX-GPU ms | fused-ANE ms | 加速 (GPU/ANE) | 区域 |
|---:|---:|---:|---:|:--|
| 1 | 1.109 | 1.374 | 0.81 | R1 GPU |
| 2 | 0.776 | 1.370 | 0.57 | R1 GPU |
| 4 | 0.888 | 1.379 | 0.64 | R1 GPU |
| 8 | 1.526 | 1.385 | 1.10 | R2 ANE |
| 16 | 2.210 | 1.413 | 1.56 | R2 ANE |
| 32 | 2.302 | 1.481 | 1.55 | R2 ANE |
| **64** | 4.006 | 1.691 | **2.37** | **R2 ANE 峰值** |
| 96 | 3.393 | **48.734** | **0.07** | ⚠️ R3 异常 |
| 128 | 3.501 | **62.946** | **0.06** | ⚠️ R3 异常 |
| 160 | 9.154 | 6.193 | 1.48 | R4 ANE |
| 256 | 14.632 | 8.573 | 1.71 | R4 ANE |
| 384 | 21.241 | 13.348 | 1.59 | R4 ANE |
| 512 | 31.634 | 18.639 | 1.70 | R4 ANE |
| 768 | 51.357 | 28.688 | 1.79 | R4 ANE |
| 1024 | 71.209 | 43.745 | 1.63 | R4 ANE |

## 8.4 区域分解（真正的答案）

```
speedup (GPU/ANE)
 2.4 |                                   ●64
 2.0 |                                          ●768
 1.6 |              ●16 ●32        ●160 ●256 ●384 ●512 ●1024
 1.1 |        ●8
 0.8 | ●1
 0.6 | ●2 ●4
 0.1 |                    ☠96  ☠128   ← ANE 未派发（fallback 49–63 ms）
     +----------------------------------------------------------------
      1  2  4  8  16 32 64   96 128   160 256 384 512 768 1024
      └── R1 ──┘└─── R2 ───┘└─ R3 ──┘└──────── R4 ───────────────┘
       GPU 赢     ANE 赢     异常         ANE 赢
```

- **R1（S = 1–4，GPU 赢）**：加速比 0.57–0.81×。ANE 延迟平坦（~1.37 ms，固定派发成本），而 MLX-GPU 能缩到 0.78 ms。小工作量摊不掉 ANE 固定成本。
- **R2（S = 8–64，ANE 赢）**：1.10 → **2.37× 峰值 @S=64**。
- **R3（S = 96–128，异常，不是 crossover）**：`ane_fused_ms` 跳到 **48.7 / 62.9 ms**，`/usr/bin/sample` **看不到 ANE 栈帧** → **UNVERIFIED_ANE_EXECUTION**。CoreML 在这些形状**根本不派发到 ANE**，49–63 ms 是 **fallback 路径**延迟。
- **R4（S = 160–1024，ANE 持续赢）**：1.48–1.79×。

## 8.5 结论

> **不存在单一 S 阈值。** 朴素的 `S > X → ANE` 规则会**错两次**：在 S=8–64 会错选 GPU（实际 ANE 赢），在 S=96–128 会错选 ANE（实际静默 fallback，慢 ~15×）。

**Placement map**：

```
S ≤ 4        → GPU   （R1 实测）
8 ≤ S ≤ 64   → ANE   （R2 实测，峰值 2.37×）
65 ≤ S ≤ 95  → GPU   （未测区间 → SAFE_GPU）
96 ≤ S ≤ 128 → GPU   （R3 实测 + 黑名单：CoreML 未派发到 ANE）
129 ≤ S ≤ 159→ GPU   （未测区间 → SAFE_GPU）
160 ≤ S ≤ 1024 → ANE （R4 实测）
S > 1024     → GPU   （超出实测范围 → SAFE_GPU）
```

未实测的间隙（5–7、65–95、129–159、>1024）**一律 SAFE_GPU，绝不外推**。

## 8.6 ⚠️ 发现的问题

> **S=96/128 是 CoreML 未派发到 ANE**（已知 P5B sched-exception），导致 0.06–0.07× 的灾难性数字——**这不是"ANE 慢"，是"ANE 没被调用"**。必须黑名单。

这个发现的严重性在于：**如果没有黑名单，整个 placement map 会在两个形状上产生 15× 的性能灾难。**

---

# 9. 阶段 Phase-3C —— 32 层端到端 E2E

**日期**：2026-09-10 ~ 09-11 ｜ **这是项目第一个"真相时刻"**

## 9.1 目标

把 Phase-3B 的单层结论放到真实 32 层 prefill / decode / E2E 上验证，回答 **Q1–Q10 十问式**。

## 9.2 方法

冻结 P6.2 MLX-GPU 为 Path A（只读）；CoreML fused FFN 为 Hybrid。**每个 (配置, shape) 都在独立进程中测量**（长 warmup 8 → 稳态采样 15 → 取中位数）。

**两处 harness 级改动**（均验证为逐位等价）：
1. **KV cache 容器**：从"每 token 一行 Python list"（ctx=1024 时每 token 需 ~66k 次 `mx.concatenate`）改为每层一个 `[1,nkv,T,hd]` 数组。等价性 `max_abs_diff = 0.0`。
2. **embedding 取行**：从 one-hot（S=32 时 23 ms，占 8 层 prefill 的 40%）改为逐位等价的 row-gather（0.48 ms，**48×**）。**两条路径都用同一个实现，所以 GPU-only baseline 是更快的那一方**，对 Hybrid 更不利。

## 9.3 正确性 Gate（全部通过）

| Gate | 结果 |
|---|---|
| Phase-3C 引擎 vs 冻结 P6.2 `forward_full` | `max_abs = 0.0` — **逐位相同** |
| `embed_fast` vs 冻结 one-hot `embed` | `max_abs = 0.0` — 逐位相同 |
| KV 容器（数组 vs 行列表） | `max_abs_diff = 0.0` — 逐位相同 |
| 增量 KV decode vs 全量 re-prefix | rmse 0.011，top-1 **1.000**，top-5 **1.000** — PASS |

## 9.4 主结果：Prefill 有收益，但**是用保真度换来的**

| S | GPU ms | Hybrid ms | tok/s GPU→Hyb | 加速 | 可复现 |
|---|---|---|---|---|---|
| 32 | 129.69 | 118.317 | 246.7→270.5 | 1.0961 | ✅（保守 1.088） |
| 64 | 230.708 | 190.317 | 277.4→336.3 | 1.2122 | 🟨 边界（差 14.9%） |
| 96 | 442.888 | 442.888 | = | **1.0** | 设计（黑名单） |
| 128 | 455.496 | 455.496 | = | **1.0** | 设计（黑名单） |
| 160 | 652.925 | 408.644 | 245.1→391.5 | 1.5978 | ❌（run2 = 1.013） |
| 256 | 986.813 | 604.904 | 259.4→423.2 | 1.6314 | ❌（run2 = 1.270） |
| **512** | **2293.077** | **1226.113** | **223.3→417.6** | **1.8702** | ✅（保守 1.661） |

**Decode：无收益**

| ctx | GPU ms/tok | Hybrid(默认) ms/tok | 默认策略 speedup | 强制 ANE 探索变体 |
|---|---|---|---|---|
| 32 | 45.19 | 43.71 | 1.03×（噪声内） | **0.74×** |
| 128 | 40.08 | 48.29 | 0.83×（噪声内） | **0.61×** |
| 512 | 47.02 | 51.43 | 0.91×（噪声内） | **0.57×** |
| 1024 | 89.17 | 86.44 | 1.03×（噪声内） | 1.12×（噪声内） |

placement map 在 S=1 落到 R1（GPU 胜），因此**默认 Hybrid decode 的 FFN 走 GPU，与 baseline 逐位相同（rmse 0.0）**——这不是巧合，是 Phase-3B 证据的直接结果。强行推到 ANE 在 ctx≤512 **稳定变慢 26–43%**。

**E2E：warm 微增，cold 变慢**

| | GPU-only | Hybrid | 比值 |
|---|---|---|---|
| **E2E warm（12 组）** | — | — | 中位 **1.05×**（精确 1.05405，范围 0.9867–1.3599） |
| E2E cold N=64 | 8740 ms（7.32 tok/s） | 10800 ms（5.93 tok/s） | **0.81×（更慢）** |
| **首 token 墙钟（N=64）** | **3923 ms** | **14733 ms** | **0.27×（慢 3.8×）** |

> 🟥 **冷启动时 Hybrid 要为 32 个 CoreML 模型支付 13.8–15.4 s 的加载/编译成本**，首 token 慢 3.8 倍。这是产品化时的硬约束。

**为什么 warm E2E 只有 1.05×**：生成 N=64 token 时，prefill 只占约 **14%**，其余 **86% 是 decode**，而 decode 收益为 0。

## 9.5 ⚠️ 最重要的附带发现：表征误差是 placement 误差的 32 倍

**这是此前各阶段都没有量化过的问题。**

冻结的融合模型用的是 coremltools `linear_symmetric` / **per-channel INT4**，而 baseline 是 MLX **group_q4（group_size=64，非对称，带 zero-point）**。**二者不是同一个量化方案。**

**权重空间重建误差（L0，纯 numpy，对上亿权重直接计算）**

| 算子 | 冻结 per-channel 对称 INT4 | per-block64 非对称 INT4（≈group_q4） |
|---|---|---|
| gate_proj | **18.3 %** | 4.4 % |
| up_proj | **17.5 %** | 4.3 % |
| down_proj | **21.3 %** | 4.3 % |

**FFN 输出误差 vs MLX group_q4**

| 变体 | FFN 相对误差 |
|---|---|
| 冻结 per-channel 对称 INT4 | **32.2 %** |
| per-block64 非对称 INT4 | **4.5 %** |

**决定性实验（单层 L0）**：

| 误差来源 | RMSE @S=32 | RMSE @S=512 |
|---|---|---|
| **PLACEMENT**（同一融合模型 ANE vs CoreML-GPU） | **0.0057** | **0.0057** |
| **REPRESENTATION**（CoreML INT4 vs MLX group_q4） | **0.1825** | **0.1806** |

> **表征误差是 placement 误差的 32 倍。分歧不来自「把 FFN 放到 ANE」，而来自融合模型本身的 INT4 量化方案。**
>
> 支持证据：S=128（map 选 GPU、无 CoreML）时 logits **逐位相同**。

**那么换成数值忠实的量化，ANE 还快吗？**

| S | 冻结 per-channel（32% 误差） | per-block64 非对称（4.5% 误差） | MLX-GPU 参照 |
|---|---|---|---|
| 32 | **1.70 ms**（ANE 已验证） | **9.69 ms**（**未派发到 ANE**） | 2.87 ms |
| 512 | **18.32 ms**（ANE 已验证） | **72.75 ms**（ANE 已验证） | ~31.6 ms（Phase-3B） |

> 🟥 **数值忠实的量化在 ANE 上慢 4.0–5.7 倍**，S=512 时（72.8 ms）甚至比纯 MLX-GPU（31.6 ms）还慢一倍以上。
>
> **换言之：ANE 的速度优势恰好多来自那个更粗的量化；把保真度拿回来，优势就消失了。**

## 9.6 测量污染（三条重要的定量发现）

1. ⚠️ **同进程交替测 GPU/ANE 污染 2.75×**
   S=32：交替法 GPU **346** / Hyb **395** ms vs 隔离进程 GPU **130** / Hyb **118** ms。
   → **必须每配置独立进程。**

2. ⚠️ **decode 噪声 floor ≈ ±17%**（由同代码路径的 null 实验直接标定：map 在 S=1 选 GPU，与 decode_gpu 是**完全相同的代码路径**，比值就是纯噪声）
   | ctx | 32 | 128 | 512 | 1024 |
   |---|---|---|---|---|
   | map/gpu（应为 1.00） | 1.034 | 0.830 | 0.914 | 1.032 |
   → **任何小于该幅度的"加速"在本环境下不可声称。**

3. ⚠️ **每次 CoreML 调用约 1.3 ms 固定 dispatch 地板**，×32 层 = **每 token 约 42 ms**。S=32 时每层 predict = 1.56 ms，其中 **88% 是固定 dispatch 开销**，真正 ANE 计算只有 ~0.2 ms。

## 9.7 Amdahl 对账（算子级 1.5–2.3× 如何被摊薄到 1.1–1.9×）

| S | GPU FFN 总 ms | Hybrid FFN 总 ms | FFN 算子 speedup | FFN 占 baseline | Amdahl 预测 | 实测整体 |
|---|---|---|---|---|---|---|
| 32 | 92.1 | 62.2 | 1.481× | 0.613 | 1.248× | **1.276×** |
| 64 | 158.8 | 67.6 | 2.349× | 0.626 | 1.562× | **1.568×** |
| 160 | 236.0 | 207.2 | 1.139× | 0.669 | 1.089× | **1.074×** |
| 256 | 486.3 | 306.5 | 1.587× | 0.668 | 1.328× | **1.410×** |
| 512 | 1087.4 | 614.0 | 1.771× | 0.718 | 1.456× | **1.557×** |

Amdahl 模型与实测吻合在 **10% 以内**。**算子级 1.5–2.3× 的收益，在整模层面被 attention + embed + lm_head 摊薄到 1.1–1.9×，整体转化率约 0.6–0.8。**

**S=512 的墙钟分解**（Hybrid，wall = 972.3 ms）：

| 段 | 耗时 | 占比 |
|---|---|---|
| embed | 8.4 ms | 0.9 % |
| attention (MLX/GPU) | 374.0 ms | 38.5 % |
| post-attn RMSNorm | 39.9 ms | 4.1 % |
| **FFN 合计** | **614.0 ms** | **63.2 %** |
| — 其中 CoreML predict | 577.1 ms | 59.4 % |
| — host→CoreML 传输 | 0.12 ms | **0.01 %** |
| — CoreML→MLX 回传 | 14.4 ms | **1.5 %** |
| — 其余 host glue | 22.4 ms | 2.3 % |

## 9.8 ANE Dispatch Guard（请求 ANE ≠ 确认 ANE）

实现（`phase3c_core.ANEDispatchGuard`）：
1. **静态黑名单 `{96, 128}`** —— Phase-3B 证明这两个 shape CoreML 根本不派发到 ANE；
2. **滚动窗口中位数比值守卫** —— 最近 5 次该 shape 的 ANE 调用中位数 > 3× 该 shape 的 MLX-GPU FFN 延迟时判为静默 fallback，强制改走 GPU 且**该延迟永不记为 ANE 性能**。

**为什么用滚动窗口中位数而不是单次**：本机 ANE/GPU 延迟存在 ±30% 抖动与偶发 2–3× 尖峰，而 R3 的静默 fallback 是**系统性**的（每次慢 14–18×）。单次采样会把抖动误判为 fallback（**实测确实发生过：早期用单次判据时 S=32 被误 trip**）。

**机制测试**（用冻结的真实延迟，非合成）：PASS —— S=96 的 48.734 ms、S=128 的 62.946 ms 均被拒绝；黑名单外的 S=192 合成 fallback（9.2×）被拒绝；S=32 的真实 ANE 胜利（1.481 vs 2.302 ms）被接受；**单次 40 ms 抖动尖峰不触发 trip**。在真实 32 层 Hybrid 运行中，guard **全程未误触发**。

## 9.9 结论

1. 🟩 **能，但只在 prefill 且 S≥256。** 最大实测 1.87×（S=512），保守 1.66×，两次独立测量可复现。
2. 🟥 **不能变成用户感知的收益。** decode 落在 R1，Hybrid 与 baseline 逐位相同；生成型 E2E 中位仅 1.05×；冷启动因为 13.8–15.4 s 的 CoreML 模型加载比 baseline **慢 19%**，首 token 慢 3.8 倍。
3. 🟥 **而且收益不是免费的。** 冻结融合模型的 per-channel 对称 INT4 使 FFN 相对误差达 32%（group_q4 为 4.5%），top-5 一致性掉到 67–75%；而唯一数值忠实的替代量化在 ANE 上慢 4–5.7 倍。

> **速度与保真度在现有模型族里是耦合的，Phase-3C 没有找到兼得的配置。**

---

# 10. 阶段 Phase-3D —— 候选搜索（寻找既有保真度又有速度的量化形式）

**日期**：2026-09-11

## 10.1 目标

寻找"**既忠实又快**"的量化候选（**IDEAL candidate**）——即一种既能通过保真度门禁、又能被 ANE 高效执行的权重表示。

## 10.2 方法

10 个候选 **A–K,P**：per-tensor / per-channel / per-block(32/64/128) × INT4/INT8 × affine/symmetric。三层冻结门槛：**Gate A = 权重保真 / Gate B = FFN 输出保真 / Gate C = logits 保真**。

## 10.3 结果：找不到 IDEAL candidate

| 候选 | 表示 | 忠实? | ANE 可达? | E_repr | Barrier |
|---|---|---|---|---|---|
| A | MLX group_q4（参考） | ✅ | N/A | 0.0 | REFERENCE_ONLY |
| **B** | int4 per-channel 对称 | ❌ | ✅ | **0.2014** | REPRESENTATION |
| **C** | int4 affine block64 | ✅ | ❌ | 0.0428 | **COMPILER_LOWERING** |
| G | int8 per-channel 对称 | ✅ | ✅ | 0.0093 | NONE_DETECTED |
| **H** | int8 affine block64 | ✅ | ❌ | **0.0020** | **COMPILER_LOWERING** |
| K | int8 affine block32 | ✅ | ❌ | 0.0035 | COMPILER_LOWERING |

Barrier 位置计数：**`COMPILER_LOWERING` 7 / `REPRESENTATION` 5 / `REFERENCE_ONLY` 1**。忠实候选 5 个：**A(ref) / C / G / H / K**。

本阶段 B 报 best_speedup **3.2169×**。

## 10.4 结论

> **找不到 IDEAL candidate。** 快的（B）不忠实（权重误差 20%）；忠实的（C/H/K）被挡在 ANE 之外。

**结构性发现**：**忠实度最高的 H（0.20% 误差）反而最慢，因为它恰好是最被 lowering 排斥的 per-block 方案。**

## 10.5 发现的问题与后续修正

① 单个 candidate 的 speedup 数字**不稳定**（为 Phase-3E 的两轮 campaign 埋下伏笔）。

② 当时**未能分离 graph 编码层的误差**——Phase-3E 的 Layer C 用 fp16 源权重作参考才分离成功。

> ✅ **被后续修正**：**B 的 3.26× 被 Phase-3E 两轮独立 campaign 证伪为不可复现**（S=64：A=2.507 vs B=1.725；S=512：A=1.542 vs B=2.065）。但「Barrier 在 COMPILER_LOWERING」被 3E/3F 保留并加强。

---

# 11. 阶段 Phase-3E —— Barrier 定位（项目最关键的一步）

**日期**：2026-09-11 ｜ **这是全项目方法论密度最高、结论最硬的一份报告**

## 11.1 目标

**不搜新候选**，只回答一个问题：**性能—保真度的矛盾首次出现在哪一层？**

## 11.2 层模型

```
MLX group_q4 原始权重
        │
        ▼
[1] Weight Representation      ← Layer A 量测
        │
        ▼
[2] Quantization / Dequant     ← Layer A/B 量测
        │
        ▼
[3] CoreML Graph Encoding      ← Layer C 量测
        │
        ▼
[4] CoreML Compiler Lowering   ← Layer D 量测（★ 本次定位到的层）
        │
        ▼
[5] Device Dispatch            ← Layer D 量测
        │
        ▼
[6] ANE Hardware Execution     ← Layer D/E 量测
```

## 11.3 Layer A —— 表示保真（纯 NumPy，不涉及 CoreML）

用 NumPy 精确复现各候选声明的量化方案，与真实 MLX group_q4 重建权重对比。3 层（L0/L15/L31）× 3 投影（gate/up/down）。

| 候选 | 表示 | bits | group | affine | **权重相对误差** |
|---|---|---|---|---|---|
| **A** | MLX group_q4 | 4 | 64 | ✓ | **0.0000**（reference） |
| **B** | int4 对称 per-channel | 4 | — | ✗ | **0.1915** |
| P | int4 对称 block128 | 4 | 128 | ✗ | 0.1213 |
| D | int4 对称 block64 | 4 | 64 | ✗ | 0.1091 |
| F | int4 对称 block32 | 4 | 32 | ✗ | 0.0883 |
| E | int4 仿射 block32 | 4 | 32 | ✓ | 0.0687 |
| **C** | int4 仿射 block64 | 4 | 64 | ✓ | **0.0434** |
| G | int8 对称 per-channel | 8 | — | ✗ | 0.0097 |
| K | int8 仿射 block32 | 8 | 32 | ✓ | 0.0038 |
| **H** | int8 仿射 block64 | 8 | 64 | ✓ | **0.0021** |

**结论**：表示误差确实存在且差异巨大（B 是 C 的 4.4 倍）。但这是**已知的、可预期的**量化残差，不是 barrier——因为忠实表示（C/H/K）确实存在。

> **关键**：**B（最快）之所以快，是因为它把 4096 个权重压成 1 个 scale，语义上丢失了权重的幅度结构。** 这是「用保真度买速度」的**表示层**成本。

## 11.4 Layer B —— 数学等价（真实 Llama 激活）

输入 = 真实 32 层前向中该层 post-attention RMSNorm 的**真实激活**（非合成高斯）。

| 候选 | L0 | L15 | L31 |
|---|---|---|---|
| B | 0.2014 | 0.2414 | **0.3060** |
| C | 0.0428 | 0.0587 | 0.0822 |
| G | 0.0093 | 0.0116 | 0.0164 |
| H | **0.0020** | 0.0028 | 0.0033 |
| D | 0.1154 | 0.1565 | 0.1781 |
| E | 0.0683 | 0.0964 | 0.1444 |
| F | 0.0871 | 0.1220 | 0.1482 |
| P | 0.1156 | 0.1623 | 0.2143 |

**结论**：
1. **误差随深度单调增长**（B: 0.201→0.306；C: 0.043→0.082）——这是新发现，之前只在 L0 测量过。
2. **纯数学路径完全正确**：所有误差都能追溯到 Layer A 的权重误差，数学实现本身没有引入误差。
3. 因此 **barrier 不在 [2] Quantization/Dequantization 的数学侧**。

## 11.5 Layer C —— CoreML Graph 等价（★ 关键否定证据）

**这是本阶段最重要的"排除"结果。**

`E_graph_isolated` = 真实 CoreML 模型（CPU_AND_GPU）输出 vs **同一份 fp16 源权重**的 NumPy 数学。

> 必须用 fp16 源权重作参考，否则表征误差会泄漏进 graph 项——**这也是 Phase-3D 未能分离该层的原因**。

| 候选 | `E_repr`（Layer B） | **`E_graph_isolated`** | `E_total` | graph cosine |
|---|---|---|---|---|
| B | 0.20138 | **0.20155** | 0.20155 | 0.999976 |
| C | 0.04275 | **0.02569** | 0.02570 | 0.998539 |
| G | 0.00928 | **0.00930** | 0.00931 | 0.999996 |
| H | 0.00200 | **0.00194** | 0.00199 | 0.999996 |

**结论：`E_graph_isolated ≈ E_repr`，对所有候选成立；cosine ≥ 0.9985。**

> **CoreML graph 编码层（[3]）几乎不引入任何额外误差。图忠实地计算了它自己权重所表达的东西。**
> 因此 **barrier 不在 [3] CoreML Graph Encoding**。

## 11.6 Layer D —— 编译器 Lowering / 设备派发（★ Barrier 在这里）

### 11.6.1 核心证据：编译器的设备合法性判定

用 `coremltools.models.compute_plan.MLComputePlan` 逐算子查询 `supported_compute_devices`。**这是编译器层的权威证据**：确定性、无采样噪声——**比 `/usr/bin/sample` 更强：sample 只证明"跑了"，compute plan 证明"允许在哪些设备上跑"。**

**两个候选的 MIL 图结构完全相同**（都是 `const×2, constexpr_blockwise_shift_scale×3, linear×3, silu×1, mul×1`）：

| 候选 | `constexpr` scale 形状 | **`linear` supported** | **`linear` preferred** |
|---|---|---|---|
| **B** int4 per-channel | `[14336, 1]` | **`[CPU, ANE]`** | **ANE** |
| **C** int4 block64 | `[14336, 64]` | **`[CPU]`** ← 独占 | CPU |
| D int4 sym block64 | `[14336, 64]` | `[CPU]` | CPU |
| E int4 aff block32 | `[14336, 128]` | `[CPU]` | CPU |
| F int4 sym block32 | `[14336, 128]` | `[CPU]` | CPU |
| **G** int8 per-channel | `[14336, 1]` | **`[CPU, ANE]`** | **ANE** |
| **H** int8 block64 | `[14336, 64]` | `[CPU]` | CPU |
| K int8 aff block32 | `[14336, 128]` | `[CPU]` | CPU |
| P int4 sym block128 | `[14336, 64]` | `[CPU]` | CPU |

> **判别规则（唯一变量）**：`constexpr_blockwise_shift_scale` 的 **scale 最后一维**。
> `1`（per-channel/per-tensor）→ GEMM **ANE-legal**；`64/128`（per-block）→ GEMM **CPU-only**。

### 11.6.2 受控实验：granularity 是唯一判别变量

在**最小单 Linear 模型**（4096→4096，无 FFN、无 elementwise、无融合）上只改量化配置：

| 变体 | `linear` supported | ANE 合法？ |
|---|---|---|
| per_tensor int8 sym | `[ANE, CPU]` | ✅ |
| per_channel int8 sym | `[ANE, CPU]` | ✅ |
| per_channel int4 sym | `[ANE, CPU]` | ✅ |
| **per_block64 int4 sym** | **`[CPU]`** | ❌ |
| **per_block64 int4 affine** | **`[CPU]`** | ❌ |
| **per_block64 int8 affine** | **`[CPU]`** | ❌ |
| **per_block32 int8 affine** | **`[CPU]`** | ❌ |
| **per_block128 int4 sym** | **`[CPU]`** | ❌ |

> **granularity 与位宽、零点策略、图结构全部正交。8 个变体、100% 一致。**

### 11.6.3 决定性交叉验证：编译器**静默忽略** ANE 请求

同一 `.mlpackage`，只改 ComputeUnit 请求，看 `linear` preferred：

| 候选 | 请求 `CPU_AND_NE` | 请求 `CPU_AND_GPU` | 请求 `CPU_ONLY` | 是否响应 ANE 请求 |
|---|---|---|---|---|
| **B** (per-channel) | **ANE** \| ANE \| ANE | GPU | CPU | ✅ **是** |
| **C** (block64) | **CPU** \| CPU \| CPU | GPU | CPU | ❌ **否** |
| G (per-channel) | ANE \| ANE \| ANE | GPU | CPU | ✅ 是 |
| D/E/F/H/K/P | CPU \| CPU \| CPU | GPU | CPU | ❌ 否 |

> **C 对 `CPU_AND_NE` 与 `CPU_ONLY` 返回完全相同的结果——编译器把 ANE 请求当空气。**
>
> 这不是「ANE 跑得慢」，这是 **ANE 从未进入候选设备集**。9 个候选中 2 个（per-channel）响应请求、7 个（per-block）忽略请求，**100% 由 granularity 决定**。

### 11.6.4 ⚠️ 执行状态：`sample` 的假阳性陷阱

| 候选 | S=32 | S=64 | S=512 |
|---|---|---|---|
| B | VERIFIED_ANE | VERIFIED_ANE | VERIFIED_ANE |
| G | VERIFIED_ANE | VERIFIED_ANE | VERIFIED_ANE |
| **C** | GPU_FALLBACK | CPU_FALLBACK | ⚠️ **VERIFIED_ANE（假阳性）** |
| D/E/F/H/K/P | NOT_BUILT / GPU_FALLBACK | GPU_FALLBACK | ⚠️ VERIFIED_ANE（假阳性） |

> ⚠️ **本阶段发现的重要方法学陷阱**：per-block 候选在 S=512 会出现 ANE 栈帧，**但那是假阳性**。
>
> compute plan 显示：per-block 的 **GEMM 在任何 S 都是 `[CPU]` 独占**；S=512 唯一被移到 ANE 的是 **elementwise `mul`**。即 **CPU 做矩阵乘 + ANE 做一次逐元素乘 = 部分卸载**，实测比同模型 GPU 慢 **2.0–4.9×**。
>
> **判定规则：ANE 执行状态必须看 GEMM 的 `supported` 列表，绝不能只看 sample 有没有 ANE 帧。**

## 11.7 Layer E —— 性能（隔离进程 + 多轮重复）

**冻结方法学**：每配置独立进程；**两轮独立 campaign**（A: n=4，B: n=8），40–50 次迭代取中位；报告 median + min/max + spread。

| 候选 | shape | campaign A (n=4) | campaign B (n=8) | 跨 campaign 稳定？ |
|---|---|---|---|---|
| **G** int8 per-ch | **S=64** | **1.266** [0.501,1.305] | **1.188** [0.628,1.389] | ✅ **稳定 >1（仅此一项）** |
| G | S=32 | 0.829 | — | — |
| G | S=512 | 0.810（慢） | 1.032（略快） | ❌ 噪声带内翻转 |
| B int4 per-ch | S=64 | 2.507 | **1.725** | ❌ 不可复现 |
| B | S=512 | 1.542 | **2.065** | ❌ 不可复现 |
| C block64 | S=512 | **0.459（更慢）** | — | — |
| H block64 | S=512 | **0.364（更慢）** | — | — |

**结论**：
1. 🟥 **Phase-3D 报告的 B「3.26×」不可复现**。
2. 🟥 **GPU 参考跨进程漂移可达 2–3.9×**（同 shape 单 run 中位 2.7 → 5.2 ms）——**不稳定的是 GPU 侧，不是 ANE 侧**。
3. 🟩 **唯一跨两轮稳定且 >1 的加速是 G@S=64 = 1.19–1.27×**，但幅度仅约 1.2×，且 S=32/S=512 无优势。
4. 忠实的 per-block（C/H）在 ANE 上**确定性地更慢**（0.36–0.46×），因为 GEMM 实际跑在 CPU。

## 11.8 Barrier Localization Matrix（最终合成）

| 候选 | 家族 | 忠实? | ANE 可达? | `E_repr` | GEMM supported | best speedup | **Barrier 位置** |
|---|---|---|---|---|---|---|---|
| A | reference (MLX) | ✅ | N/A | 0.0000 | — | — | REFERENCE_ONLY |
| **B** | per-channel int4 | ❌ | ✅ | **0.2014** | `ANE\|CPU` | 3.22* | **REPRESENTATION** |
| **C** | per-block64 int4 aff | ✅ | ❌ | 0.0428 | **`CPU`** | 0.88 | **COMPILER_LOWERING** |
| **G** | per-channel int8 | ✅ | ✅ | **0.0093** | `ANE\|CPU` | **1.19–1.27** | NONE_DETECTED（唯一两关全过） |
| **H** | per-block64 int8 aff | ✅ | ❌ | **0.0020** | **`CPU`** | 0.80 | **COMPILER_LOWERING** |
| K | per-block32 int8 aff | ✅ | ❌ | 0.0035 | `CPU` | — | COMPILER_LOWERING |
| D/E/F/P | 混合 | ❌ | ❌ | 0.068–0.116 | `CPU` | — | REPRESENTATION + COMPILER_LOWERING |

\* B 的 speedup 不可复现。

**结构性发现**：
- 忠实候选 5 个（A/C/G/H/K），其中 **3 个（C/H/K——即所有 per-block 忠实方案）被 `COMPILER_LOWERING` 挡在 ANE 之外**。
- **唯一同时满足「忠实 + ANE 可达 + 稳定 >1」的是 G（per-channel INT8）——但它只有 ~1.2×，且只在 S=64。**
- 忠实度最高的 H（0.20%）**反而最慢**（0.36–0.80×），因为它恰好是最被 lowering 排斥的 per-block 方案。

## 11.9 Q1–Q5 逐条回答

**Q1 — 最快的 INT4 per-channel 的性能优势来自 INT4，还是来自 per-channel 的简化？**
→ **来自 per-channel 的简化，不是 INT4 本身。** 决定性证据：**INT8 per-channel（G）同样 ANE-legal**，而 **INT4 per-block（D/C/E/F）一样被拒**。位宽对 ANE 合法性**完全无影响**；granularity 是唯一判别变量。省下的是「每行 4096 个权重共享 1 个 scale」的还原复杂度与语义保真度，**不是 4 bit 的字节数**——B(88.2MB) vs C(95.0MB) 权重只差 7.8%。

**Q2 — group-64 affine 的性能问题发生在 dequantization，还是 CoreML graph lowering？**
→ **发生在 CoreML compiler lowering，不在 dequantization 的数学侧。** 数学侧：C 的 dequant 是「每 64 元素 1 次乘加」，算术量可忽略，且 Layer B 证明其纯数学路径正确。系统侧：C 的 `linear` 算子 `supported=[CPU]`，ANE 请求被静默忽略。**dequantization 本身不是瓶颈；编译器不肯把 per-block dequant 折进 ANE GEMM 才是。**

**Q3 — 两个表示数学计算量接近，为什么一个能高效派发 ANE，另一个 fallback 或变慢？**
→ 差别**不在计算量，而在编译器的设备合法性判定**。两者 MIL 算子序列**完全相同**（唯一差别是 `constexpr_blockwise_shift_scale` 的 scale/offset 张量形状）。CoreML 对前者有 ANE 实现、对后者没有，于是前者全图落 ANE，后者全图落 CPU（S=512 时仅 `mul` 上 ANE，反而需要 CPU↔ANE 来回搬运，**比纯 GPU 还慢 2.0–4.9×**）。

**Q4 — 是否存在「忠实表示 + 数学便宜」但「CoreML lowering 低效」的情况？**
→ **存在，且这是本次的核心发现。** C 与 H 正是这种：H 的权重误差仅 0.20%（全家族最忠实）、数学路径完全正确、权重只比最快的 B 大 7.8%——但它的 GEMM 被编译器判为 CPU-only，ANE 上 0.36–0.80×。

**Q5 — 是否有明确证据表明 group-wise affine quantization 天然不适合当前 ANE 执行路径？**
→ **有强证据支持「当前 CoreML 执行路径不支持」，但不足以判定「ANE 硬件天然不适合」。**
- 支持 `LIKELY_COMPILER_CONSTRAINT`：per-channel 量化 GEMM 在同一台 M5、同一 CoreML 上**跑得很好**。**说明 ANE 硬件对「量化权重 + 反量化 + GEMM」这个模式是支持的**；缺的只是编译器把 per-block 粒度折叠进 ANE GEMM 的 lowering 支持。
- ⚠️ **不能写成 `LIKELY_HARDWARE_CONSTRAINT`**：没有任何证据表明 ANE 的 MAC 阵列无法表达分组 scale。反证是 per-channel（粒度=1 的特例）工作正常。
- 也**不能写成 `CONFIRMED`**：本结论建立在 coremltools 9.0 的降级行为之上。若有人用**原生 MIL 手工构造** per-block scale/shift 的 constexpr 节点，或 Apple 在未来 CoreML 版本补齐该 lowering，结论即被推翻。

## 11.10 Stop Conditions 判定

| Outcome | 条件 | 是否触发 |
|---|---|---|
| **A** | Faithful + VERIFIED_ANE + speedup > 1 | ⚠️ **形式上触发但幅度不足**：G@S=64 = 1.19–1.27×，忠实、ANE 可达，但仅 ~1.2×、仅单点 |
| **B** | 所有忠实表示 VERIFIED_ANE 且 speedup ≤ 1 | ✅ **成立**：C/H/K 数学与 graph 均正确，但在 ANE 上 ≤1（0.36–0.88×） |
| **C** | 忠实表示 graph 正确但 ANE 一致 fallback | ✅ **成立**：所有 per-block 忠实候选在 S=32/64 一致 fallback |
| **D** | 忠实表示数学路径本身已昂贵 | ⚠️ **部分成立**：忠实度的可行边界被 REPRESENTATION 约束 |

→ **B、C、D 同时成立，A 仅边际成立。**

## 11.11 最终判定

```
REPRESENTATION_BARRIER_STATUS = STRONGLY_SUPPORTED
PRIMARY_BARRIER_LOCATION = COMPILER_LOWERING（次位：REPRESENTATION）
```

**为何不是 `LIKELY`（比 Phase-3D 升一级）**：补齐了**三条独立且互相印证的直接证据**：
1. **编译器设备合法性**：per-block GEMM `supported=[CPU]`（7 个候选一致）；
2. **受控实验**：最小单 Linear 模型上 granularity 是唯一判别变量（8 变体，与位宽/零点/图结构正交）；
3. **请求-响应测试**：per-block 候选对 `CPU_AND_NE` 与 `CPU_ONLY` 返回**完全相同**结果。

**为何仍不是 `CONFIRMED`**：未排除「手工原生 MIL 可以写出 ANE-legal 的 per-block 表示」这一替代解释。

**回答统领性问题**「为什么当前系统无法同时获得 MLX Llama 的保真度与 ANE 的性能优势」：

> **因为「数值忠实」在本模型家族里要求 per-block(≥64) 的量化粒度，而 CoreML 编译器恰好只把 per-channel/per-tensor 粒度的量化 GEMM 降级到 ANE。两个条件互斥，于是忠实的表示全部被推回 CPU，快的表示全部牺牲保真度。**

## 11.12 留下的唯一活口（→ Phase-3F）

> *「未尝试手工原生 MIL 构造 ANE-legal 的 per-block 表示 —— 这正是唯一可能推翻 `STRONGLY_SUPPORTED` 的方向。」*

---

# 12. 阶段 Phase-3F —— 原生 MIL 构造测试（终局）

**日期**：2026-09-12 ｜ Proteus-1 的最后一次最小验证

## 12.1 目标

回答 Phase-3E 留下的唯一活口——二选一：

- **H0（后端限制）**：原生 MIL 构造的 block64 `linear` 也是 `supported=[CPU]` → 瓶颈在编译器/ANE 后端，与构建路径无关。
- **H1（构建路径限制）**：原生 MIL 构造的 block64 `linear` 能到 `supported=[CPU,ANE]` → 是 coremltools 量化 pass 弄丢了 ANE 合法性。

## 12.2 方法

用 `coremltools.converters.mil.Builder` 手写 `@mb.program`（`opset_version=iOS18`），通过 `ct.convert(source="milinternal")` 编译成 MLModel，`constexpr_blockwise_shift_scale` 与 `linear` 这两个 op **完全由手工拼装**，**不经过** `linear_quantize_weights`。

权重 = **真实 Llama layer-0 `gate_proj`**（4096→14336 单 linear）。**唯一权威证据 = `MLComputePlan` 的 `LINEAR_SUPPORTED_DEVICES`**（不是 `/usr/bin/sample`）。

| 变体 | 构建路径 | 量化 | 期望 |
|---|---|---|---|
| **A1** | coremltools | per-channel INT4 | **阳性对照**（期望 `[CPU,ANE]`） |
| **B1** | coremltools | per-block64 | **阴性对照**（期望 `[CPU]`） |
| **C1** | **原生 MIL** | per-block64 affine | **H1 的判定实验** |
| **D** | **原生 MIL** 粒度扫描 | per-channel / block32/64/128 | 确认粒度仍是唯一判别变量 |

## 12.3 主证据：编译器设备合法性

| 变体 | 构建路径 | `linear` supported | ANE 合法？ |
|---|---|---|---|
| **A1** per-channel | coremltools | **`[CPU, ANE]`** | ✅ |
| **B1** block64 | coremltools | **`[CPU]`** | ❌ |
| **C1** block64 | **原生 MIL** | **`[CPU]`** | ❌ |
| D per-channel | 原生 MIL | **`[CPU, ANE]`** | ✅ |
| D block32 / 64 / 128 (+affine) | 原生 MIL | `[CPU]` | ❌ |

```
C1 (原生 MIL block64)  linear.supported = [CPU]   ← 与 B1 (coremltools block64) 逐字相同
```

> **判定**：H1（"手工原生 MIL 可绕过 coremltools 量化 pass 到达 ANE"）**被证伪**。同一份 block64 权重、同一条 `constexpr_blockwise_shift_scale→linear` 图，无论由 coremltools 量化 pass 生成还是手工 MIL 生成，编译器都判定 `linear` 为 `supported=[CPU]`。

## 12.4 图同一性

8 个变体的 MIL 算子序列**完全相同**（`constexpr_blockwise_shift_scale | const | linear`），**唯一差别是 `scale` 张量的最后一维**（`[14336,1]` vs `[14336,64/128/32]`）。

## 12.5 正确性与数学等价性

| 变体 | 基准 | real 输入 | random 输入 | 解读 |
|---|---|---|---|---|
| A1 (coremltools per-ch) | vs fp16 | cos=0.990 | cos=0.984 | per-channel 本身有 ~1.5% 量化残差 |
| B1 (coremltools block64) | vs fp16 | cos=**0.9998** | cos=0.9997 | coremltools block64 忠实 |
| **C1 (原生 MIL block64 affine)** | vs fp16 | cos=0.855 | cos=0.754 | 见下注 |
| D per-channel (原生) | vs A1 | cos=**0.99998** | cos=0.99996 | **原生 per-channel == coremltools per-channel，逐位等价** |
| D block64 (原生, 对称) | vs B1 | cos=**0.9966** | cos=0.9941 | **原生 block64 == coremltools block64，数学等价** |

> **关键解读**：**对称 per-block 原生 MIL（D_block64）与 coremltools block64 的 cos = 0.994–0.997 → 原生 MIL block64 在数学上等价于 Phase-3E block64。**
>
> **C1（affine block64 原生）的 cos=0.85 是"构建器编码细节"，不是编译器问题。** 手工 affine 量化没有精确复刻 coremltools 内部的 affine 反量化约定（coremltools 的 B1 实际是**对称** per-block，blob 里无 offset）。这是**量化器编码差异**，而 C1 的 compute-plan 结论（CPU-only）与编码无关。
>
> 按 Phase-3F 的 Q2 护栏：**绝不能把"我的手工编码没复刻对"误判为"原生 MIL 不可达 ANE"**——compute-plan 才是判定依据。

## 12.6 Stop Condition 判定

| Outcome | 条件 | 是否触发 |
|---|---|---|
| **A** BREAKTHROUGH（原生 block64 ANE-legal 且等价） | C1 `linear.supported` 含 ANE 且数学等价 | ❌ **未触发**：C1 = `[CPU]` |
| **B** BACKEND_BARRIER_SURVIVES（两条路径都 CPU-only） | 原生 MIL 与 coremltools 路径 block64 均 `[CPU]` | ✅ **触发**：C1 与 B1 同为 `[CPU]` |
| **C** INCONCLUSIVE（API 无法构造等价原生 MIL） | 原生 MIL 根本构造不出等价图 | ❌ 未触发：对称原生 block64 已验证等价 |

## 12.7 最终判定（Proteus-1 的终点）

```
PHASE_3F_HYPOTHESIS          = H0 (BACKEND LIMITATION)
REPRESENTATION_BARRIER_STATUS = VERY_STRONGLY_SUPPORTED   (由 STRONGLY_SUPPORTED 升级)
PRIMARY_BARRIER_LOCATION      = COMPILER_LOWERING          (经 coremltools + 原生 MIL 双路径验证)
STOP_CONDITION                = B (BACKEND_BARRIER_SURVIVES)
```

> **回答统领性问题**「block-wise 量化 linear 的 CPU-only，是 coremltools 构建路径还是 CoreML 编译器后端造成的？」
>
> **是 CoreML 编译器/ANE 后端造成的。** 我们绕开了 coremltools 的量化 pass、用手写原生 MIL 重建了同一条图，per-block64 的 `linear` 仍然 `supported=[CPU]` 独占。coremltools 构建路径这一最后替代解释已被排除。

---

# 13. 项目转折 —— 从 Proteus-1 到 Proteus-2

## 13.1 Proteus-1 的终点状态

**日期**：2026-09-12 ｜ **状态**：`FROZEN`

```
FINAL_PROJECT_STATUS    = 技术上成功（5 条普适发现 + 11 条路线被严格证伪 + 可复用工具链与测量协议）；
                          产品目标未实现（未找到任何保真前提下超越 MLX GPU 的配置）
ORIGINAL_GOAL_STATUS    = 部分达成 —— "小内存"✅ 与"大模型"✅ 由 MLX 4-bit 生态解决（非 Proteus 功劳）；
                          "高速度"❌ 未改善，瓶颈是内存带宽这一硬件常数
CURRENT_BEST_RUNTIME    = MLX GPU 单设备（fp16 compute + group_q4 权重），FFN 达同热态 matmul 峰值 86.5%
```

**六层判定链（Proteus-1 的最终答案）**：

```
MLX group_q4 原始权重
[1] Weight Representation   ← 测：表示误差存在且巨大（per-channel 0.18 vs per-block 0.043）
[2] Quantization / Dequant  ← 测：纯数学路径正确，误差全部来自权重残差
[3] CoreML Graph Encoding   ← 测：E_graph ≈ E_repr，cosine ≥ 0.9985 → 【已排除】
[4] CoreML Compiler Lowering← ★ Barrier 在这里（双路径验证）
[5] Device Dispatch         ← 主因的下游表现
[6] ANE Hardware Execution  ← 【无证据支持硬件限制】
```

## 13.2 Proteus-1 对下一阶段的建议（不预设结论）

障碍在 `COMPILER_LOWERING` → 突破点不是"更细的架构"，而是"**绕开 CoreML lowering 的执行路径**"。

1. 🟩 **不要放弃 ANE 路线** —— 障碍不在硬件。
2. 🟥 **不要继续尝试突破 CoreML block-wise lowering** —— 已多轮独立验证为 backend barrier。
3. 🎯 **唯一跨两轮稳定 >1 的是 G（int8 per-channel）@S=64 ≈1.2×** —— 幅度不足以支撑架构决策。
4. 📌 **把「表示粒度 vs 编译器设备合法性」作为一等约束**：编译期查 `linear.supported`，不含 ANE 则判定该 FFN 不可卸载（**勿用运行时延迟启发式，会被假阳性欺骗**）。
5. 🚀 **评估 GPU/Metal 原生、GGUF/llama.cpp、或自研 IR/编译器路径**。

## 13.3 候选方向评分（PROTEUS2_CANDIDATES.md，状态 `PROPOSAL ONLY`）

| 候选 | 绕Barrier | 总目标 | 同精度 | 异构 | 可验证 | 综合 |
|---|---|---|---|---|---|---|
| **A MLX 深度优化** | ✅ | ✅ | ✅ | 🟨 | ✅ | **🟩 推荐** |
| **B Metal kernel** | ✅ | ✅ | ✅ | 🟨 | ✅ | **🟩 推荐** |
| **C GGUF/llama.cpp** | ✅ | ✅ | ✅ | 🟨 | ✅ | **🟩 强推荐（先做参照系）** |
| D 表示转译 | ❌ | 🟨 | ❌ | 🟨 | ❌ | 🟥 已证伪 |
| E HW-Aware Runtime | ❌(仅规避) | ✅ | ❌ | ✅ | ✅ | 🟨 天花板低 |
| F Proteus IR 编译器 | ✅ | ✅ | ✅ | ✅ | 🟥 | 🟥 接口缺失 |

**推荐的唯一下一步**：

> **先用 llama.cpp / GGUF 建立"外部参照系"，再决定自研方向。**

理由：①成本最低、信息量最大；②直接回答最关键的问题——*"我们在 MLX 上做到 1.87× 的 prefill 收益，到底是因为我们做得好，还是因为 MLX 基线本身偏慢？"*；③完全绕开已确认 Barrier 且不牺牲精度。

**H-P2-1（进入实验前先写下的可验证假设）**：

> 在 M5 / 16 GB 上，同一 Llama-3.1-8B-Instruct-4bit，**llama.cpp (Metal) 的 prefill 吞吐与 MLX group_q4 基线相比，比值 ∈ [0.8, 1.25] 之外**。
> - 若 llama.cpp 显著更快（**>1.25×**）→ MLX 路径有优化空间 → 走**候选 A**
> - 若相当（**0.8–1.25×**）→ 已接近 GPU 生态上限 → 走**候选 B** 或接受 GPU 上限
> - **Gate（正确性）**：logits **top-1 一致率 ≥ 0.95**，且 vs P6.2 冻结基线 **rmse ≤ 0.01**

---

# 14. Proteus-2 —— 外部参照系与执行前沿

## 14.1 Phase-1 —— 外部基线（首次测量被自己作废）

**日期**：2026-09-12 ｜ **问题**：MLX 原生 runtime 距成熟 GPU runtime 还有多远？

### 14.1.1 ⚠️ 第一次结果是无效的

**本机 16 GB 内存 swap 常驻 10–14 GB**，同配置摆动 **3–11×**；顺序扫描与受控交错给出**相反结论**。

> **判定：Gate P2-1 = C**（噪声 > 差异，不得下结论）

这是项目第一次**主动作废自己的测量结果**——不是数据不好看，而是数据不可信。

### 14.1.2 Phase-1b —— 洁净重测

用户清理内存后，**swap 降至 4.6 GB 且全程平稳**；受控交错 A/B（4 轮/形状）产出可信数据。

- 单 runtime 抖动降至 **1.02–1.90×**（原为跨 run 3–11×）
- **`R_overall_median = 0.823`** → **Gate P2-1 = B**
- prefill `R = 0.947`（持平），decode `R = 0.730`（MLX 领先）
- 公平性经 `mlx_lm` 独立交叉验证（**差异 <4%**）

> **结论：`GPU_RUNTIME_ECOSYSTEM_GAP = SMALL`** —— MLX 原生 runtime 与成熟 llama.cpp/Metal **同级**，没有大块可优化空间。

**这个结论直接关闭了两个候选方向**：候选 A（MLX 深度优化）与「MLX 基线偏慢」这一解释。

## 14.2 Phase-2.2 —— 执行前沿图（GPU 侧空间被钉死）

**日期**：2026-09-12 ｜ **问题**：在成熟 GPU runtime 之上，Transformer 算子级执行还剩多少真实性能空间？

### 14.2.1 墙钟分解（S=512 prefill）

**FFN 68.11%** | qkv_proj 11.39% | o_proj 6.70% | lm_head 6.03% | residual 2.04% | attention_core 1.96% | norm 1.89% | rope 1.82% | kv_cache 0.03%

（2 campaign × 3 粒度；instrumented 路径 bit-exact；**FFN 占比跨 1.74× 热态仅移动 0.68pp**）

> 独立复现了 Proteus-1 的 FFN=63.2%（本次洁净环境测得 **68.1%，更高**）。**FFN 比次热点大 6×。**

### 14.2.2 天花板先行实测（写任何 kernel 之前）

- FFN 有效 **10.05 TFLOP/s** vs 同热态 f16 峰值 **11.65 TFLOP/s** ⇒ **FFN 已达 ALU 峰值 86.5%**
- 理论可回收上限仅 **9.23% E2E**
- 中间激活流量全部消除也只值 **2.2% E2E**（激活 14.7 MB/layer，batch=1 太小）

### 14.2.3 Minimal SwiGLU fusion probe（自研 Metal kernel）

| 测量 | 结果 |
|---|---|
| kernel 独立测量 | **1.333×** |
| 真实 32 层内 | **0.991×** |
| E2E A/B（3 campaign） | **G = 0.988 / 0.990 / 0.998** ⇒ 无收益 |
| 保真度 | cos = 1.0000000000，rel_rmse = 5.6e-04 ✅ 过 Gate |

> **判定：`GPU_KERNEL_HEADROOM = LOW`（Gate P2-2）**
>
> **判据：FFN ALU 饱和，非访存瓶颈。** 三条独立证据一致：①fusion probe 无收益；②FFN 已 86.5% ALU 饱和；③流量上限仅 2.2%。

**结论**：**不触发 Phase-2B（自研 Metal kernel）**。原假设 **H-P2B-1（fused SwiGLU 降 FFN ≥15%）已被直接证伪**——不是"还没试"，是**测过并且无空间**。

> 📌 **一个重要澄清**：Proteus-1 的「FFN=63.2% 是最大杠杆点」这个前提**本身没错**，错在**假设它有未被用尽的余量**。

## 14.3 Phase-2.3 —— Direct ANE 探索（绕过 CoreML）

**日期**：2026-09-12 ｜ **问题**：是否存在绕过 CoreML lowering 的 Direct ANE 路径，让真实 group64 Quantized GEMM 上 ANE？

### 14.3.1 ⚠️ 本阶段自己推翻了自己的草稿

> **早期草稿判 `Outcome C (DEAD END)`**，理由"ANE 没有任何形式的 4-bit 分组反量化"。
>
> **更正为 `Outcome B — TECHNICAL PATH EXISTS`。** 报告**明确保留了这个错误与推翻它的实验**，并自评：「错在犯了 charter 明确警告的错：**把 op 级拒绝推广成可表示性**」。

### 14.3.2 ANEForge 确实绕过 CoreML

真路径（代码/二进制证据）：

```
Python → MIL(program(1.3) + BLOBFILE 常量权重) → ctypes
  → libane_e5rt_dispatch.dylib
  → dlopen(/System/Library/PrivateFrameworks/Espresso.framework/Espresso)
  → e5rt_e5_compiler_* / e5rt_execution_stream_*
  → ANECompiler + ANEServices → ANE 硬件
```

**确实绕过 CoreML**：`otool -L` 只链 Foundation/libobjc/libc++/libSystem，**零 CoreML 链接**。

**ANE 执行 VERIFIED**（device-mask A/B）：0x4（ANE-only）与 0x7（AUTO）数值**完全相同**，而 CPU（6.6e-3）/ GPU（2.1e-4）明显不同；栈帧 `ANEServicesProgramProcessRequestDirect`。

### 14.3.3 单 op 层面全是否定

| 尝试 | 结果 |
|---|---|
| `constexpr_blockwise_shift_scale` int8 | ✅ 可 / uint4 ❌ 拒（**6/6 vs 0/6** 复现），且不收 shift |
| `constexpr_affine_dequantize` | 只收 1-D `[N]` scale，组化 `[N,NB]` 全拒 |
| `constexpr_lut_to_dense` | 拒 per-block palette |
| blockwise 输出作 matmul 权重操作数 | ❌ 必须经 `add(+0)` 桥接 ⇒ 物化稠密 fp16 |

### 14.3.4 ★ 但 group64 仍可表达——用分解

$$Y = \sum_{b} X_b \cdot \text{dequant}(q_b, s_b)^T \quad (b = 1..NB,\ \text{block\_size}=64)$$

- block 轴 = group 轴，每项 `affine_dequantize(scale=[N])` 可编译
- P1 隔离实验 **cos = 1.00000000**；NB = 4/16/64 全 COMPILE-OK
- 真实层形状 vs 精确 group_q4 **cos 0.99998**（表示误差 5.91e-03，在 Gate 内）

**代价**：每个部分和都是完整 `[1,S,N]` fp16 ⇒ 流量 **∝ NB·S**。

- **S=512：比值带 0.14–0.32（MLX/ANE，任何组合都输）**
- **S=1：比值带 0.57–1.11 ⇒ UNRESOLVED**
- block-size 扫描 BS=512（8 partials）最快 6.377 ms，**仍输 MLX 5.795 ms**，且已非 group64

**MLX group_q4 语义（实测校正）**：**`w = q*scale + bias` 每 64 块**（`(q-bias)*scale`、`q*scale` 都错，rel_rmse 2.74）。

### 14.3.5 结论

> **`DIRECT_ANE_PATH = PARTIALLY_VIABLE`** —— ANEForge 能让真实 group64 以同等块结构上 ANE，但**必须用分解**，且 **S=512 prefill 比 MLX 慢 3–7×**。
>
> **重新界定 Proteus-1**：barrier 不再是 `COMPILER_LOWERING`（分解能表达 group64），而是**吞吐/结构**。

**⚠️ 热态混淆的扩展发现**：热态混淆**也影响 MLX GPU 参考本身**（跨 run **2.2×**），而 ANE 计时反而稳定（1.01×）——**跨 runtime 比较必须把两侧的热态都当作变量**。

## 14.4 Phase-2.4 —— ANE 原生算力边界（ANE 路线的判决）

**日期**：2026-09-12

> **Verdict：`Outcome C — ANE_NATIVE_FRONTIER ≤ MLX_GPU`**
> **`DIRECT_ANE_STATUS = PERFORMANCE DEAD END`**（group64/int4 具体为 `ARCHITECTURALLY_BLOCKED`）
> **Stop condition 在 Experiment A 触发**（charter 规定：dense ANE ceiling 不能超 MLX GPU）

### 14.4.1 Experiment A：dense FP16 ceiling（2 campaign × 17 配置 × 4 reps）

| 形状 | S | ANE ms | GPU ms | 慢 | ANE TF/s | ANE GB/s |
|---|---:|---:|---:|---:|---:|---:|
| 4096→14336 | 1 | 5.69 | 1.13 | **5.04×** | 0.02–0.11 | 20.7 |
| 4096→14336 | 64 | 5.78 | 1.61 | 3.59× | 1.30–4.63 | 20.7 |
| 4096→14336 | 128 | 5.89 | 2.17 | 2.71× | 2.55–6.87 | 20.6 |
| 4096→14336 | 512 | 9.22 | 7.78 | **1.18×** | 6.53–7.40 | 14.8 |
| 14336→4096 | 1 | 5.74 | 1.36 | **4.21×** | 0.02–0.10 | 20.5 |
| 14336→4096 | 512 | 28.69 | 7.75 | **3.70×** | 2.10–7.84 | 4.1 |
| 4096→4096 | 1 | 1.71 | 0.52 | **3.32×** | 0.02–0.07 | 19.9 |
| 4096→4096 | 512 | 2.88 | 2.43 | **1.19×** | 5.96–6.87 | 14.4 |

> **0/34 配置 ANE 胜**；最好 1.12–1.19× 慢，最差 5× 慢；ANE 峰值 **~6.5 TFLOP/s** vs GPU **~8–12 TFLOP/s**。

**两个 regime 都输**：
- 权重受限（S≲256）：**5×**（~20 vs ~100 GB/s）
- 算力受限（S≳512）：**1.3–1.8×**（~6.5 vs ~8–12 TFLOP/s）

**额外发现**：
- `14336→4096` 在 S=512 比 `4096→14336` **慢 3.1×**（28.7 vs 9.2 ms），**同 FLOPs 同权重字节** ⇒ GEMM 效率强依赖 K/N 哪个大
- `14336→4096` 在 S=128 **编译失败**（两 campaign 复现）

### 14.4.2 「ANE 权重流 ~20 GB/s」的证据链（后来被部分推翻）

- 权重尺寸扫描：8.4 MB→0.247 ms、16.8 MB→1.014、33.6 MB→1.761、67.1 MB→3.394、117.4 MB→5.684（线性，~20 GB/s）
- **决定性实验**：固定 33.6 MB 权重，把算术量放大 256×（S=1→256），墙钟 **1.71 / 1.72 / 1.72 / 1.78 / 1.72 ms —— 完全不变**，TFLOP/s 从 0.02 涨到 4.99
- 跨三种矩阵形状、跨 11 个 batch size 复现
- 排除 wrapper 伪影：ANEForge dispatch floor 仅 **0.20 ms**（拟合 R²=1.0000）

### 14.4.3 Q2 表示阶梯

| 表示 | 状态 | 速度 | 误差 |
|---|---|---|---|
| fp16 dense (exact) | **VERIFIED_ANE** | 5.83→9.13 ms | cos 1.00000000，117.4 MB/layer |
| **INT8 per-channel** | **VERIFIED_ANE** | **0.99→5.03 ms** | 单投影 cos 0.9999554，rel 9.16e-03，58.7 MB |
| INT4 per-channel | **NOT_SUPPORTED** | — | uint4 被 `affine_dequantize` 拒 |
| INT8 block64（单 op） | PARTIAL_OFFLOAD | 5.68→6.05 ms | 5.91e-03 |
| INT4 block64（单 op） | **NOT_SUPPORTED** | — | 6/6 复现 |
| **INT4 block64 分解** | **VERIFIED_ANE** | — | cos 0.99998，rel 5.91e-03，33.0 MB |

**唯一原生快的是 INT8 per-channel**，赢只因为**权重字节减半**（58.7 vs 117.4 MB）对 20 GB/s 上限。

受控 A/B vs MLX group_q4（同进程交替 5 reps，最大状态漂移 13%）：

| S | MLX ms | ANE ms | MLX/ANE | cos |
|---|---:|---:|---:|---:|
| 1 | 0.444 | 0.923 | **0.480** | 0.9999563 |
| 32 | 0.758 | 0.995 | 0.761 | 0.9999574 |
| 128 | 1.698 | 1.183 | **1.436** | 0.9999570 |
| 512 | 6.631 | 5.681 | **1.167** | 0.9999554 |

### 14.4.4 ★ 但该路径过不了 Gate B（本阶段最重要的测量）

| 层级 | int8 per-channel vs 精确 group_q4 |
|---|---|
| weight error（gate/up/down） | 9.16e-03 / 8.73e-03 / 1.09e-02 |
| **单投影**输出（S=512） | cos 0.99995542，rel_rmse **9.16e-03** ✅ 过 ≤1e-2 Gate |
| **完整 FFN**输出（S=128） | cos 0.99988306，rel_rmse **1.53e-02 ❌ 未过** |

> **误差被 SwiGLU 非线性放大 1.67×，跨过门禁线。**
>
> 且它用 **58.7 MB/layer = group_q4(33.0 MB) 的 1.8×**，违背「小内存」目标。

### 14.4.5 Q3 分解记账（S=512，R²=1.0000）

$$T_{total} = 0.201\,\text{ms(dispatch)} + NB \times 0.412\,\text{ms(每块GEMM)} + (NB-1) \times 0.211\,\text{ms(累加)}$$

NB=64（真 group64）：
- 每块 GEMM **26.39 ms（66%）**
- 部分和累加 **13.30 ms（33%）**
- dispatch 0.20 ms（0.5%）
- **总计 39.89 ms**

> **机制**：每块写完整 `[1,S,14336]` fp16 partial（S=512 时 14.7 MB），64 块 = **940 MB 写 + ~1.85 GB 读回 ≈ 2.8 GB 流量，只为了产出一个 14.7 MB 的结果**。

### 14.4.6 Q4 反事实 roofline（**MODELLED 非实测**）

| 场景 | 时间 | 相对 MLX |
|---|---|---|
| IDEAL_0 实测基线 group64 分解 | 39.89 ms | 6.02× 慢 |
| **IDEAL_1 部分和无物化**（MODELLED） | 13.28 ms | **2.00× 慢** |
| **IDEAL_2 原生 int4-group64 权重操作数**（MODELLED） | 1.67 ms | **0.25×（快 4×）** |
| IDEAL_3 IDEAL_2 + 单次融合 dispatch（MODELLED） | 1.47 ms | 0.22×（快 4.5×） |
| 参考：int8 per-channel（现存）实测 | 5.68 ms | 快 1.17× |

> **决定性行 = IDEAL_1**：**即使部分和物化完全免费，group64 分解仍慢 2×**。唯一超过 MLX 的路线是 IDEAL_2/3，需要 2.3 已证**不存在**的 ANE op。IDEAL_2/3 **无法校准**。

### 14.4.7 四阶段闭环

| 阶段 | 问题 | 答案 |
|---|---|---|
| Proteus-1 | CoreML 能否 lower group64 到 ANE？ | 否（`COMPILER_LOWERING`） |
| Proteus-2.2 | GPU kernel 有 headroom 吗？ | 否（FFN 已达机器峰值 86.5%） |
| Proteus-2.3 | Direct ANE 能表达 group64 吗？ | **能（分解）**，但慢 6× |
| **Proteus-2.4** | **ANE 的真实算力边界在哪？** | **~6.5 TFLOP/s、~20 GB/s —— 两个 regime 都低于 GPU** |

> **按 charter 停止，不进入 Proteus-2.5。**

**⚠️ 数字不一致提示**：本报告正文标题写「34 个实测配置」，Artifacts 写「18 configs」，§7 与 ROADMAP 写「17 配置 × 2 campaign，ANE 0/17 胜」——三处口径不同，本报告如实并列呈现，不做取舍。

---

# 15. 更正链全图 —— 项目如何一次次推翻自己

> **这一章是本报告最重要的部分。** Proteus 项目的核心价值不在于它得出了什么结论，而在于它**系统性地推翻了自己的结论**，并且每一次推翻都有可复现的数据链。
>
> 一份健康的实验记录，其"被推翻的结论"列表应该和"确认的结论"列表一样长。本项目两者都长。

## 15.1 主更正链（17 条）

### 链条 A：Proteus-1 内部（表示层 → 编译器层）

| # | 旧结论 | 出处 | 修正 | 依据 |
|---|---|---|---|---|
| A1 | fused-ANE 在 S=512 **输** GPU（0.76×） | Phase-3A | **赢 ≈1.70×** | GPU 基线测低：12.89 → **31.63 ms**（复检中位 35.34）。12.89 ms 隐含 ~14 TFLOPS，超 M5 fp16 能力 |
| A2 | GPU 基线 S=512 = 12.89 ms | Phase-3A | **31.63 ms** | Phase-3B 严格复测 |
| A3 | B（int4 per-channel）「**3.26× 加速**」 | Phase-3D | **不可复现**（S=64: 2.507 vs 1.725；S=512: 1.542 vs 2.065） | Phase-3E 两轮独立 campaign |
| A4 | 「`sample` 有 ANE 栈帧 = ANE 在跑」 | Phase-3B/3C 早期 | **假阳性**：per-block GEMM 永远 CPU-only，S=512 只有 elementwise `mul` 上 ANE（部分卸载反而慢 2.0–4.9×） | Phase-3E §5.4 |
| A5 | S=160/256 prefill 加速 1.60×/1.63× | Phase-3C | **不可复现**，落在环境漂移带内 | Phase-3C §9 |
| A6 | 「INT4 ANE 有优势」 | Phase-2B | 精确化为「**per-channel** INT4 ANE 有优势」；**忠实的 per-block64 慢 4–5.7×** | Phase-3C/3E |
| A7 | Barrier 可能在天平另一端（H1 构建路径） | Phase-3E 留的活口 | **H1 证伪**，H0 成立；`VERY_STRONGLY_SUPPORTED` | Phase-3F 原生 MIL |

### 链条 B：Proteus-2 内部（测量污染 → 结论作废 → 重测）

| # | 旧结论 | 出处 | 修正 | 依据 |
|---|---|---|---|---|
| B1 | 首次外部基线可下结论 | Phase-1 | **Gate P2-1 = C（噪声>差异）** | swap 常驻 10–14 GB，同配置摆动 3–11× |
| B2 | Gate P2-1 = C | Phase-1 | **Gate P2-1 = B**（R=0.823） | Phase-1b 洁净重测，swap 降至 4.6 GB |
| B3 | 下一步进 Proteus-2B（自研 Metal） | ROADMAP 原计划 | **不触发** | Gate P2-2 = LOW，headroom 9.23% < 10% |
| B4 | H-P2B-1（fused SwiGLU 降 FFN ≥15%） | 原假设 | **证伪**——不是"还没试"，是"测过且无空间" | E2E G = 0.988/0.990/0.998 |
| B5 | Direct ANE = Outcome C（DEAD END） | 2.3 早期草稿 | **Outcome B（TECHNICAL PATH EXISTS）** | 分解逃逸口 cos 0.99998；**报告保留错误与推翻它的实验** |
| B6 | 环境门禁（swap/pressure/thermal）足够 | Protocol 原文 | **不足**：burst probe 假阴性 | 58 ms burst 在两态读同一 ~11.8 kGFLOP/s |

### 链条 C：★「16 MiB 字节律」三部曲（最精彩的一段）

```
2.4 的 Outcome C
   ↑ 建立在「ANE 权重流 ~20 GB/s」之上
   ↓
CROSSVALIDATION 用同一 4096×4096/33.55MB 矩阵测出 113.5 GB/s（差 5.6×）
   → 定位 K∈[4080,4112] 33 宽窄槽（「K 编译器悬崖」）
   ↓
BYTESIZE_LAW 再推翻「K 悬崖」本身
   → 固定 K=4096 只动 N，K 每行相同却出现 2.5× 落差 ⇒ K 是无关变量
   → 真因是「字节数落在 16 MiB 整数倍 ±0.4%」
   ↓
零填充 K 4096→4160 得 2.58×（10/10 命中，maxdiff 精确 0）
   ↓
OFFLOAD_VERDICT 三臂实验证明卸载仍零和
   → ane/dram = 0.906，填充后 int8 8.13 GB/token vs group_q4 4.52 GB
```

> **判决的演进**：**"表示不可行" → "可表示但慢" → "慢的前提测错了" → "前提修好后仍然慢，且原因是共享 DRAM 已被吃满"**

## 15.2 横向更正表（OFFLOAD_VERDICT §5，10 条）

| # | 原认知 | 修订后 |
|---|---|---|
| 1 | ANE 外部取数 ~20 GB/s 普适上限 | 🟨 修订：**fp16 专属**；int8 逐通道可达 ~63 GB/s。不影响结论 |
| 2 | ANE 持续性能可能优于 burst | 🟥 否定：ANE 并发比等带宽 CPU 内存流**更伤** decode（0.906×） |
| 3 | 本机 GPU 持续塌缩 2× 污染所有持续测量 | 🟨 限定：**纯 decode 工况下不触发**（120 s 平坦无衰减） |
| 4 | 同进程交替测 GPU/ANE 互污染 | 🟥 升级为定量：**GIL 伪影单独吃掉 29%** |
| 5 | 推测解码 1.61× | 🟩 上调并上线 1.575×（干净）/ 1.71×（网关）；n=6/8 有害 |
| 6 | 推测解码 token 完全一致 | 🟨 精确化：fp16 ULP 平局 argmax 翻转，**非逻辑错误** |
| 7 | 推测解码总是更快 | 🟥 限定仅低温（temp 0.7 为 0.904×），已加 max_temp 闸门 |
| 8 | K∈[4080,4112] 编译器悬崖 | 🟥 **证伪**（真因 16 MiB ±0.4%） |
| 9 | ANE fp16 取数上限 ~20 GB/s | 🟥 **证伪**（带外 fp16 ~54 GB/s） |
| 10 | int8 按 N 双模态机制未解释 | 🟩 **已解释**（N·K 命中 16 MiB 整数倍，23/23 可预测） |

## 15.3 后期自我推翻（最值得尊敬的四条）

| # | 报告 | 自我推翻的内容 | 依据 |
|---|---|---|---|
| 1 | **COMPUTE_PUSH** | 「ANE 小矩阵胜 8/9、最高 5.01×」→ **100% 是 GPU launch 开销假象** | 链式调用摊薄后 GPU 提升 9.21×，ANE 胜 0/4 |
| 2 | **MIDTERM_STATUS** | 「长上下文 decode 崩塌」→ **是递增顺序测量的热浸泡** | 冷却 150 s + 顺序翻转：short(879) 1.059 / long(7011) 0.983，比值 **0.928** |
| 3 | **AS_SUPPLEMENT** | 自己的「ANE 全面落败」→ **限缩为吞吐维度**；漏掉了**能效维度** | ANE 能效**全部 batch 都赢**（1.1–10×） |
| 4 | **PREFILL_CORRECTION** | 自己的「prefill 完全不变」→ **作为"Proteus 整体"陈述是误导的** | Proteus-1 确有 prefill 1.27–2.10×，但建立在 per-channel（过不了门禁） |

> **第 2 条特别值得注意**：报告还**指出自己的分析脚本 verdict 逻辑写错了**——`ctx_collapse_cause` 的 A/B 两相都内含塌缩，**相位中位数因此收敛**（23.99 vs 19.52 → 误判 INCONCLUSIVE）；实际信号是 **A 相 1.058→0.400、B 相冷却后回 1.011**，是教科书式可逆功耗塌缩。**当某相位自身在衰减时，相位中位数是错误统计量。**

## 15.4 ★ 16 MiB 字节大小律（纯原创发现）

**这是项目最有价值的原创科学发现。**

### 15.4.1 陈述

> **ANE 外部权重取数存在精确的「16 MiB 字节大小律」**：权重张量字节数落在 **2²⁴（16 MiB）整数倍 ±0.4%** 内 → 取数钉在 **~21 GB/s**；带外 → **~54 GB/s**。
>
> **判据是字节数，不是 K/N/形状。**

### 15.4.2 它统一解释了此前三个被当作独立 bug 的现象

| 旧记录 | 真相 |
|---|---|
| 「N=2048/fp16 下 **K∈[4080,4112] 编译器悬崖**」 | 该区间字节数都落在 16 MiB ±0.4% 内 |
| 「**fp16 ~20 GB/s 是硬件上限**」 | fp16 的真实 8B 形状恰好命中慢带；int8 恰好不命中 |
| 「int8 下 **N 为 4096 整数倍就慢**」 | 实际是 N·K 恰为 16 MiB 整数倍 |

### 15.4.3 决定性实验（固定 K=4096，只动 N，N=2048 fp16）

| N | MiB | rel | GB/s | 判定 |
|---:|---:|---:|---:|:--|
| 1984 | 15.500 | 0.0312 | 50.9 | fast |
| 2000 | 15.625 | 0.0234 | 49.6 | fast |
| **2040** | 15.938 | 0.0039 | **23.2** | **SLOW** |
| **2048** | 16.000 | 0.0000 | **20.2** | **SLOW** |
| **2056** | 16.062 | 0.0039 | **24.2** | **SLOW** |
| 2100 | 16.406 | 0.0254 | 52.1 | fast |
| 2160 | 16.875 | 0.0547 | 53.3 | fast |

> **K 每行相同却出现 2.5× 落差 ⇒「K 编译器悬崖」被证伪。**

### 15.4.4 定律验证

**23/23 命中，假阳性 0，假阴性 0。**
慢均值 **21.2 GB/s（n=11）**；快均值 **54.3 GB/s（n=12）**；**惩罚 2.57×**。

**杀手级判别**：同一个 `(N,K) = (4096, 2048)`
- fp16：32.00 MiB，rel 0.0000 → **22.7 GB/s SLOW**
- int8：8.01 MiB，rel 0.4995 → **40.5 GB/s fast**

> **同一 (N,K)，只有表示不同 ⇒ 排除任何形状/编译器解释。**

### 15.4.5 渐变边界（N=1024 fp16）

| K | MiB | rel | GB/s |
|---:|---:|---:|---:|
| 8050 | 15.72 | 0.0173 | 51.1 |
| 8110 | 15.84 | 0.0100 | 42.3 |
| 8140 | 15.90 | 0.0063 | 27.2 |
| 8170 | 15.96 | 0.0027 | 22.0 |
| **8192** | **16.00** | **0.0000** | **19.4** |
| 8214 | 16.04 | 0.0027 | 21.8 |
| 8244 | 16.10 | 0.0063 | 27.6 |
| 8274 | 16.16 | 0.0100 | 42.5 |
| 8300 | 16.21 | 0.0132 | 49.9 |

> 边界**对称陡峭**：**rel ≤ 0.004 全慢，rel ≥ 0.013 全快**，过渡带约 0.4%–1.3%（≈±64 KiB @16 MiB）。

### 15.4.6 真实 Llama-3.1-8B 形状落点

| 投影 | fp16 | 判定 | int8 | 判定 |
|---|---|---|---|---|
| q_proj 4096×4096 | 32.00 MiB rel 0.0000 | **慢** | 16.01 MiB rel 0.0005 | **慢** |
| o_proj 同 q_proj | — | **慢** | — | **慢** |
| k_proj 1024×4096 | 8.00 rel 0.5000 | 快 | 4.00 rel 0.2501 | 快 |
| v_proj 同 k_proj | — | 快 | — | 快 |
| gate_proj 14336×4096 | 112.00 rel 0.0000 | **慢** | 56.03 rel 0.4983 | 快 |
| up_proj 同 gate | — | **慢** | — | 快 |
| down_proj 4096×14336 | 112.00 rel 0.0000 | **慢** | 56.01 rel 0.4995 | 快 |

> **未填充 int8 下真实模型有 64 个投影（32 层 × {q_proj, o_proj}）落在慢带。**
>
> 这也解释了旧实测困惑：真实 gate_proj fp16 **5.736 ms / 20.5 GB/s** vs int8 **0.936 ms / 62.7 GB/s** —— fp16 的 112 MiB = 7×2²⁴ 恰在带内，int8 56.03 MiB（rel 0.4983）远在带外。**旧归因「fp16 路径硬件上限 20 GB/s」是错的。**

### 15.4.7 填充逃逸（零填充 K 4096→4160，数学恒等）

| 投影 | 未填充 | 填充后 | maxdiff | 加速 |
|---|---|---|---|---|
| q_proj | 16.01 MiB rel 0.0005，0.9277 ms，18.1 GB/s | 16.26 MiB rel 0.0161，**0.3333 ms，51.2 GB/s** | **0.000e+00** | **2.83×** |
| o_proj | 0.8729 ms，19.2 GB/s | 0.3448 ms，49.4 GB/s | **0** | **2.57×** |
| gate_proj（对照） | 0.9119 ms，64.4 GB/s | 0.9263 ms，64.4 GB/s | **0** | **1.00×** |

> **gate_proj 对照组 1.00× 至关重要**——它**排除了「填充有普遍好处」的替代解释**，证明收益确实来自逃出慢带。

**第二 campaign 跨层复现**（5 层 × 2 投影，奇数层反转变体顺序）：

L0 q 20.1→51.6（2.57×）｜L0 o 19.3→50.3（2.60×）｜L8 q 20.9→51.7（2.48×）｜L8 o 21.7→52.2（2.41×）｜L16 q 20.1→52.7（2.62×）｜L16 o 21.5→52.3（2.43×）｜L24 q 20.4→52.7（2.59×）｜L24 o 20.2→53.4（2.64×）｜L31 q 20.0→53.1（2.65×）｜L31 o 23.5→52.9（2.25×）

> **10/10 全命中，中位 2.58×，区间 [2.25, 2.65]，全部 maxdiff = 0。**

### 15.4.8 为什么它仍然救不活 ANE 卸载

按真实量化字节重算（填充后 int8 每 token **8.130 GB**，group_q4 **4.517 GB**）：

| 卸载比例 f | 总字节 GB | 相对 | @120 GB/s |
|---:|---:|---:|---:|
| 0.00 | 4.517 | 1.000× | 26.6 tok/s |
| 0.25 | 5.421 | 1.200× | 22.1 |
| 0.50 | 6.324 | 1.400× | 19.0 |
| 1.00 | 8.130 | **1.800×** | 14.8 |

> 填充没改变结论：ANE 唯一原生快的 int8 逐通道仍是 group_q4 的 **1.8 倍字节**，而 DRAM 已被 decode 吃满 **123.4 GB/s**。
>
> **唯一可能真正有价值的场景：ANE 独占整个模型（无 GPU 竞争），不在本项目目标内。**

## 15.5 未被推翻的结论（经多份报告交叉确认）

| 结论 | 交叉确认来源 |
|---|---|
| decode 顶 DRAM 屋顶线（118–133 GB/s，占理论 0.96–1.08） | OFFLOAD_VERDICT / MIDTERM / PROVENANCE 一致 |
| GPU 无 K=4096 悬崖（30.3/35.7/40.6/**50.2**/45.7/59.3/60.4 GB/s 平滑） | SPEEDUP_DIRECTIONS / FINAL_TECHNICAL 一致 |
| ANE 稠密算力上限 6.2–7.75 TFLOP/s（三独立测量一致） | COMPUTE_PUSH |
| 三层保真门禁（权重 / 单投影 / **完整 FFN**） | P2.4 / QUANT_SEARCH / FINAL_TECHNICAL 一致 |
| 同一 (N,K) fp16 慢 int8 快（(4096,2048) 22.7 vs 40.5） | BYTESIZE_LAW 杀手级判别 |
| FFN 已达 ALU 峰值 86.5%，kernel headroom <10% | P2.2（三 campaign） |

---

# 16. 找到的方案 —— Speculative Decoding

> **这是整个项目的转折点**：在穷尽了所有"让 ANE 帮忙"的路线后，项目意识到**唯一合法的出路不是换引擎，而是让一次前向产出多个 token**。

## 16.1 穷尽后的方向清单

| 方向 | 具体做法 | 结果 | 判定 |
|---|---|---|---|
| **ANE 直连** | 绕过 CoreML，用 ANEForge 私有 e5rt 把权重送上神经引擎 | 权重流 ~20–68 GB/s，算力 ~6.5 TFLOP/s，两 regime 都输 GPU | ❌ |
| **group64 分解** | 拆成 NB 个逐块 GEMM 以在 ANE 上表达 | 能表达（cos 0.99998），但慢 6× | ❌ |
| **Metal 自研 kernel** | 手写 SwiGLU fusion | E2E ≈ 1.0×（无收益） | ❌ |
| **GPU 维度补零** | 把 ANE 的 K=4096 悬崖移植到 GPU | GPU **无此悬崖** | ❌ |
| **更低位宽** | 4→3/2 bit（decode 带宽受限，字节减半即提速） | 权重 rel_rmse 崩到 **0.22 / 0.41** | ❌ |
| **Speculative decoding** | 小模型草拟、大模型批量验证 | **1.6–1.9×，且逐 token 基本一致** | ✅ **采用** |

## 16.2 为什么它能绕开带宽墙

**关键实测：一次 forward 验证 K 个 token 的成本几乎与验证 1 个相同。**

| 上下文长度 | K=1 | K=4 | K=8 | K=16 | **verify(8)/verify(1)** |
|---:|---:|---:|---:|---:|---:|
| ctx=128 | 253.7 ms | 265.6 | 312.7 | 340.4 | **1.23** |
| ctx=512 | 856.3 ms | 922.5 | 974.2 | 1327.5 | **1.14** |

> **验证 8 个 token 只比验证 1 个贵 14–23%。**
>
> 因为 decode 是**权重带宽受限**——权重读一遍，验证 1 个 token 还是 8 个 token，读的字节一样多。多出来的只是 KV-cache 那点激活流量。
>
> **理论上限 ≈ 6.5–7×（K=8 时）。**

**原理**：

```
普通 decode：每个 token 都要跑一次完整的 8B forward
            token1 → [8B forward] → token2 → [8B forward] → token3 → ...

Speculative：小草稿模型快速猜 K 个 token，大模型一次 forward 全部验证
             草稿: [0.5B] → 猜 "社会 发展 的 基础"
             验证: [8B forward × 1 次] → 检查这 4 个 token 对不对
             接受前 a 个匹配的 + 1 个修正 = 一次 forward 产出 a+1 个 token
```

## 16.3 关键改进一：草稿模型必须同 tokenizer

初版用 `Qwen2.5-0.5B` 做草稿，但它的 tokenizer 与 Llama 不同：

```
Llama-3.1 target ids: [791, 6864, 315, 9822, 374]
Qwen2.5 draft  ids:   [785, 6722, 315, 9625, 374]   ← 不一致
```

tokenizer 不匹配会显著压低接受率。换成 **`Llama-3.2-1B-Instruct-4bit`**（同 Llama-3 tokenizer，实测 5/5 prompt 编码完全一致）后：

| 草稿模型 | 加速比（逐轮配对 median） | 胜出轮次 |
|---|---:|---:|
| Qwen2.5-0.5B（异 tokenizer） | 1.49× | 6/6 |
| **Llama-3.2-1B（同 tokenizer）** | **1.86×** | **6/6** |

> **换同 tokenizer 草稿 = +25% 加速。**

## 16.4 关键改进二：n_draft 调参（一条反复反转的曲线）

n_draft 是**全项目最反复的一个参数**——四份报告给出三个不同最优值。以下按时间列出每次结论及其测试条件：

| 报告 | 结论 | 条件 |
|---|---|---|
| FINAL_TECHNICAL §3.4 | **nd=4 稳健最优** | 早期，草稿仍为 Qwen0.5B 时代附近 |
| SPEEDUP_DIRECTIONS | **nd=2 最优**（median 1.61 vs nd=4 的 1.40） | 同 tokenizer 草稿后 |
| OFFLOAD_VERDICT §4.3 | **nd=4 最优** | 主机高负载（load 8.85）下测 |
| **DECODE_PUSH（推翻上述）** | **nd=2 最优**，nd=4 是遗留错误值 | 两轮 campaign，宿主洁净门禁通过 |
| **REJECTION_SAMPLING** | **nd=3 最优** | 接受规则换成拒绝采样后 |

**DECODE_PUSH 的最终定论（已上线）**：

| n_draft | campaign 1 | campaign 2 | 胜出 | 接受率 | 判定 |
|---:|---:|---:|---:|---:|:--|
| **2** | **1.490** | **1.247** | **6/6, 5/6** | **0.590** | ✅ **最优** |
| 3 | — | 1.232 | 4/6 | 0.658 | ⚪ 次优 |
| 4 | 1.289 | 1.127 | 5/6, 5/6 | 0.704 | ❌ 现行值非最优 |
| 6 | 0.899 | — | 1/6 | 0.734 | ❌ |
| 8 | 0.796 | — | 1/6 | 0.769 | ❌ |

> **关键机制**：**接受率随 n_draft 单调上升（0.590 → 0.769），但提速比单调下降** ⇒ **草稿变长的边际收益抵不过每轮 1B 草稿前向的固定成本**。

**为什么网关的 nd=4 是错的**：该值是在草稿还是 **Qwen2.5-0.5B**（tokenizer 不匹配）时定的；2026-09-13 15:26 草稿换成同 tokenizer 的 Llama-3.2-1B，但 **n_draft 从未重扫**。

## 16.5 关键改进三：温度闸门的修正（一次产品级回归）

**问题**：投机解码在默认温度下是否更快？

早期实测（temp 扫描，paired、同进程、ndraft=4、160 token）：

| temp | 加速比 | 接受率 | tokens/iter |
|---:|---:|---:|---:|
| 0.0 | 1.126 | 0.583 | 3.33 |
| 0.3 | 1.181 | 0.576 | 3.30 |
| **0.7（网关默认）** | **0.904** | 0.435 | 2.74 |
| 1.0 | 0.941 | 0.358 | 2.43 |

**机制**（`mlx_lm` 源码 `generate.py:625`）：接受规则是**精确匹配** `if tn != dtn: break` ⇒ 接受率 ≈ Σp(x)q(x)，温度越高衰减越快。

**当时的处置**：加 `max_temp = 0.5` 闸门（`_spec_enabled_for` 返回 `temperature <= max_temp`）。

**⚠️ 但这个处置是过度保守的**——`max_temp=0.5` 把 temp>0.5 一整段全部关掉，**等于丢弃约 1.14× 的默认路径提速**。

**DECODE_PUSH 的修正**（两轮 campaign，temp=0.7，200 token，6 pairs/campaign）：

| n_draft | campaign 1 | campaign 2 | 胜出 | 接受率 |
|---:|---:|---:|---:|---:|
| **1** | 1.101 | 1.140 | 5/6, 6/6 | 0.405–0.410 |
| **2** | **1.140** | **1.155** | 4/6, **6/6** | 0.545–0.565 |
| 3 | — | 1.010 | 3/6 | 0.590 |
| 4 | 0.989 | 1.075 | 3/6, 4/6 | 0.643–0.653 |

> **此前 0.904× 是在 n_draft=4 下测的——是 n_draft 选错，不是温度本身的问题。**
>
> temp=0.7 下 **nd=1/2 两轮均 ≥1.10**，nd=2 在 campaign 2 是 **6/6 全胜**。

**处置**：把「on/off 闸门」换成**温度感知的 n_draft**。

## 16.6 关键改进四：拒绝采样接受规则（零精度代价的提速）

**这是最新、理论上最漂亮的一步。**

### 16.6.1 原理

`mlx_lm` 原生用的是**精确匹配**接受（`generate.py:624`）。改用 **Leviathan 标准拒绝采样**后：

- 两者 emit 的 token 都是 target 分布 p 的真样本，草稿只决定"一次能往前走多远" ⇒ **输出分布严格不变**
- 单 token 接受率：精确匹配 `Σ p(x)·q(x)` vs 拒绝采样 `Σ min(p,q)`
- 因 p,q ∈ [0,1] 恒有 `p·q ≤ min(p,q)` ⇒ **精确匹配永远接受得更少**

**实测**（`accept_rule_headroom.json`，120 个 teacher-forced 位置）：

| 规则 | 接受率中位 |
|---|---|
| exact-match | 0.724 |
| **拒绝采样（Leviathan）** | **0.872** |
| **差** | **+0.148** |

> ⚠️ **重要边界**：**temp=0 时 p 退化成 one-hot，两种规则等价**（greedy 一致位置上差距仅 +0.010，即噪声）。**收益全部在 temp>0**——正好是网关默认 0.7。

### 16.6.2 分布保真验证（600 trial）

| 规则 | max\|emp − p₀\| |
|---|---|
| baseline（纯采样噪声） | 0.0049 |
| exact | 0.0099 |
| **rejection** | **0.0101** |

> rejection 与 baseline **同量级** ⇒ **无偏**。

**⚠️ 过程中发现并修掉一个会静默致偏的坑**：exact 分支拒绝时**必须 emit 已抽到的 tn，不能重新抽**；重抽会让 `P(x) = p(x)(q(x)+1−A)`，实测把 `p=[.8618,.1382]` 偏成 `[.9094,.0906]`（偏差 **0.126**）——**这个偏差在只看"文本是否通顺"时完全看不出来**。

### 16.6.3 离线实测（temp=0.7，nd=3，200 token，配对 + 顺序翻转）

| campaign | exact | rejection | gain | 胜出 |
|---|---:|---:|---:|---:|
| c1（6 对） | 1.004 | **1.210** | +0.206 | 5/6 |
| c2（6 对） | 1.007 | **1.249** | +0.242 | 5/6 |
| c3（10 对，宿主干净） | 0.993 | **1.145** | +0.153 | **9/10** |

> **中位 1.004 → 1.210；19/22 胜出。**

其他 nd（c1/c2）：nd=2 → **1.181 / 1.192**；nd=4 → **1.101 / 1.118** ⇒ 在拒绝采样规则下 **nd=3 最优**。

**实现保真交叉校验**：自研 exact 臂复现 `mlx_lm` 原生数字（1.094 / 1.126 vs 原生 1.140 / 1.155 @nd=2）⇒ **重实现可信**。

### 16.6.4 网关侧（诚实说明：未能量到同等幅度）

| 场景 | 数值 |
|---|---|
| spec-off 基线 | 29.43 |
| exact nd=2（上次上线） | 37.78（**1.284×**） |
| rejection nd=3（本次） | 37.17（1.263×） |

表面看 rejection 没赢，但**两次跨会话、宿主状态不同，绝对 tok/s 不可比**。

**同会话配对 A/B**（翻转 accept_rule + 重启网关，逐对取比值）：

| pair | exact | rejection | ratio |
|---|---:|---:|---:|
| 0 | 38.24 | 36.84 | 0.963 |
| 1 | 22.19 | 31.27 | **1.409** |
| 2 | 19.43 | 23.22 | **1.195** |
| **中位** | | | **1.195（2/3 胜）** |

> **⚠️ 这个 A/B 判废**：exact 臂从 38.24→22.19→19.43 **单调衰减 0.51×**，rejection 臂也衰减 0.63× ⇒ 典型**热浸泡 + swap 8.6 GB**，不是配置效应；**顺序翻转无法消除单调衰减**（项目既有铁律）。
>
> **⇒ 网关侧结论未定，以离线三 campaign（19/22）为准。**

### 16.6.5 上限重估

| 状态 | 理论上限 |
|---|---|
| 改前（exact, α=0.80, c=0.39） | 1.36× |
| **改后（rejection）** | **≈1.5×** |
| 再压草稿成本 c=0.25 | ≈1.9× |
| 再 c=0.20 | ≈2.2× |

> **剩余最大杠杆仍是草稿成本 c，不是接受率 α。**

## 16.7 保真度：实测基本无损，但有一个必须说明的边界

### 16.7.1 逐 token 一致率（8 prompt × 128 token，greedy）

| prompt | 一致 / 总数 | 一致率 |
|---|---:|---:|
| The capital of France is | 128/128 | 100% ✅ |
| def fibonacci(n): | 128/128 | 100% ✅ |
| **水是生命之源，因为** | **44/128** | **34.4%** ❌ |
| Explain quantum computing... | 128/128 | 100% ✅ |
| 1, 2, 3, | 128/128 | 100% ✅ |
| Once upon a time | 128/128 | 100% ✅ |
| The best way to learn a language is | 128/128 | 100% ✅ |
| 在机器学习中，过拟合是指 | 128/128 | 100% ✅ |

> **总计 940/1024 = 91.80% 逐 token 一致；完全一致的 prompt 7/8。**

### 16.7.2 那一处分歧的根因（已定位）

中文 prompt 在 token 35 处分歧。该位置 logits：

```
106222 ('社会')  logit = 15.4375   ← baseline 选了这个
17161  ('文')    logit = 15.4219   ← spec 选了这个
21990  ('生')    logit = 15.3984

top1 与 top2 的差距 = 0.0156       ← 近似并列
```

> **在近似并列点，批量验证改变了浮点累加顺序，argmax 翻转。这是 greedy 采样在并列点的固有非确定性，不是实现 bug。**

后续 `DECODE_PUSH` 进一步**定性为 `H0_BENIGN_TIE_FLIP`**：分歧点 **top1-top2 gap 恒为 0.015625**（= 2⁻⁶，**恰好是 fp16 在该量级的量化步长**），且都在 token 130/198 处。

> **准确表述**：speculative 在数学上保持分布（拒绝采样保证），但在 fp16 数值下，约 8% 的 token 在 top-1/top-2 并列处会发生翻转。
>
> **可用性判断**：对生成质量无实质影响（都是近似并列的候选），但对**需要逐字节可复现**的场景（回归测试、确定性流水线）是需要注意的边界。

## 16.8 最终受控测量

6 轮同进程交替（baseline 与 spec 在同一轮内背靠背，**逐轮配对比值抵消热态**）：

| 轮 | baseline | spec | 比值 | 热态漂移 |
|---:|---:|---:|---:|---:|
| 0 | 12.96 | 20.00 | 1.54× | 0.067 |
| 1 | 9.64 | 13.55 | 1.41× | **0.512** |
| 2 | 6.43 | 15.77 | **2.45×** | 0.037 |
| 3 | 9.36 | 13.64 | 1.46× | 0.035 |
| 4 | 12.31 | 20.76 | 1.69× | 0.151 |
| 5 | 11.59 | 22.21 | 1.92× | 0.162 |

```
baseline median : 10.62 tok/s
spec     median : 17.88 tok/s
加速比 median   : 1.61×   range [1.41, 2.45]   胜出 6/6
```

> ⚠️ 注：本机（无风扇 M5 Air）热态漂移极大（本轮 drift 最高 **0.512**）。**必须用逐轮配对比值**——**若用跨轮中位数会得到 1.22×（错误）**。

## 16.9 证据强度分层（项目自己的评级）

| 数字 | 强度 | 依据 |
|---|---|---|
| **1.575×** | **最强** | 洁净主机配对 A/B + 顺序翻转，4/4 全胜 |
| 1.209× | 中 | 8 组配对（负载下） |
| 1.71×（网关） | 弱 | 非配对，仅佐证 |

> **引用应以 1.575× 为主；网关数字仅作旁证。**

---

# 17. 持续优化 —— 从离线实验到产品上线

## 17.1 调度与部署的硬约束（Proteus-1 遗产）

| 约束 | 数值 | 影响 |
|---|---|---|
| **Cold start** | 32 个 CoreML 模型加载 **13.8–15.4 s** | Hybrid 冷启动首 token 慢 3.8× |
| **dispatch 地板** | 每次 CoreML 调用 ~1.3 ms，×32 层 = **每 token ~42 ms** | decode 形状的致命伤 |
| **GPU↔ANE 同进程污染** | **2.75×** | 必须每配置独立进程 |
| **decode 噪声 floor** | **±17%** | 小于此幅度的加速不可声称 |

## 17.2 网关缺口：prefix cache 完全没接线

**这是项目后期发现的一个真实产品级缺陷。**

```python
# gm/backends/mlx_lm_backend.py:160
stream_generate(...)   # 不传 prompt_cache
```

```bash
$ grep -rn "prompt_cache\|kv_bits" gm/
# 零命中
```

> **后果：每一轮对话都把整个历史重新 prefill ⇒ 多轮对话总 prefill 工作量 O(N²)。**

**长上下文请求的真实构成**（冷态实测）：

| ctx | prefill 吞吐 | 48-token decode | prefill 占该请求 |
|---:|---:|---:|---:|
| 459 | 664 tok/s | 1.6 s | 30% |
| 1803 | 656 tok/s | 1.7 s | 61% |
| 3595 | 479 tok/s | 2.8 s | 73% |
| **7179** | **253 tok/s** | **3.8 s** | **88%** |

> **上下文越长，prefill 占比越大——到 7k 时已达 88%。** 而网关**完全没有**利用 prefix cache。

## 17.3 prefix cache 的收益与判定风波

**收益巨大**：

- nocache TTFT 中位 0.79 s vs cache **0.37 s**
- 第 5 轮 TTFT **1.54 s → 0.36 s（4.3×）**
- 总墙钟 12.58 s → 10.93 s；轮内 speedup **[1.085, 1.226]，中位 1.155×**

**⚠️ 但被脚本自己的 gate 判 INVALID**：5 轮里**第 4 轮 token 与 from-scratch 参考不一致**，脚本自判 `valid=False`。

**排查中**：单独诊断 **5/5 一致**、determinism 对照通过、`--turns 10` 跑出 **10/10 一致**、logprob 漂移 0.015–0.039 ⇒ **间歇性**不一致，非系统性逻辑错。

> **在判定之前，prefix cache 的数字一律不能算作成绩。**（这是项目诚实性的体现）

**关键工程细节（最易出 bug）**：必须用 **`cache[0].offset`（权威缓存长度）+ 真长公共前缀（LCP）** 来 trim，**不能用"假设追加式历史"的算术**——**差一位就会静默污染输出**。

## 17.4 KV cache 量化（质量可行、结构上救不了聊天）

**KV bytes/token** = 32 层 × 8 kv_heads × 128 head_dim × 2(K,V) × 2B = **128 KiB/token**

**结构预测**：

| ctx | KV 占比 | 预测加速 |
|---:|---:|---:|
| 1024 | 2.9% | 1.013× |
| 4096 | 10.6% | 1.056× |
| **8192（网关上限）** | **19.2%** | **1.095×** |
| 32768 | 48.7% | 1.320× |

**实测（greedy 配对、顺序翻转、含 ctx=1024 对照臂）**：

| ctx | KV 占比 | 结构预测 | 实测中位 | token 一致 | logprob 漂移 |
|---:|---:|---:|---|---:|---:|
| 928（对照） | 2.6% | 1.013× | **1.073× [1.048,1.698]** | **100.0%** | 0.0011 |
| 7200 | 17.3% | 1.095× | **0.685× [0.650,0.951]** | **100.0%** | 0.0010 |

> **速度结论不可用**：理论 ctx=928 应 ~26.6 tok/s、ctx=7200 应 ~22.6；实测 5.7 与 **1.3** ⇒ 长上下文臂慢 **17×**，且随测量单调恶化（pair0 1.28 → pair2 0.78）= **宿主换页**特征（测量期间 swap 13.4 GB/14.3 GB，系统负载均值 46–85）。
>
> **对照臂自己证明污染**：ctx=928 结构预测 1.013× 却测出 1.073× 中位、单对高达 **1.698×** ⇒ **噪声底 ~1.7×** ⇒ ctx=7200 的 0.685× 同样不可信。

**可用结论（仅质量侧）🟩**：**8-bit KV 量化近乎无损** —— 两上下文全部 6 对 token **100% 一致**，平均 logprob 漂移仅 **0.0010–0.0011**。

**结论**：短上下文基本无用（1.013×），长上下文才可能可观（≤1.10× @8k）⇒ **救不了默认聊天场景**。

> **交叉印证**：Swiftlet 的 `PLAN.md:195` 把 **"quantized KV cache" 明确列为 TurboFieldfare 的死路（Do not repeat）**——**两个独立项目在同一决策上结论一致**。

## 17.5 「长上下文 decode 崩塌」——自己的假设被自己证伪

**上一轮错误结论**：`ctx_sweep` 显示 ctx>2000 后 decode 掉出屋顶线（ctx=7179 仅 **0.556×**）。

**本轮定案**（冷态交替 A/B，每次测量前冷却 **150 s**、顺序翻转）：

| 上下文 | 测量值 | 中位 |
|---|---|---|
| short ctx=879 | 1.059 / 1.061 / 0.981 | **1.059** |
| long ctx=7011 | 1.065 / 0.983 / 0.957 | **0.983** |

> **long/short = 0.928 ⇒ 屋顶线律全上下文成立。** ctx=7011 冷态仍有 **~131 GB/s**。
>
> **所谓「崩塌」完全是按递增顺序测量导致的持续热浸泡**（长上下文排最后，测的是热透的机器）。

**方向是「关门」不是「开门」**：证伪了"长上下文有独立算法瓶颈"的希望，把提速空间**重新钉死在 bytes/token**。

## 17.6 已上线部署（2026-09-13 23:45–23:58）

### 17.6.1 改动一：n_draft 4 → 2

`General Model/models.json`：
```json
"num_draft_tokens": 2,                    // 4 → 2
"num_draft_tokens_high_temp": 2,          // 新增
"max_temp": 0.5                            // 语义改为"高温仍启用，只换短草稿"
```

`gm/backends/mlx_lm_backend.py`：
- 新增 `_spec_ndraft_for(opts)` —— 按温度路由草稿长度
- `_spec_enabled_for` 语义变更：**`max_temp <= 0` 才真正关闭高温**（保留旧行为开关）

备份：`models.json.bak.nd2.234501`、`mlx_lm_backend.py.bak.234501`

### 17.6.2 网关端到端验证（temp=0.7，真实 HTTP，15 请求）

| 指标 | spec OFF | spec ON (nd=2) | 倍数 |
|---|---:|---:|---:|
| decode tok/s | 29.43 | **37.78** | **1.284×** |
| total tok/s | 27.71 | 35.49 | 1.281× |
| TTFT | 0.378 s | 0.358 s | 1.06× |

> **默认温度路径首次吃到提速**——改前这里是 0×（spec 被闸门关掉）。绝对吞吐 **29.4 → 37.8 tok/s**。

**§8.3 口径诚实标注**：on/off 为**同会话前后对照，非配对**；绝对 tok/s 跨会话不可比；**离线配对实验才是因果证据**。

### 17.6.3 改动二：接受规则 → 拒绝采样（2026-09-14 凌晨）

新增 `gm/backends/spec_rejection.py`（拒绝采样 spec 循环）；`mlx_lm_backend.py` 新增 `accept_rule` 配置、按规则分流、**异常自动回落到原生路径**；`base.py` GenMeta.accept_rule 字段；`server.py` `/stats` 暴露 accept_rule。

`models.json`：`accept_rule: "rejection"`、`num_draft_tokens: 3`

**安全设计**：
- **异常回落**（rejection 路径抛任何异常即回落已验证的 `stream_generate`）
- **opt-in**（`accept_rule: "exact"` 回到原行为）
- **修复了 EOS 泄漏**（新路径原先把 `<|eot_id|>` 当文本吐出，现按 eos_ids 停止且不输出）

上线后 `last_meta` 确认：`"num_draft_tokens": 3, "accept_rule": "rejection"`

### 17.6.4 生产安全性

| 开关 | 效果 |
|---|---|
| `max_temp = 0` | 一键回到旧行为 |
| `num_draft_tokens_high_temp = 0` | 关闭温度区分 |
| `accept_rule: "exact"` | 回到原生接受规则 |

**草稿模型（Llama-3.2-1B）与 target（8B）均未变。**

---

# 18. 最终成果

## 18.1 产品级成果

| 指标 | 基线 | 最终方案 | 变化 |
|---|---|---|---|
| **decode 速度（网关默认 temp=0.7）** | 29.43 tok/s | **37.78 tok/s** | **1.284×** |
| decode 速度（离线严格配对，temp=0.7） | 1.004× | **1.210×** | 三 campaign **19/22** 对胜出 |
| decode 速度（离线配对，greedy） | — | **1.247–1.490×** | 两 campaign |
| 逐 token 一致率 | — | **91.80%**（7/8 prompt 完全一致） | 近似无损 |
| **输出分布** | — | **严格不变**（拒绝采样保证） | **理论无损** |
| KV 量化质量 | — | **token 100% 一致**，logprob 漂移 0.001 | 近无损 |
| 权重保真度 | group_q4 原生 | **完全不变** | **零改动** |
| 额外内存 | — | +1B 草稿模型（4-bit ≈ **0.7 GB**） | — |

## 18.2 最终方案定义

```
目标模型 : Llama-3.1-8B-Instruct-4bit (MLX group_q4)
草稿模型 : Llama-3.2-1B-Instruct-4bit  (同 tokenizer，实测 5/5 编码一致)
n_draft  : 2（低温/贪心） / 3（拒绝采样规则下）/ 温度感知路由
接受规则 : 拒绝采样（Leviathan），可 opt-in 回退 exact
执行设备 : GPU（MLX）
配置     : mlx_lm 原生 speculative + 自研 spec_rejection.py
部署     : gm 网关（Python stdlib HTTP + 进程内 mlx_lm）
```

## 18.3 相对其他方案的最终对比

| 方案 | 相对 GPU 基线 | 保真度 | 部署 |
|---|---:|---|---|
| **GPU + speculative（最终方案）** | **1.284×（网关）/ 1.21×（离线）** | **严格不变分布** | ✅ **已上线** |
| GPU group_q4（原基线） | 1.00× | 原生 | ✅ 已生产 |
| ANE 融合（补零逃逸） | 0.25–0.31× | 补零 maxdiff=0 但未过完整门禁 | ❌ |
| ANE 原方案 | 0.08–0.22× | 3.6× 内存 | ❌ |
| ANE 权重卸载 | **零和**（ane/dram = 0.906） | — | ❌ 结构性否决 |
| 3-bit 量化 | 理论 ~1.3× | **rel_rmse 0.22** | ❌ |
| 4-bit→2-bit | 理论 ~2× | **rel_rmse 0.41** | ❌ |
| KV cache 量化 | 1.013×（ctx1024） | 近无损 | ❌ 结构上救不了聊天 |

## 18.4 剩余未决/未做项（诚实清单）

| 项 | 状态 |
|---|---|
| **prefix cache 判定** | ⚠️ **判定中**——期望收益最大的一项（直击 88% 的 prefill 大头） |
| 网关侧 rejection 配对 A/B | ⚠️ 需在宿主空闲（swap<1GB、load<5）重做 |
| 更激进草稿量化（压 c） | 未做——**剩余最大杠杆** |
| 动态 n_draft | 未做 |
| 逐字节可复现的 tie-breaking | 未做（8% 翻转边界） |
| int4 draft 崩溃（Swiftlet 血统提示） | **未独立验证** |
| 能量/功耗测量 | ❌ **全项目无任何数据**（`powermetrics` 需 sudo） |
| ANE 能效维度 | ⚠️ 引自 ANEForge 数据，**本机不可复现** |
| prefill 并发分工（按 N 维切分） | 未测——理论可分得 ~1.6×，但端到端收益仅 ~4–6% |
| P1 遗留实验：32 层 E2E + fused FFN + 忠实 group64 | ❌ **至今未跑** |

## 18.5 三条「唯一合法的出路」（项目最终认知）

decode 已顶 DRAM 屋顶线（冷态 118–133 GB/s，占理论 0.96–1.08），**单机单次 decode 里任何第二引擎都只能重排同一批字节，不能减少字节**。

⇒ 只剩三条：

1. **减少每 token 要搬的字节**（权重/KV 量化）—— **已近极限**
2. **让一次前向产出多个 token**（投机解码）—— ✅ **当前唯一产品上生效的杠杆**
3. **不要重复搬运已搬过的字节**（prefix cache）—— ⚠️ **判定中**

---

# 19. 最早期的探索 —— ANEProbe 阶段（P2 → P6）

> **时间上这一章最早，但放在这里是因为它是"ANE 有希望"这一信念的来源，也是后来所有推翻的对象。** 这些报告在 ANEProbe 的 `Results/` 与各 `P*` 目录下，是项目的史前史。

## 19.1 阶段脉络

```
P2   单 Linear 上发现 ANE crossover（S≥320 ANE 反超）  ← 信念的起点
P3B  复合 FFN 上 crossover 缩水成窄带（S≈256–448）    ← 第一次打折
P4A  运行时多模型编排下 ANE 完全失去优势               ← 第二次打折
P4D  量化 Attention 上的表现                            ← 范围扩展
P5A  单层 INT4 block + KV cache                        ← 引入 KV
P5B  多层（4/8/16）runtime scaling                     ← 首次出现"深层 ANE 有利"
P6   可配置 placement map → 冻结策略                   ← 形成 Proteus-1 的 map
```

## 19.2 P2 —— 单 Linear 的 ANE crossover（信念的起点）

在**单个** FP16 Linear/GEMM 上确认：**ANE 在 S≥320 反超 GPU**。

| 形状 | crossover | ANE/GPU @320–1024 |
|---|---|---|
| 4096→11008 | S=320 | **0.65–0.92（全程 ANE 胜）** |
| 4096→14336 | S=320 | 0.75–0.86 |
| 4096→16384 | S=320 | 0.74–0.91 |

S=1024 峰值 ~**6.2 TFLOPS**。

> **这是整个 ANE 路线的第一块基石**：一个干净的、可复现的 crossover。

## 19.3 P3B —— 复合 FFN 上优势缩水成窄带（第一次打折）

**问题**：单 Linear 的 GEMM crossover 能否在真实 LLM 的 **SwiGLU FFN** 复合算子中复现？

**答案：不能完全保留。**

| S | fused GPU | fused ANE | **ANE/GPU** |
|---:|---:|---:|---:|
| 1 | 3.40 | 5.80 | **1.71** |
| 64 | 7.81 | 5.44 | 0.70 |
| 256 | 23.98 | 20.98 | **0.87** |
| **320** | 30.22 | 24.56 | **0.81** ← 最优 |
| 384 | 29.81 | 28.64 | 0.96 |
| **448** | 36.08 | 32.54 | **0.90** |
| 512 | 37.50 | 36.40 | 0.97 |
| 768 | 55.43 | 53.58 | 0.97 |
| 1024 | 72.93 | 71.57 | 0.98 |

**分带聚合（mean ANE/GPU，fused）**：
- S=1 → **2.69**（ANE 慢 2.7×，decode 固定开销）
- S=64–128 → **8.49**（小批量 ANE 差）
- **S=256–384 → 0.93（ANE 胜，crossover 带）**
- S=448–512 → 1.00（中性/切点）
- S=768–1024 → **1.26（GPU 胜，大 S 反转）**

> **一句话**：P2 的「S≥320 全程 ANE」在 FFN 上**不再成立**；真实 crossover 是**区间 [约 S=256, 约 S=448]**，**两端都是 GPU**。

**损耗归因（P2 → P3B 直接对照）**：

| S | P2 单 Linear | P3B FFN fused | Δ |
|---:|---:|---:|---:|
| 320 | 0.65 | 0.81 | **+0.16** |
| 384 | 0.84 | 0.96 | +0.12 |
| 448 | 0.73 | 0.90 | +0.17 |
| 512 | 0.83 | 0.97 | +0.14 |
| 768 | 0.92 | 0.97 | +0.05 |
| 1024 | 0.84 | 0.98 | +0.14 |

> **所有测点 FFN 的 ANE/GPU 均劣于 P2 单 Linear 0.05–0.17。**
>
> **关键**：elementwise + mul + scheduling **吃掉了 ANE GEMM 优势的约 70–100%**（大 S 甚至净亏损）。

**修正后的 runtime policy（窄带 ANE）**：

```
FFN (hidden=4096, intermediate≥11008):
    S ∈ [≈320, ≈448]  → 用 ANE  (fused ratio 0.81–0.90)
    S 其他             → 用 GPU
    S ≤ 128 (decode)   → 一律 GPU（ANE 固定开销慢 1.7–3×）
    深 prefill S≥512    → GPU（ANE 已无优势甚至慢）
```

**⚠️ S=128 异常**：fused ANE 出现 **85–131 ms**（vs S=64≈5–16 ms、S=256≈21–29 ms），3 轮内 std 低（非单轮抖动）→ **判定为非热漂移的 ANE scheduling 异常点**。**这就是后来 R3 黑名单的最早发现。**

**⚠️ 工程限制（本阶段真实发现）**：CoreML 在 M5 上对**独立**的 `silu(gate)*up` 元素模型在 `.cpuOnly` 后端会 **SIGSEGV**（大张量尺寸下稳定复现；fused 图中相同 silu+mul 却安然无恙）。

## 19.4 P4A（FFNProbe）—— 运行时编排下 ANE 完全失去优势（第二次打折）

**方法差异**：不是单图 fused，而是像真实 LLM runtime 一样，用**已有的独立 FP16 CoreML Linear 模型**逐步组合 FFN——**4 次独立 CoreML prediction / FFN call**。

| S | GPU_ONLY | ANE_ONLY | HYBRID | H/G |
|---:|---:|---:|---:|---:|
| 1 | 4.55 | 4.10 | 4.17 | 0.92 |
| 8 | 3.61 | 4.23 | 3.61 | 1.00 |
| 32 | 3.75 | 4.35 | 3.99 | 1.07 |
| 128 | 5.47 | 15.60 | 5.73 | 1.05 |
| 256 | 7.52 | 21.67 | 7.60 | 1.01 |
| **320** | **11.74** | 25.94 | 16.71 | **1.42** |
| **512** | **14.64** | 39.05 | 23.52 | **1.61** |
| **1024** | **28.07** | 74.33 | 46.86 | **1.67** |

> **每个 S 的最快模式都是 GPU_ONLY。**
>
> **ANE_ONLY 在 S≥256 全面落后**（S=1024 是 GPU 的 **2.65×**）。
> **HYBRID 反而比纯 GPU 慢** 1.42–1.67×。

**根因**：每次 ANE CoreML invocation 有 **~4–5 ms 固定 dispatch/sync 开销**，4 次调用无法像 fused 图只付一次；ANE→GPU 张量搬运 + 同步额外昂贵；elementwise 在 ANE 上也不免费。

> **结论**：单个 Linear 的 ANE GEMM 优势**在真实「分表多模型 runtime 组合」下被多次 invocation + 跨设备搬运完全抵消**。若要享受 ANE，**必须把 FFN 合成单个 fused CoreML 图**。

## 19.5 P5A —— 单层 INT4 block + KV cache

**配置**：hidden=4096、heads=32、head_dim=128、intermediate=11008、**single layer**、INT4 权重/FP16 激活、**cache slots=1024（固定分配）**。

| S | GPU(FP16) | GPU(INT4) | HYB4GPU | HYB4 | ANE(INT4) |
|---:|---:|---:|---:|---:|---:|
| 1 | 5.0047 | 1.5029 | 2.0721 | 2.0447 | 23.9362 |
| 32 | 5.0703 | 2.0122 | 2.1924 | 2.1822 | 24.0391 |
| 64 | 5.3568 | 3.3224 | **2.6590** | 2.6983 | 24.7521 |
| 128 | 9.2745 | 15.1397 | 75.0274 | 90.0095 | 26.6199 |
| 256 | 28.1067 | 30.8640 | **18.4855** | 31.1857 | 32.1184 |
| 512 | 61.8891 | 57.3653 | **35.8060** | 38.8336 | 41.5238 |
| 1024 | 115.9825 | 115.1646 | 78.3854 | **56.7435** | 58.4564 |

**Decode（median ms/token）**：

| ctx | FP16-GPU | GPU(INT4) | HYB4GPU | HYB4 | ANE(INT4) |
|---:|---:|---:|---:|---:|---:|
| 32 | 5.8222 | **2.6149** | 7.6600 | 3.6310 | 5.1776 |
| 64 | 5.8161 | **2.4893** | 6.4352 | 8.6570 | 4.0770 |
| 128 | 6.4339 | **2.7043** | 4.1636 | 4.0895 | 4.8945 |
| 256 | 6.6140 | **2.8244** | 3.0490 | 4.2177 | 3.8465 |
| 512 | 6.9998 | 3.6711 | **3.5217** | 5.2219 | 5.1078 |
| 1024 | 6.3848 | 3.9046 | **3.2602** | 6.3732 | 4.7915 |

**关键结论**：
- **仅量化本身就在处处击败 FP16-GPU**（所有 decode ctx + 大 prefill）。
- **但 decode 的胜利不是 ANE 芯片带来的**：**INT4-GPU 在每个 decode ctx 都击败 INT4-ANE**（如 ctx=512：GPU 3.67 vs ANE 5.11 ms）。
- INT4-ANE 只在 S≥512 prefill 赢。
- **固定 1024 KV-cache 图把 ANE 的小批量优势侵蚀到远低于 P4E。**

> **结论**：P5B 应把 KV-cache decode 留在 **GPU-INT4**（ctx≥512 用 HYBRID4GPU），**ANE 只用于大 prefill**。

## 19.6 P5A FusedFFN —— H2 成立：融合也救不回 ANE

**问题**：把完整 SwiGLU FFN 融合成**单个 CoreML graph** 后，能否恢复 ANE 的 GEMM 优势？

**答案（全 30 节点 = 10 S × 3 模式）：不能。**

| S | GPU_ONLY | ANE_ONLY | ALL | **ANE/GPU** |
|---:|---:|---:|---:|---:|
| 1 | 3.39 | 3.87 | 3.05 | **1.14** |
| 8 | 3.09 | 3.87 | 3.08 | 1.25 |
| 32 | 3.17 | 3.88 | 3.88 | 1.22 |
| **128** | 4.58 | **36.51** | 4.71 | **7.97** ⚠️ |
| 256 | 6.07 | 20.39 | 20.39 | 3.36 |
| 320 | 9.89 | 24.49 | 24.50 | 2.48 |
| 384 | 10.09 | 28.61 | 28.61 | 2.84 |
| 448 | 12.39 | 32.75 | 32.74 | 2.64 |
| 512 | 12.79 | 36.87 | 36.84 | 2.88 |
| 1024 | 25.68 | 70.08 | 70.07 | 2.73 |

> **每个 S 的最快模式都是 GPU_ONLY。** 全 10 个 S 的 ANE/GPU 均 >1（最小 1.14，S≥256 稳定 2.5–3.4×）。

**⚠️ S=128 ANE 调度异常**：ANE_ONLY 在 S=128 达 **36.5 ms**（比 S=256 的 20.4 ms 还高；重复 3 次均 ~36.3–36.7 ms，**可复现非漂移**），ANE/GPU 高达 **7.97×**。同时 `.all` 在 S=128 **选择 GPU**（4.71 ms）而非 ANE——**CoreML 的 `.all` 调度器在 S=128 也规避这个病态 ANE dispatch**。

**四条结论**：
1. **整图 fusion 不能恢复 ANE 优势（H2 成立）。**
2. **P4A 的 runtime overhead 不是唯一凶手**——移除多次 invocation 与跨设备搬运后 ANE 仍不占优。
3. `bias=True` + 融合 vs P3B `bias=False`：P3B 在 S=320–448 还有近乎持平窄带，**本阶段连窄带也不出现**（S=320 ANE/GPU=2.48）⇒ **在真实 LLM 常见 FFN（带偏置）下 ANE 劣势更稳定**。
4. **M5 ANE 对 FFN 层不适合作为主要计算后端。**

## 19.7 P5B —— 多层 runtime scaling（首次出现"深层 ANE 有利"）

**结构**：P5A 单层 INT4 Llama block 重复堆叠，L∈{4,8,16}；INT4 权重/FP16 激活；fixed-1024-slot KV cache。宿主线程把 residual chain 穿过同一个已编译单块模型 → 测的是 **runtime** scaling。

**Decode median ms/token（ctx=512）**：

| L | INT4-GPU | HYB4GPU | HYB4 | winner |
|---:|---:|---:|---:|:--|
| 1 | 3.6711 | 3.5217 | 5.2219 | HYB4GPU |
| 4 | 31.5033 | 30.1599 | **19.2163** | HYB4 |
| 8 | **87.4463** | 137.8800 | 295.9563 | INT4-GPU |
| 16 | 123.3604 | 130.9132 | **112.7064** | HYB4 |

**Prefill median ms（S=512）**：

| L | INT4-GPU | HYB4GPU | HYB4 | winner |
|---:|---:|---:|---:|:--|
| 4 | 194.7746 | **123.2781** | 152.1586 | HYB4GPU |
| 8 | 392.8129 | **221.3672** | 299.1835 | HYB4GPU |
| 16 | 1051.4036 | 602.7982 | **600.0532** | HYB4 |

**Q1：ANE-FFN 优势是否跨层累积？**
decode gap（HYB4GPU − A）/ A 平均 = L=4 **+0.1577**、L=8 **+0.1259**、L=16 **−0.0268（由正转负=变快）**。

> **答案：是，16 层时翻成真赢。** 原因：FFN 计算量 ∝L，×L 后能覆盖固定 2-call 拆分成本。

**Q3：KV 是否成主导瓶颈？**
KV 增长严格线性于层数，L=16 @ctx=1024 = **268.4 MB**。M5 的 **E5/IOSurface 分配器在 L=16 → ctx≳512 decode 触及硬天花板**（持续 `Failed to allocate E5 buffer / IOSurface`）。

> **1024ctx×16层下 CPU/GPU 全块 decode 完全无法测量**（device_limited），而 **ANE-FFN runtimes 存活且稳定**（B=113.5、C=72.1 ms/tok）→ **FFN 卸载到 ANE 恰好缓解压垮 GPU 路径的 IOSurface 压力**。

**Q6 进 P6 的判定**：
- **MECHANISM: GO**
- **RUNTIME: CONDITIONAL GO — 但非 ANE 中心设计**

两硬约束：①保真度——hybrid vs GPU logits 随层数发散（L=16 rmse ~0.026、max ~0.15）；②硬件天花板——L=16×1024ctx decode 的 A 路径在 M5 E5/IOSurface 上不可测。

## 19.8 P6 —— 可配置 placement map（Proteus-1 的 map 来源）

**方法**：每层独立选 Attention 设备（GPU|ANE）与 FFN 设备（GPU|ANE），或整块一次融合调用。

**单最优放置（部分）**：

| phase | L | S/ctx | winner | latency ms |
|---|---:|---:|---|---:|
| prefill | 4 | 32 | GPU-ONLY | 13.6800 |
| prefill | 4 | 128 | FUSED-GPU | 29.6738 |
| prefill | 4 | 512 | **PARTIAL-RISING-75** | 104.7275 |
| prefill | 16 | 512 | **PARTIAL-RISING-75** | 408.6355 |
| decode | **全部** | 全部 | **FUSED-GPU** | 15.6 / 31.0 / 61.7 |

**Q1 如何分配（最终答案）**：
- **Decode：FUSED-GPU 在每个 (L,ctx) 都是 latency winner**；**FUSED-ANE 与 FUSED-GPU 同在 energy Pareto 前沿**（**mJ/token 少约 40–45%、latency 多约 10%**）
- **Prefill 小 S**：GPU 赢
- **Prefill 中 S（128）**：FUSED-GPU 赢
- **Prefill 大 S（512）**：**ALL-FFN-ANE 或 PARTIAL-RISING**（末 k 层 FFN→ANE）赢

> **非均匀部分 ANE 尾可测地优于均匀**（L=4 S=512：PARTIAL-RISING-75 **104.7** vs 最优均匀 ALL-FFN-ANE 106.0 ms）→ **大 prefill 存在真实 layer-vs-layer 分化**。

**Q2 Layer×Context×Phase crossover**：
- (a) GPU-split vs fused-GPU 随 S 交叉
- (b) **GPU vs ANE-FFN 随 S 交叉**：小 S 时 ANE prefill 病态（pad-to-1024 惩罚，per-operator ANE attention 在 S=32 约 **24 ms**）；S=512 时 ANE-FFN 赢
- (c) **prefill 在 S=128→512 之间从 GPU 跨到 ANE-FFN；decode 的 latency 无 crossover**（FUSED-GPU 主导），但存在**纯能耗的 crossover 到 FUSED-ANE**

> 📌 **这个"能耗 crossover"值得注意**——它是整个项目里 ANE 唯一未被否定的价值维度（后来在 §20.4 被 ANEForge 数据独立确认）。

**Phase-2 建议**：**锁定硬件放置 map**；decode=FUSED-GPU（能耗则 FUSED-ANE）、prefill 小/中=GPU、prefill 大 S=ALL-FFN-ANE + PARTIAL-RISING 尾；**之后**才引入真实 Llama 权重。

## 19.9 P6.3 —— GPU-only vs Proteus-1 as-executed（诚实性的典范）

**这一阶段没有测出任何加速，但它的处理方式是全项目诚实性的标杆。**

**关键事实**：真实 Llama runtime（P6.2）**纯 MLX**，而 **MLX 只暴露 CPU 与 GPU，没有 ANE 设备**。

⇒ **Baseline A（GPU-only）= FUSED-GPU MLX 全 32 层在 GPU**；**Baseline B（Proteus-1 as-executed）= 同一条 MLX FUSED-GPU 路径**，因为 P6.1 的 ANE-hybrid 放置是 CoreML 特性、**无法**在该 MLX runtime 表达。

> **所以 as-run 的比较测的是同一代码路径 → speedup = 1.0×。这是真实诚实结果、非伪造。**

**实测数字（仍然有价值）**：

| 项目 | 结果 |
|---|---|
| **Prefill 峰值** | **133,134 tok/s @S=256**（热稳态，forward-only） |
| Prefill @S=1024 | 54,108 tok/s |
| **Decode** | **24.6 tok/s @ctx32 → 13.3 tok/s @ctx1024** |
| E2E（冷实例） | 1.3–11.5 gen tok/s（权重加载主导） |

**终判原文**：
> 选「No meaningful improvement」**仅因** ANE-hybrid Proteus-1 放置在 MLX runtime 不可执行——这是**工具/runtime 能力**缺口，**不是** Proteus-1 策略慢的证据，也明确**不是**宣称 ANE 在真实 Llama 上无价值。

**勾选项**：Significant / Moderate / Marginal **均否**；Regression 否。**未伪造任何 ANE 配置。**

---

# 20. 引入 ANEForge 与 Swiftlet

> 在 Proteus-2.4 判决 ANE 路线"死亡"之后，**两个外部项目改变了结论的适用范围**。这一章记录这两个项目带来了什么。

## 20.1 ANEForge —— 绕开 CoreML 的 ANE 直连通道

### 20.1.1 它解决了什么问题

Apple 只通过 CoreML 暴露神经引擎，**只支持推理**，而且 CoreML 自行决定模型落在引擎上还是静默回落到 CPU/GPU。

**ANEForge 跳过它**：把一个张量图编译成**单个 ANE program**，通过 CoreML、MPSGraph、Espresso 内部使用的**同一套私有 `aned` 栈**派发。

### 20.1.2 能力

| 能力 | 说明 |
|---|---|
| **在引擎上训练** | forward + backward + Adam 全部编译为 ANE program |
| **CoreML 到不了的硬件层** | `af.sdpa` 直接驱动引擎的 fused-attention 层 |
| **绝不回落** | 预训练 ResNet-18 端到端 0.33 ms，cosine 1.0000 |
| **MLPerf on ANE** | 参考 ResNet-50 纯 ANE 通过 MLCommons `submission_checker`（v5.1，三个 edge 场景全 VALID） |
| **LLM on ANE** | Llama/Qwen 的 prefill 与 KV-cache decode、精确投机解码、GGUF MoE、Qwen3.5-27B 混合架构 |
| **跨芯片编译** | 从一台机器为 28 个 ANE target（M1–M5）lower 并 gate 一个图 |

**规模**：58 个 fused 算子 + 19 个 native bridge 算子，dispatch floor **~70 μs**。

> **状态**：研究项目，依赖私有 framework 符号，可能随时变化。**与 Apple 无关联。**

### 20.1.3 ★ 它推翻了 Proteus-2.4 的核心前提

**这是项目最重要的一次转折。**

**分歧发现**：ANEForge 自带的 `bench/gemv_bandwidth_sweep.py` docstring 问「ANE 有效带宽是否在 ~112 GB/s 附近平台化？」其**实测**：

| K=N | MB | **GB/s** |
|---:|---:|---:|
| 512 | 0.52 | 6.1 |
| 1024 | 2.10 | 28.9 |
| 2048 | 8.39 | 75.6 |
| **4096** | **33.55** | **113.5** |
| 6144 | 75.50 | 129.8 |
| 8192 | 134.22 | **142.6** |

```
verdict: ane_bw_max_GBps = 142.6, tail_median = 121.7, paper_claim = 112
```

**而 Proteus-2.4 用同一 4096×4096、33.55 MB 矩阵测到 1.659 ms = 20.2 GB/s ⇒ 差 5.6×。**

**排查两假设**：
- H1 口径（他们 min 我 median）→ K=4096 min 21.2 / median 19.1，**差 <12%，不解释 5.6×**
- H2 布局（linear ty=true vs ty=false）→ 21.2 vs 20.9 GB/s，**几乎相同不解释**
- **H3 尺寸本身 → 找到：非单调**

**复现完整曲线**（ANEForge 精确方法：min over 30 reps，warmup 8）：

| K | **GB/s** |
|---:|---:|
| 512 | 7.9 |
| 1024 | 22.9 |
| 2048 | 40.8 |
| 3072 | 53.5 |
| **4096** | **20.2 ← 塌陷** |
| 5120 | 62.6 |
| 6144 | 66.0 |
| 7168 | **68.3 ← 峰值** |
| **8192** | **20.9 ← 又塌陷** |

**精确定位**（固定 N=2048 只扫 K）：

| K | GB/s |
|---:|---:|
| 3840 | 51.7 |
| 3968 | 51.1 |
| 4032 | 50.7 |
| 4064 | 33.2 |
| **4080** | **23.0** |
| **4096** | **20.6** |
| **4112** | **22.8** |
| 4128 | 32.5 |
| 4160 | 52.5 |
| 4352 | 52.0 |

> **悬崖 = K ∈ [4080, 4112]，两侧 4064/4128 是过渡带，约 33 宽**；**窄槽而非平台 ⇒ 编译器对齐/路由边界，不是内存带宽墙**。

### 20.1.4 为什么 Proteus-2.4 没发现

权重尺寸扫描用了 `4096→14336`、`14336→4096`、`4096→4096` 三个形状——**三个全都含 K=4096**。

> "权重字节线性增长、时间线性增长"看起来像干净的带宽平台，**实际是在悬崖里平移**。

**实验设计教训**：**形状覆盖必须对维度本身做正交扫描，而不只是扫尺寸。**

### 20.1.5 可立即使用的手段（补零逃逸，第一版）

真实 `gate_proj [14336,4096]`：

| 方案 | 时间 | GB/s | 加速 |
|---|---:|---:|---:|
| K=4096 基线 | 5.2698 ms | 22.3 | 1.00× |
| **K=4160 补零** | **1.7443 ms** | **68.4** | **3.02×** |
| K=4224 补零 | 1.7454 ms | 69.4 | 3.02× |

> 代价 = 64 列零权重 **+1.6% 字节**，收益 **3.02×**。

**⚠️ 当时标注的未验证项**：数学上补零不改变结果，**但 fp16 累加顺序可能引入微小数值差异 —— 尚未验证**。（后来 BYTESIZE_LAW 用 maxdiff=0 补上了这一验证。）

### 20.1.6 仍需解释的差距

| 来源 | GB/s |
|---|---|
| ANEForge 报告（M-series） | **113–142** |
| ANEForge paper claim | 112 |
| **本机实测峰值** | **68.3** |

> **仍差 1.7–2.1× 未解释。** 候选：机型（M5 base 无风扇）、热态、或他们的 `eff_bytes` 口径含 I/O（`(K*N+K+N)*2`）。

### 20.1.7 对既有结论的影响表

| 结论 | 状态 |
|---|---|
| P2.4 Outcome C | ⚠️ **前提已被推翻，判决需重估**（0/17 对比是在悬崖维度上做的） |
| P2.4「ANE 权重流 ~20 GB/s」 | ❌ **错误**（本机实际峰值 ≥68 GB/s） |
| P2.4 Experiment C 分解记账 | ⚠️ 需重测（per-block GEMM 的 K=64，但外层维度含 4096） |
| P2.3「S=512 慢 3–7×」 | ⚠️ 需重测 |
| Proteus-2.2 FFN 86.5% | ✅ 不受影响 |
| Proteus-2.2 热态方法论 | ✅ 不受影响 |
| Finding 5（decode 下限 = 字节/带宽） | ✅ 逻辑不变但"带宽"数值要重估 |

### 20.1.8 ANEForge 可直接并入的模块（9 项）

| 模块 | 价值 |
|---|---|
| `gemv_bandwidth_sweep.py` | **本次分歧来源，应替换 P2.4 的 weight_bandwidth.py** |
| `device_bandwidth_roofline.py` | 含功耗 |
| `device_compare*.py` | 三设备 ANE/GPU/CPU 同形状 + 功耗 |
| `compress_speedup_bench.py` | 对应 Proteus-3 |
| **`aneforge/speculative.py`** | **ANE 上投机解码实测 2.28×**（Qwen3-8B + 0.6B draft，7.4→16.8 tok/s）；关键洞察：**ANE 上 verify(K) ≈ verify(1)**（K=5 时 ~1.05×），因 decode 是 latency/dispatch-bound |
| `aneforge/llm.py` | LlamaPrefill 完整 prefill/decode on ANE 含 KV-cache |
| `_op_catalog.py` | 28 个 ANE target 逐 op 能力表 |
| `_cost.py` / `ane_cost_model.json` | 成本模型 |

> **最该立刻纳入三个**：`gemv_bandwidth_sweep`、`speculative.py`、`compress_speedup_bench`。

## 20.2 Swiftlet —— 一个反面的参照系

### 20.2.1 它是什么

**Swiftlet 是一个 Swift + Metal runtime**，面向 Qwen3-Next 与 Qwen3.5/3.6 **MoE 混合模型族**。核心思路：**只把模型的稠密核心常驻内存，按需从存储流式加载被路由的 MoE 专家权重。**

### 20.2.2 实测数据

| 模型 | 磁盘 | 峰值 RAM | Decode（M5 Mac） |
|---|---|---|---|
| Qwen3.6-35B-A3B, 4-bit | 18 GB | **2.6 GB** | **7–11 tok/s** |
| Qwen3.6-35B-A3B, 8-bit | 34 GB | 7.6 GB | 3.5–4 tok/s |
| Qwen3-Next-80B-A3B, 4-bit | 42 GB | **4.3 GB** | 4.5–5 tok/s |

**其他硬件**：

| 硬件 | 表现 |
|---|---|
| **M4 Max（40 核 GPU, 64 GB）** | 4-bit 35B 约 **19.5 tok/s** |
| **M1（8 核 GPU, 16 GB）** | 4-bit 35B 约 **2.45 tok/s**；8-bit 约 1.74 tok/s |
| **iPhone 17** | 35B 约 2.5 GB RAM，约 **1 tok/s** |

**最说明问题的配置**：8-bit 80B 的 **78.8 GiB 权重在 64 GB 机器上根本装不下**，但 Swiftlet 用 **6.9 GiB** 就能服务，约 4.8 tok/s。4-bit 397B（**207.6 GiB**）在 **12.6 GiB** 内运行，约 1.4 tok/s。

> **Decode 速度跟随活跃参数量（35B/80B 都约 3B，397B 约 17B），远大于跟随容器大小。**

### 20.2.3 设计要点

- 稠密权重常驻：attention、DeltaNet 投影、router、共享专家、embedding —— 4-bit 下约 1.3 GB（35B）/ 2.5 GB（80B）
- 把数万个被路由专家 repack 成固定步长的 blob，装进 `.qpack` 容器 ⇒ **取一个专家 = 恰好一次 `pread`**，不用 mmap、不 thrash page cache
- 有界池 + **LFU + recency** 淘汰缓存
- 整个前向用 Metal **运行时编译 shader**
- **75% 的层用 Gated DeltaNet 线性注意力**，有固定大小的循环状态 ⇒ **这些层在任何上下文长度都没有增长的 KV cache**

### 20.2.4 ★ 关键硬事实：Swiftlet 完全不碰 ANE

> **已核实：`Sources/` 下 CoreML / Espresso / e5rt / AppleNeuralEngine 引用数 = 0 ⇒ 纯 GPU/Metal。**
>
> 规模：**8911 LOC Swift**（Apache 2.0）。

### 20.2.5 为什么它的技巧不能迁移到我们的问题

| 维度 | Swiftlet | 我们的问题 |
|---|---|---|
| 目标模型 | Qwen MoE 混合架构 | **稠密** Llama-3.1-8B |
| 权重复用前提 | **每 token 只激活 top-k 专家 ⇒ 只读那一小部分权重** | **稠密模型每 token 必须读全部权重，无可跳过部分** |

> **MoE 流式的前提是稀疏激活；稠密模型没有这个前提。⇒ Swiftlet 的专家流式技巧不可迁移。**

### 20.2.6 它真正的贡献：提出了正确的问题

> Swiftlet 的**真实贡献 = 提出了正确的问题**（无风扇、持续、端侧才是要优化的工况）。

**可借条目**：①测量纪律；②功耗包络混淆的量化（39%）；③别做 KV 量化的判断；④"passive-wait CPU 线程"工程手法。

### 20.2.7 ★ 跨项目交叉印证（最有价值的部分）

Swiftlet 的 `PLAN.md` / `THIRD_PARTY_NOTICES.md` 转述其血统项目的实测，与我们的独立测量**高度一致**：

| # | Swiftlet 血统的说法 | 我们的独立测量 | 一致性 |
|---|---|---|---|
| ① | colibri：*"a spinning CPU throttles the GPU **39%** via the shared power envelope"*（`PLAN.md:180`） | 纯宿主 CPU 忙等（几乎无内存流量）让 GPU 掉 **29%**（`gpu_busy` **89.9** vs `gpu_only` **126.6 GB/s**） | ✅ **29% vs 39%，同一现象** |
| ② | TF 死路清单："quantized KV cache" 不要重复（`PLAN.md:195`） | 结构上限仅 **1.013–1.095×**，救不了默认聊天 | ✅ 一致 |
| ③ | Swiftlet README：*"the decode loop is close to compute bound"*（低端 M1）；`PLAN.md`：*"decode 是 dispatch bound 而非 IO bound"* | decode 冷态顶在 **118–133 GB/s**（理论 0.96–1.08）⇒ bytes/token 是唯一约束 | ✅ 同一结论 |
| ④ | `PLAN.md`：*"MTP head at int8 for speculative decode, **never int4**: both TF-adjacent projects measured int4 MTP collapse"* | **未独立验证** | ⚠️ 方向一致，**我们未测 int4 draft** |

> **特别值得注意第 ① 行**：两个互相独立的项目、用不同方法、在同类硬件上**测到同一物理现象**（共享功耗包络下 CPU 活动挤占 GPU）。
>
> **这解释了为什么所有 benchmark 必须每配置独立进程。**

---

# 21. 方法论铁律

> **这一章可能是本报告最有长期价值的部分。** 全部铁律都是被真实混淆源欺骗之后总结出来的，每一条都对应一次错误结论。

## 21.1 测量铁律（按确立顺序）

| # | 铁律 | 触发它的事故 |
|---|---|---|
| 1 | **「CoreML 模型文件生成 ≠ CoreML 运行时执行 ≠ ANE 执行」** | Phase-2 的 BLOCKED 误判 |
| 2 | **单 campaign 的 speedup 不足以下结论** —— 必须 ≥2 轮独立 campaign 并报告 range | Phase-3D 的「B 3.26×」被证伪 |
| 3 | **每配置必须独立进程** —— 同进程交替污染可达 **2.75×** | Phase-3C 交替法 346/395 vs 隔离 130/118 ms |
| 4 | **ANE 是否执行，看 compute plan 的 `supported` 列表，不看 sample 栈帧** —— sample 在 S=512 是假阳性 | Phase-3E §5.4 |
| 5 | **burst probe 不能当门禁** —— 58 ms burst 在两种功耗态读出同一值 ⇒ 假阴性 | Proteus-2.2 |
| 6 | **形状覆盖必须对维度本身正交**，否则会把局部伪影误判为全局常数 | Proteus-2.4 的三个形状全含 K=4096 |
| 7 | **测带宽必须在带宽主导区** —— `[1,1,K]` 小矩阵测出的是 launch 噪声 | GPU 假悬崖 min=16.9/max=47.7 |
| 8 | **测算力必须摊薄调度开销** —— 否则会把固定开销误读成算力差距 | ANE「小矩阵快 5 倍」实为 GPU launch 开销 |
| 9 | **顺序扫描若测项本身会致热，必须交错 + 冷却，不能递增排列** | 「长上下文 decode 崩塌」实为热浸泡 |
| 10 | **当某相位自身在衰减时，相位中位数是错误统计量** | `ctx_collapse_cause` 误判 INCONCLUSIVE |
| 11 | **只测「更快」不测「更省电」，会系统性地低估能效型硬件** | 项目全程无功耗数据，漏掉 ANE 唯一的价值维度 |

## 21.2 实验设计铁律

| # | 铁律 | 说明 |
|---|---|---|
| 12 | **保真度必须在复合层级测**（一个 Transformer block / 完整 FFN），不能只测单投影 | int8 per-channel 单投影 9.2e-3 过门禁，穿 FFN 放大到 **1.53e-02** 失败 |
| 13 | **填充类改动必须报 maxdiff**，且必须留「本已快」的对照组 | gate_proj 对照 1.00× 排除了「填充有普遍好处」 |
| 14 | **同进程多线程对照必须配「纯宿主 CPU」对照臂** | 否则 GIL 伪影被误读为硬件竞争（高达 **29%**） |
| 15 | **合成循环测不出 DRAM 真实压力** —— 反复重读同一 33 MB 权重测的是缓存 | 真实 decode 每 token 必流 4.5 GB 且零复用 |
| 16 | **对照臂必须与实验臂等字节量** | 三臂设计（alone / +ANE / +DRAM） |
| 17 | **必须设「效应量应 ≈ 0」的阴性对照臂**（暴露噪声底） | KV 量化实验的 ctx=928 对照臂暴露噪声底 ~1.7× |
| 18 | **实测值必须先与结构预测对齐再解读** | 理论 22.6 vs 实测 1.3 的 17× 缺口本身就是判定依据 |
| 19 | **换页污染是单调的，顺序翻转无法消除** | 网关 rejection A/B 两侧同时衰减 0.51×/0.63× |
| 20 | **绝不把「我编码没复刻对」误判为「原生 MIL 不可达 ANE」** | Phase-3F Q2 护栏 |

## 21.3 判定铁律

| # | 铁律 | 说明 |
|---|---|---|
| 21 | **「算子被拒绝」≠「计算不可表达」** | Proteus-2.3 的自我更正 |
| 22 | **系统地把「软件栈限制」与「硬件限制」分开写** | 本项目硬件限制**未证明** |
| 23 | **把「表示粒度 vs 编译器设备合法性」作为一等约束**：编译期查 `linear.supported` | 勿用运行时延迟启发式，会被假阳性欺骗 |
| 24 | **报告的判据必须写在数据之前**（Gate A/B/C 三层冻结门槛） | 事后调门禁 = 伪造 |
| 25 | **必须保留推翻自己的实验**（包括被推翻的草稿与它的错误） | Proteus-2.3 报告含"这个错误是怎么被发现和纠正的" |
| 26 | **红线**：`NO FAKE SPEEDUP` / `NO SINGLE-RUN CONCLUSION` / `NO UNVERIFIED HARDWARE CLAIM` / `NO SACRIFICING FIDELITY FOR NUMBERS` | 项目不变的 charter |

## 21.4 工具坑（工程备忘）

| # | 坑 | 解法 |
|---|---|---|
| 1 | `gguf` 包无 `RopeScalingType.LLAMA3` | 用 NONE + 手记 factor/orig_ctx |
| 2 | `GGUFWriter.add_tensor()` **自动反转 2D 维度** | 传自然 `[out,in]`，勿手动 `.T` |
| 3 | **1-D norm 必须 F32** | F16 会 ggml abort |
| 4 | `llama-cli` 缺 `-st` 会进交互模式狂输出 | 曾生成 **1.2 GB** 垃圾 |
| 5 | `llama-bench` decode 必须 `-d <ctx>` | 否则是 depth-0 |
| 6 | cmake 用 pip install（Homebrew 无 bottle） | — |
| 7 | `slice_by_size` 在 ANEForge 会失败 | 用**独立输入端口**绕过 |
| 8 | rejection 分支拒绝时**必须 emit 已抽到的 tn** | 重抽会让分布静默偏移 0.126 |
| 9 | 投机路径 `prompt_cache` 必须是 [target 层]+[draft 层] 合并列表 | mlx 按 `len(model.layers)` 切分 |
| 10 | prefix cache trim 必须用 `cache[0].offset` + 真 LCP | 差一位就静默污染输出 |

---

# 22. ANE 的真实价值边界（最终修正后的图景）

> Proteus-2.4 判决 ANE "PERFORMANCE DEAD END"。**这个判决的适用范围后来被两次限缩。**

## 22.1 第一次限缩：能效维度被漏掉了

**触发**：用户提示"详见 ANEForge"+"ANE 作为补充呢"。

**承认的口径差异**：

| | 我们测的 | ANEForge 测的 |
|---|---|---|
| 形状 | S=1 / 单 token decode | **batched serving B=1..256** |
| 指标 | **延迟 / 吞吐** | **吞吐 + 吞吐每瓦（perf/W）** |
| 结论 | ANE 输 | 吞吐：ANE 在小 B 赢；**能效：ANE 在全部 B 都赢** |

> **我们漏掉了「能效」维度，也漏掉了 batched serving 口径。**

## 22.2 能效实测（引自 ANEForge）

**吞吐 cross-over**：

| 工作负载 | cross-over B | 说明 |
|---|---|---|
| vision（conv-stack→GAP→FC） | **无 cross-over** | **ANE 在全部测量的 B 都赢，从未被超越** |
| encoder（transformer block S=128） | ~**B=23** | B<23 ANE 赢 |
| attention（self-attn block S=128） | ~**B=6** | |
| gemm（batched `[B,M,K]@[K,N]`） | ~**B=5** | |

**能效（perf/W）cross-over —— 关键**：

| 工作负载 | ANE 能效优势 | cross-over |
|---|---|---|
| vision | **6.6× → 10.2×** | 无 |
| encoder | **5.4× → 1.9×** | 无 |
| attention | **2.4× → 1.7×** | 无 |
| gemm | **1.6× → 1.1×** | 无 |

> **ANE 在能效上从不输。** 即使吞吐已落后（B=256 的 gemm，ANE 吞吐只有 GPU 的 **0.25×**），**能效仍是 1.07×**。

**vision 吞吐也赢的原因**：conv-stack —— **卷积是 ANE 原生强项**（它本就是为 CNN 设计的），**LLM 的 GEMM 不是**。

## 22.3 修正后的图景

| batch 区间 | 吞吐 | 能效 |
|---|---|---|
| 小 batch（B≲5） | **ANE 赢** | ANE 赢 1.6–6.6× |
| 中等 batch | ANE 赢（vision/encoder） | ANE 赢 |
| 大 batch（B≳23） | GPU 赢 | **ANE 仍赢 1.07–1.9×** |

> **正确表述：ANE 是能效引擎，不是吞吐引擎。**
>
> - **延迟/吞吐优先**（单用户 LLM 推理）→ **GPU 赢**
> - **能效优先**（持续服务、电池供电、热受限）→ **ANE 赢且幅度 1.1–10×**

## 22.4 ⚠️ 本机并发测试

GPU + ANE 同时跑等量负载（S=32，4096→4096）：

| 配置 | 结果 |
|---|---|
| GPU 单独 | 0.017 s = **1801.6 iters/s** |
| ANE 单独 | 0.051 s = 585.0 |
| **并发** | 0.052 s = 1155.9 |
| 串行两次墙钟和 vs 并发实际 | 0.068 s vs 0.052 s → **1.31×** |
| GPU 线程被拖慢 | **1.24×** |
| ANE 线程被拖慢 | **1.01×** |

> **并发收益仅 1.31× 而非 2×**（符合统一内存共享带宽预期），且这是在不平衡负载（GPU 17 ms / ANE 51 ms）下得到的，平衡负载下会更接近 1× ⇒ **并发叠加不是一条可靠路线**。

## 22.5 ⚠️ 证据边界（必须说明）

> **上面能效数据全部来自 ANEForge 在 M-series 上的实测，不是我们在本机测的。**

**本机测不了**：`sudo -n powermetrics -n 1 -i 100` → `sudo: a password is required`；powermetrics 需密码，本会话审批提示被禁用**无法提权**。

| 数据 | 来源 | 本机可复现？ |
|---|---|---|
| 吞吐 cross-over | ANEForge | 部分（我们的 S=1 口径不同） |
| **能效 perf/W** | **ANEForge** | ❌ **不可复现（需 sudo）** |
| 并发叠加 1.31× | 本机 | ✅ 本机实测 |

> **能效结论目前是「引自 ANEForge 的实测数据」，不是「本机验证过的」。** 若作为生产依据需先解决 powermetrics 权限。

## 22.6 三个有证据支持的用法

| 用法 | 证据强度 | 适用场景 |
|---|---|---|
| **A. 能效优先的服务** | **强**（1.1–10×） | 电池供电持续推理、**热受限设备**（"比如本机这台无风扇 M5 Air —— 它的功耗塌缩正是热限制的直接体现"）、多租户功耗预算 |
| **B. 小 batch vision/conv 负载** | **强**（吞吐全程赢 3.1–5.7×） | 视觉任务 |
| **C. 小 batch GEMM/attention** | 有限（B≲5 ANE 赢，gemm 2.2×、attn 3.5× @B=1） | 随 B 快速反转 |

> 📌 **A 可能是本项目最有价值的未开发方向**——我们一直追"更快"，但**没测过"更省电"**。

## 22.7 对本项目的含义

| 陈述 | 修正后状态 |
|---|---|
| ❌ "ANE 路线全面关闭" | **过宽**（吞吐优先场景关闭；**能效优先场景开启**） |
| ✅ "ANE 算力不如 GPU" | 仍成立（7.75 vs 11.51，吞吐维度） |
| ✅ "ANE 无可用的量化形式" | 仍成立（找到保真的但慢 3–5×） |
| ✅ "ANE 小矩阵优势是 launch 假象" | 仍成立 |
| ❌ "ANE 没有价值" | **错——它的价值在能效，不在速度** |

---

# 23. 找保真形式的最后一次尝试（量化搜索）

**问题**：能不能找到一种 ANE 可执行**且**保真度过门禁的权重量化形式？

**门禁（项目标准）**：权重 rel_rmse ≤ 1e-2，**且穿过完整 FFN 后仍 ≤ 1e-2**。

## 23.1 搜索空间（ANE 可执行算子）

来自 Phase-3E + P2.3/2.4 的穷尽验证：`affine_dequantize(scale=[N])`、`lut_to_dense(lut=[1,1,16,1] / [N,1,16,1])`、`blockwise_shift_scale(int8)`。

**权重误差（4 个真实 Llama 张量）**：

| 形式 | gate_proj | up_proj | down_proj | q_proj | 平均 | 过门禁 |
|---|---:|---:|---:|---:|---:|:--|
| per-tensor LUT4 | 0.1193 | 0.1033 | 0.1351 | 0.2034 | **0.1403** | ❌ |
| per-row LUT4 | 0.1074 | 0.1053 | 0.1082 | 0.1703 | **0.1228** | ❌ |
| per-channel int8 | 0.0092 | 0.0087 | 0.0109 | 0.0122 | **0.0102** | ❌（临界） |
| per-channel int4（**非 ANE 可执行**） | 0.1826 | 0.1748 | 0.2134 | 0.2425 | 0.2033 | ❌ |
| **per-row LUT4 + int8 残差** | 0.0033 | 0.0031 | 0.0045 | 0.0050 | **0.0040** | ✅ |
| per-row LUT4 × row-scale | 0.1989 | 0.1942 | 0.2116 | 0.3774 | 0.2455 | ❌ |

> **观察**：单级 4-bit 形式（LUT4、int4）权重误差都在 **10–20%**；per-channel int8 权重层级勉强临界（0.0102）但**FFN 层级会失败**；**两级叠加把误差降一个数量级（0.1228 → 0.0040）**。

## 23.2 ★ 决定性层级 = 完整 FFN

FFN = `down_proj(swiglu(gate_proj(x), up_proj(x)))`，S=128，基准 = 真实 group_q4 反量化：

| 形式 | 权重 rel | FFN cos | **FFN rel_rmse** | 判定 |
|---|---:|---:|---:|:--|
| per-row LUT4 only | 0.1081 | 0.98475313 | **1.76e-01** | ❌ |
| per-channel int8 | 0.0096 | 0.99988317 | **1.53e-02** | ❌ |
| **per-row LUT4 + int8 残差** | **0.0037** | 0.99998271 | **5.87e-03** | ✅ |

> **关键**：per-channel int8 权重层级 0.0096 看似合格，**穿过 SwiGLU 非线性后放大到 1.53e-02 超过门禁**。
>
> **只有两级形式同时通过权重与 FFN 两层。**

## 23.3 为什么两级能过

- 第一级 **per-row 16-entry palette** 捕获每行主要分布（误差 ~12%）
- 第二级对**残差**再做 per-row int8，把剩余误差压到 ~0.4%
- 两者都是 ANE **已证可执行**算子（`lut_to_dense` + `affine_dequantize`）

> **本质 = 「用两次 ANE 可执行的低精度表达，逼近一次 ANE 不可执行的高精度表达」**，与 P2.3 的 group64 分解同一思路，但**分解在权重空间而非计算空间，所以没有 NB 倍部分和流量**。

## 23.4 ❌ 但代价：比 GPU 慢 3–5×

| S | 单级 per-channel int8 | 两级候选 | GPU group_q4 | GPU/两级 |
|---:|---:|---:|---:|---:|
| 32 | 5.645 ms | 7.012 | **1.358** | **0.19** |
| 128 | 5.452 | 7.422 | **1.617** | 0.22 |
| 512 | 8.614 | 16.924 | **5.669** | 0.33 |

**两级相对单级的工作量**：S=32 **1.24×**；S=128 1.36×；S=512 **1.96×**。

**根因仍是老问题**：ANE 的 S=1 权重流在 K=4096 悬崖内，且 ANE 稠密算力（~6.5）低于 GPU（~8–12）。

> **这次给 ANE 一个它"能执行且能保真"的形式，它仍然赢不了。**

## 23.5 完整结论表

| 形式 | ANE 可执行 | 权重复核 | FFN 复核 | 速度 | 采用 |
|---|:--:|:--:|:--:|---|:--:|
| per-channel int8 | ✅ | ⚠️ 临界 | ❌ | 慢 4.2× | ❌ |
| per-channel int4 | ❌ | ❌ | — | — | ❌ |
| per-tensor LUT4 | ✅ | ❌ | ❌ | — | ❌ |
| per-row LUT4 | ✅ | ❌ | ❌ | — | ❌ |
| **per-row LUT4 + int8 残差** | ✅ | ✅ | ✅ **5.87e-03** | **慢 3–5×** | ❌（速度） |
| **group_q4 (block64)** | ❌ | ✅ | 原生 | **GPU 1×** | ✅ **当前生产** |

> **保真度问题解决了，性能问题没解决。**

## 23.6 价值

1. **关闭一条路线**（"给 ANE 一个保真形式就能赢"不成立——**瓶颈不是保真度，是硬件**）
2. **给出可复用工具**（两级量化 = 粗 LUT + 细残差，在权重空间逼近高精度表达，**与 ANE 无关**，可用于任何"目标算子不被支持"的场景）
3. **修正此前判断**：Proteus-1 的 per-channel 优势不只是"保真度换来的"，即使补上保真度，性能依然不够

---

# 24. 项目全景时间线

| 日期 | 阶段 | 关键事件 |
|---|---|---|
| ~08-26 | P2–P4E | 单 Linear crossover（S≥320 ANE 胜 0.65–0.92）；量化 Attention 探索 |
| ~08-27 | P3B / P4A | FFN 上缩水成窄带 S≈256–448；运行时编排下 ANE 全输 |
| 08-28 前 | **P6.2** | **冻结真实 Llama MLX 引擎**（vs mlx_lm corr=1.0000） |
| 08-28 | P6.3 / P6.4 | 诚实报 speedup=1.0×（MLX 无 ANE 设备）；CoreML bring-up BLOCKED |
| 08-29 | **Phase-2** | 单 Linear 验证，运行时 BLOCKED → 铁律「文件生成 ≠ 运行时 ≠ ANE 执行」 |
| **08-30** | **Phase-2B ★** | **INT4 ANE-native dequant 在真实权重上 VALIDATED**（21 算子 corr≥0.96，S=512 1.27–2.10×） |
| 08-30 | FP32 孪生 | **FP32 不适合 ANE**（geomean 0.68×）→ 转向 INT4 的直接原因 |
| 08-30 | Phase-3A | 融合把 96 次调用降到 32 次（37.4 s → 1.23 s @S=512）；**GPU 基线测低** |
| 09-10 | **Phase-3B** | 测得 4 区域 crossover map（峰值 2.37×）；**发现 S=96/128 未派发 ANE**；修正 3A 基线 |
| 09-10~11 | **Phase-3C** | 32 层 E2E：prefill 1.87×（保守 1.66×）；decode 无收益；cold 0.81×；**发现表征误差是 placement 误差的 32 倍** |
| 09-11 | **Phase-3D** | 候选搜索，找不到 IDEAL candidate；B 报 3.26×（后被证伪） |
| 09-11 | **Phase-3E** | **Barrier 定位到 `COMPILER_LOWERING`**（STRONGLY_SUPPORTED） |
| 09-12 | **Phase-3F** | **原生 MIL 排除构建路径** → VERY_STRONGLY_SUPPORTED；**Proteus-1 冻结** |
| 09-12 | **P2 Phase-1** | 首次外部基线 → **Gate C（数据作废）** |
| 09-12 | **P2 Phase-1b** | 洁净重测 → **Gate P2-1 = B**（R=0.823），MLX 与 llama.cpp 同级 |
| 09-12 | **P2 Phase-2.2** | **Gate P2-2 = LOW**，FFN 已达 ALU 峰值 86.5%，不触发自研 Metal |
| 09-12 | **P2 Phase-2.3** | 绕过 CoreML 成功；group64 可分解表达（cos 0.99998）但慢 6× |
| 09-12 | **P2 Phase-2.4** | **Outcome C / PERFORMANCE DEAD END**（0/34 配置 ANE 胜） |
| 09-12 | proteus_review | 四份收尾复盘（5 条科学发现 / 11 条被证伪路线 / 硬件 frontier） |
| **09-13** | **ANEFORGE_CROSSVALIDATION** | **推翻 2.4 前提**：同一矩阵测出 113.5 vs 20.2 GB/s（差 5.6×） |
| **09-13** | **BYTESIZE_LAW** | **16 MiB 字节大小律**（23/23 命中，2.57× 惩罚）；零填充逃逸 2.58× |
| 09-13 | **OFFLOAD_VERDICT** | **卸载零和**（ane/dram = 0.906）；decode 已顶 DRAM 屋顶线 |
| 09-13 | **COMPUTE_PUSH** | ANE 算力峰值 7.75 < GPU 11.51；推翻自身「小矩阵优势」 |
| 09-13 | **QUANT_SEARCH** | 找到过双门禁的形式（两级量化）但**仍慢 3–5×** |
| 09-13 | **AS_SUPPLEMENT** | 限缩「ANE 全面落败」→ **ANE 是能效引擎** |
| 09-13 | **PREFILL_CORRECTION** | 承认漏报 prefill 优势，但那是 per-channel 换来的 |
| 09-13 | **SPEEDUP_DIRECTIONS** | **找到 Speculative Decoding**（nd=2，1.61×，无损） |
| 09-13 | **FINAL_TECHNICAL** | 从零解释的完整技术报告（1.61×，91.80% 一致率） |
| **09-13 23:00–23:58** | **DECODE_PUSH** | **推翻「nd=4 最优」→ nd=2**；**推翻「temp=0.7 负收益」**；**上线，网关 1.284×** |
| **09-14 凌晨** | **REJECTION_SAMPLING** | **拒绝采样上线**（1.004→1.210，19/22 胜）；nd=3 |
| 09-15 | gm 网关 | TTFT 修复（prefix cache 22.3×）；32K 上下文放开；KV int8 省 1.53 GB |
| 09-16 | **gm-probe** | 模型通用性工具：三道校验（快照完整性 / tokenizer 兼容 / 规模关系）；诚实报告"不支持加速" |
| 09-16 | **投产改造** | 网关改 ThreadingHTTPServer（修「一次对话后自动离线」）；项目迁出 iCloud；网关改用 Python 3.11 |
| 09-16 | **Proteus Studio** | SwiftUI 桌面工具（对话 / 接入 / 服务三页），替换掉不可用的 tkinter 版 |
| 09-16 | **本报告** | Proteus 全集技术报告（第 27 章记录投产全过程） |

---

# 25. 数据总表

## 25.1 最终生产方案数字

| 指标 | 数值 | 来源 |
|---|---|---|
| decode（网关，temp=0.7，nd=2） | **1.284×**（29.43 → 37.78 tok/s） | DECODE_PUSH §8.2 |
| decode（离线配对，temp=0.7，rejection，nd=3） | **1.210×**（19/22 胜） | REJECTION_SAMPLING §3 |
| decode（离线配对，greedy，nd=2） | **1.247–1.490×** | DECODE_PUSH §2 |
| decode（洁净主机配对，nd=4） | **1.575×**（4/4 胜） | OFFLOAD_VERDICT §4.1 |
| 逐 token 一致率 | **91.80%**（7/8 prompt 完全一致） | FINAL_TECHNICAL §3.6 |
| 分布保真（600 trial max\|emp−p₀\|） | 0.0101（baseline 噪声 0.0049） | REJECTION_SAMPLING §2 |
| 接受率提升（exact → rejection） | 0.724 → **0.872**（**+0.148**） | REJECTION_SAMPLING §1 |
| 额外内存 | +0.7 GB（1B 草稿，4-bit） | FINAL_TECHNICAL §4.2 |

## 25.2 Proteus-1 最终成绩单

| 场景 | 最佳实测 | 可复现 | 备注 |
|---|---|---|---|
| **Prefill S=512** | **1.87×**（保守 1.66×） | ✅ 两轮 | 223.3 → 417.6 tok/s |
| Prefill S=256 | 1.63×（保守 1.27×） | ❌ | run2 = 1.27 |
| Prefill S=160 | 1.60×（保守 1.01×） | ❌ | run2 = 1.01 |
| Prefill S=64 | 1.21× | 🟨 边界 | run1 1.212 / run2 1.424，差 14.9% |
| Prefill S=32 | **1.10×** | ✅ | |
| Prefill S=96/128 | **1.00×** | ✅ 设计如此 | R3 黑名单 |
| Decode（默认策略） | **1.00×**（噪声内） | — | S=1 选 GPU，无 CoreML 边界 |
| Decode（强制 ANE） | **0.57–0.74×（变慢）** | ✅ | ctx≤512 稳定慢 26–43% |
| E2E warm | **1.05×**（0.99–1.36×） | — | prefill 仅占 ~14% |
| E2E cold | **0.81×（变慢）** | ✅ | 首 token **0.27×**（慢 3.8×） |

**Decode 噪声 floor ≈ ±17%**。

## 25.3 Crossover Surface（单层 L0 fused FFN）

| S | 1 | 2 | 4 | 8 | 16 | 32 | 64 | 96 | 128 | 160 | 256 | 384 | 512 | 768 | 1024 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| GPU ms | 1.109 | 0.776 | 0.888 | 1.526 | 2.210 | 2.302 | 4.006 | 3.393 | 3.501 | 9.154 | 14.632 | 21.241 | 31.634 | 51.357 | 71.209 |
| ANE ms | 1.374 | 1.370 | 1.379 | 1.385 | 1.413 | 1.481 | 1.691 | **48.734** | **62.946** | 6.193 | 8.573 | 13.348 | 18.639 | 28.688 | 43.745 |
| 加速 | 0.81 | 0.57 | 0.64 | 1.10 | 1.56 | 1.55 | **2.37** | **0.07** | **0.06** | 1.48 | 1.71 | 1.59 | 1.70 | 1.79 | 1.63 |

## 25.4 保真度 vs 速度（核心取舍）

| 表示 | 权重相对误差 | ANE 上速度 | 判定 |
|---|---|---|---|
| MLX group_q4（基线） | **0.0（参考）** | N/A（MLX 无 ANE） | ✅ 生产 |
| per-channel INT4 对称（冻结模型） | **0.18–0.21** | **快**（1.70 ms @S=32） | ❌ 不忠实 |
| per-block64 非对称 INT4（忠实） | **0.043** | **慢 4.0–5.7×** | ❌ 不上 ANE |
| int8 per-channel | 0.0093 | 快 | ❌ 穿 FFN 放大到 1.53e-02 |
| **per-row LUT4 + int8 残差** | **0.0037** | **慢 3–5×** | ❌ 保真但慢 |

## 25.5 量化位宽阶梯（gate_proj 权重 rel_rmse，group=64）

| bits | 8 | 6 | **4（当前）** | 3 | 2 |
|---|---:|---:|---:|---:|---:|
| rel_rmse | 2.3e-03 | 2.35e-02 | **3.49e-02** | **2.21e-01** | **4.14e-01** |

> **4→3 bit 误差跳 6.3×，2-bit 达 0.41（权重基本被毁）。当前 4-bit 已贴保真度边界。**

## 25.6 M5 硬件 Frontier 总表

| 单元 | 算力 | 权重流带宽 | 判定 |
|---|---|---|---|
| **统一内存** | — | **~120 GB/s**（实测可用 ~116） | **decode 的真正主瓶颈** |
| **GPU** | **11.65–11.9 TFLOP/s**（峰值）<br>7.3–8.2（真实 LLM 形状） | **~100 GB/s** | MLX 已用 **86.5%** 算力；headroom **9.23% E2E** |
| **ANE** | **6.53–7.75 TFLOP/s** | **~20 GB/s**（后被字节律修正为 fp16 专属；带外 ~54） | 两 regime 均输；分组 4-bit dequant op **不存在** |

**限制类别**：

| 类别 | 内容 | Proteus 能改变？ |
|---|---|---|
| **HARDWARE LIMIT** | 统一内存 ~120 GB/s；GPU 8–12 TFLOP/s；ANE ~6.5–7.75 TFLOP/s；ANE 权重流 | ❌ |
| **ARCHITECTURAL LIMIT (ISA)** | ANE 无分组 4-bit dequant op、无 per-block scale、无 per-block LUT、无 blockwise shift | ❌（需 Apple 改 ISA） |
| **SOFTWARE STACK LIMIT** | CoreML 无法 lower per-block64（**已被证明非决定性**） | ⚠️ 理论可修，但修了也无收益 |
| **API LIMIT** | 无功耗计数器；无 ANE 硬件计数器；无零拷贝 host↔CoreML | ⚠️ 影响测量不影响结论 |
| **MEASUREMENT LIMIT** | 热态 2× 可逆塌缩；S=1 比值带跨 1.0 | ⚠️ 已缓解到可用程度 |

## 25.7 「下一代硬件重启清单」（写给未来的自己）

| 触发条件 | 该跑的实验 | 预期 |
|---|---|---|
| Apple 发布支持分组 4-bit dequant **权重操作数**的 ANE op（任何 API 层） | P2.4 Experiment D 的 IDEAL_2/3 直接实测 | **[Mo] ~0.25× MLX（~4× 快）** |
| ANE 权重流带宽实测 **> 60 GB/s** 的新芯片 | 重跑 P2.4 Experiment A 全套 | [I] ANE 角色质变 |
| 统一内存带宽 **≥ 200 GB/s** 的芯片 | 重跑 decode 下限分析 | [I] decode 瓶颈从带宽转向算力 |
| MLX 或 llama.cpp 原生支持混合设备调度且暴露 per-op device 选择 | 重跑 P1 Phase-3C 的 32 层 E2E（fused FFN + 忠实 group64） | [I] **未决实验** |
| 出现 >13B 可量化模型且 16 GB 装不下 | 重评"小内存"目标本身 | — |

## 25.8 关键数字疑点（如实标注）

| 疑点 | 说明 |
|---|---|
| P2.4 配置数 | 正文「34 个」/ Artifacts「18」/ §7 与 ROADMAP「17」——三处口径不同 |
| per-channel 权重误差 | Phase-3D 写 0.2014 / Phase-3E Layer A 写 0.1915 / Final Summary 写 0.18–0.21 |
| P6.2 峰值 RSS | ~10.6 GB（KV decode 实验）与 ~5.16 GB（性能摘要）未解释差异 |
| `153 GB/s` 内存带宽 | 假设值，Q10 判 `NOT_SUPPORTED`，但在多处分析中被继续使用 |
| GPU 参考跨进程漂移 | **2–3.9×**，是项目最大未受控混淆源，未在 CONFIRMED 列表中单列 |
| 「macOS 27.0」 | 报告原文如此，真实性存疑（归档方已自行加注） |
| proteus24 报告数 | PROVENANCE 自述 13 份，实际目录 16 份 |
| MIDTERM_STATUS 日期 | 与 DECODE_PUSH 同标 09-13，但内容晚于后者 |

---

# 26. 结论

## 26.1 一句话总结

> **Proteus 用 11 条被严格证伪的技术路线，换来了一张完整的 M5 硬件能力边界图，并最终在唯一幸存的杠杆上取得了产品级成果：Speculative Decoding 在真实网关上线，默认温度路径端到端提速 1.284×。整个 ANE 路线，从"未开发的算力金矿"这一最初猜想出发，被三阶段、四份 frontier map、上百个实验逐步否定到零和。**

## 26.2 五层判定

| 层 | 判定 |
|---|---|
| **原始工程假设** | **三条全被证伪** —— 这是项目的核心产出 |
| **已证伪路线** | **11 条**，全部保留可复现的数据链 |
| **成功发现** | **5 条**普适、可迁移的科学发现 |
| **技术资产** | ANEForge 直连通道、私有 e5rt API 签名表、手写 MIL 通路、算子级 profiling 框架、持续热态 probe 协议、完整 32 层真实 Llama INT4 runtime、placement map |
| **产品目标** | 🟨 **部分达成**：小内存 ✅ / 大模型 ✅ / 高速度 🟨（唯一有效杠杆已上线） |

## 26.3 五条可迁移的科学发现

1. **ANE 权重取数的「16 MiB 字节大小律」** —— 取数速率只由权重张量字节数决定，与 K/N 无关（23/23 命中，2.57× 惩罚）。
2. **「表示可行」与「性能可行」必须分开验证** —— 单 op 被拒绝 ≠ 计算不可表达。
3. **保真度误差会在复合算子中放大** —— 逐算子门禁会产生假阳性通过。
4. **无风扇机器上的持续功耗塌缩与 burst probe 假阴性** —— 完整可复用的测量协议。
5. **decode 下限由内存带宽决定，且当前 runtime 已贴住它** —— 把"还能不能更快"变成一道算术题。

## 26.4 最重要的三条认知

> **① 「瓶颈是数据搬运，不是算力」**
>
> 这条在**四个互相独立的项目**里被重复验证：colibri（CPU 忙等拖慢 GPU **39%**）、我们的独立测量（**29%**）、Swiftlet（"decode 是 dispatch bound 而非 IO bound"）、ANEForge（ANE 上 verify(K)≈verify(1)）。

> **② 「知道边界在哪，本身就是这类硬件研究的主要产出」**
>
> 11 条被证伪的路线不是 11 个独立的失败，而是**同一个硬件常数的 11 种表现**。

> **③ 「不因投入巨大而人为宣布成功，也不因产品未实现而忽略已获发现」**
>
> 项目在最接近"宣布胜利"的时刻（Phase-2B 的 1.27–2.10×）没有宣布，而是继续追问"这个优势是怎么来的"——**最终发现它建立在过不了门禁的量化形式上**。

## 26.5 最终技术路线图

```
                        ┌─────────────────────────────────┐
                        │  目标：小内存 · 大模型 · 高速度   │
                        └─────────────────────────────────┘
                                       │
              ┌────────────────────────┼────────────────────────┐
              ▼                        ▼                        ▼
        ┌──────────┐            ┌──────────┐            ┌──────────┐
        │  小内存   │            │  大模型   │            │  高速度   │
        │   ✅     │            │   ✅     │            │   🟨     │
        │ 4.21 GB  │            │ 8B 等价  │            │ 1.284×   │
        └──────────┘            └──────────┘            └──────────┘
         MLX 生态功劳            MLX 生态功劳                  │
                                                             │
                              ┌──────────────────────────────┘
                              ▼
                   decode 已顶 DRAM 屋顶线（~123 GB/s）
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
      ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
      │ 减少 bytes/ │ │ 一次前向多  │ │ 不重复搬运  │
      │   token     │ │  出 token   │ │ 已搬过的字节│
      │  已近极限   │ │ ✅ 已上线   │ │ ⚠️ 判定中   │
      │             │ │  1.284×     │ │ prefix cache│
      └─────────────┘ └─────────────┘ └─────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  Speculative     │
                    │  Decoding        │
                    │  + 拒绝采样      │
                    │  + 温度感知路由  │
                    └──────────────────┘
```

---

# 附录 A 文件清单

> **本附录列出项目全部报告与数据文件的原始位置。** 第二项任务（归档整理）已将这些文件汇集到同一目录，详见 [附录 B](#附录-b-归档整理说明)。

## A.1 MLXonANE（iCloud 归档，Proteus-1 全部产物）

**根目录索引文件**：

| 文件 | 内容 |
|---|---|
| `README.md` | 总索引 + 诚实性声明 6 条 |
| `PROTEUS1_FINAL_SUMMARY.md` | ★ 最终结论汇总（先读这个） |
| `EXPERIMENT_TIMELINE.md` | ★ 实验时间线与判断演进链 |
| `PROTEUS2_CANDIDATES.md` | Proteus-2 候选方向评估（PROPOSAL ONLY） |

**阶段目录（每阶段含 `code/ data/ reports/ models/`）**：

| 阶段 | 报告 |
|---|---|
| `P6.2/` | `PHASE_SUMMARY.md`、`reports/Phase6_PHASE2_REPORT.md` |
| `Phase-2/` | `PHASE_SUMMARY.md`、`reports/real_llama_int4_operator_report.md`（INT4 ★）、`reports/real_llama_operator_report.md`（FP32 孪生） |
| `Phase-3A/` | `PHASE_SUMMARY.md`、`reports/PROTEUS1_PHASE3_RUNTIME_OPTIMIZATION_REPORT.md` |
| `Phase-3B/` | `PHASE_SUMMARY.md`、`reports/PROTEUS1_PHASE3B_CROSSOVER_REPORT.md`、`data/proteus1_phase3b_phase3a_baseline_correction.md` |
| `Phase-3C/` | `PHASE_SUMMARY.md`、`reports/PROTEUS1_PHASE3C_E2E_REPORT.md` |
| `Phase-3D/` | `PHASE_SUMMARY.md`、`reports/PROTEUS1_PHASE3D_REPRESENTATION_REPORT.md`、`reports/PHASE3D_FROZEN_GATES.md` |
| `Phase-3E/` | `PHASE_SUMMARY.md`、`reports/PROTEUS1_PHASE3E_BARRIER_REPORT.md`、`models/BUILD_NOTES.md` |
| `Phase-3F/` | `PHASE_SUMMARY.md`、`reports/PROTEUS1_PHASE3F_NATIVE_MIL_REPORT.md`、`models/BUILD_NOTES.md` |
| `P6.2/` | `reports/Phase6_PHASE2_REPORT.md` |

**`_raw_archive/Results/`**：**81 个原始 CSV/JSON/MD**，与源目录 **byte-identical，永不覆盖**。

**外部项目**：

| 目录 | 内容 | 规模 |
|---|---|---|
| `ANEForge-main/` | ANEForge 源码（ANE 直连通道） | 7.0 MB |
| `Swiftlet-main/` | Swiftlet 源码（Swift+Metal，纯 GPU） | 760 KB |

## A.2 ANEProbe（本机实验台）

**顶层报告目录**：

| 路径 | 内容 |
|---|---|
| `Results/` | 早期阶段报告（Phase2/3A/5A/5B/6 系列、P3B、P4D、FusedFFN、FFNProbe） |
| `Proteus2/` | Proteus-2.0/2.1/2.2（含 `MEMORY.md`、`PROTEUS2_ROADMAP.md`） |
| `proteus23/` | Proteus-2.3 ANEForge 审计 |
| `proteus24/` | **Proteus-2.4 + 15 份后续报告（更正链核心）** |
| `proteus_review/` | 四份收尾复盘（科学发现 / 硬件 frontier / 最终审查 / 下一路线图） |
| `P6/` `P6.4/` `P65/` | P6 系列运行时与突破方案 |
| `P3B/` `P4AFFN/` `P4BFFN/` `P4CFFN/` `P4DAttention/` `P4E/` `P5A/` `P5B/` `P5AFusedFFN/` | 早期单算子探索 |
| `Models/` | 构建的 CoreML 模型（10 GB） |
| `P6Model/` | 真实 Llama runtime 代码与 venv |

## A.3 关键报告优先级（若要精简阅读）

| 优先级 | 文件 | 理由 |
|---|---|---|
| ★★★ | `PROTEUS1_FINAL_SUMMARY.md` | Proteus-1 全部结论 |
| ★★★ | `EXPERIMENT_TIMELINE.md` | 判断演进链 |
| ★★★ | `Phase-3E/reports/PROTEUS1_PHASE3E_BARRIER_REPORT.md` | Barrier 定位（方法论密度最高） |
| ★★★ | `proteus24/PROTEUS_ANE_BYTESIZE_LAW.md` | 16 MiB 字节律（纯原创） |
| ★★★ | `proteus24/PROTEUS_FINAL_TECHNICAL_REPORT.md` | 从零解释的完整叙述 |
| ★★ | `Phase-3F/reports/PROTEUS1_PHASE3F_NATIVE_MIL_REPORT.md` | 双路径验证 |
| ★★ | `Phase-3C/reports/PROTEUS1_PHASE3C_E2E_REPORT.md` | 32 层 E2E 与保真度发现 |
| ★★ | `proteus24/PROTEUS_ANE_OFFLOAD_VERDICT.md` | 卸载零和定论 |
| ★★ | `proteus_review/PROTEUS_FINAL_TECHNICAL_REVIEW.md` | 项目终判 |
| ★★ | `proteus24/PROTEUS_DECODE_PUSH_REPORT.md` | 最终上线方案 |
| ★ | `proteus_review/PROTEUS_SCIENTIFIC_FINDINGS.md` | 5 条普适发现 |
| ★ | `proteus_review/PROTEUS_HARDWARE_FRONTIER.md` | 硬件边界表 |


# 27. 从研究到投产 —— 模型通用性、实际落地与 Proteus Studio

> **本章记录 2026-09-16 的工作**：把前面 26 章的研究成果从"实验台上的结论"变成"可日常使用的工具"。这一章包含三部分：**模型通用性**（能不能对任意 MLX 模型都有效）、**实际投产**（网关改造与线上部署）、**Proteus Studio**（一份可用的桌面工具）。

---

## 27.1 目标：让加速能力覆盖所有 MLX 模型

前面所有工作的结论都建立在**一个模型**上：Llama-3.1-8B-Instruct-4bit。投产必须回答：

> **这套加速方案能不能用在别的模型上？能用到什么程度？**

先说结论，因为这里有一条**必须讲清楚的数学边界**：

> 🟨 **「对所有 MLX 模型都有加速」在数学上不成立。** 投机解码的收益取决于草稿成本比 `c = 草稿时间 / 目标时间`：
>
> ```
> 收益 = 接受长度 / (1 + c)      要加速必须 c < 1，即草稿必须比目标小
> ```
>
> - **8B / 14B / 32B / 70B**：各主流模型族都有 0.5B–3B 的小兄弟 → **可以加速**，且目标越大收益越大
> - **小模型（0.5B–3B）**：没有更小的同族草稿 → `c ≥ 1` → **必然更慢**
> - **新发布架构**：还没有对应的小模型 → 无草稿可用
>
> **这不是实现缺陷，是投机解码的数学前提。** 任何声称"对小模型也能靠投机提速"的方案都是在骗人。

### 27.1.1 交付物：`gm-probe`

把「接入一个新模型」从手工四步变成一条命令：

```bash
./gm-probe <模型路径>              # 探测（只读）
./gm-probe <模型路径> --sweep      # 附带实测扫描 n_draft
./gm-probe <模型路径> --write      # 写回配置（自动备份）
```

**三道校验，每道都对应一个真实陷阱：**

| # | 校验 | 防的是什么 |
|---|---|---|
| 1 | **快照完整性** | HF cache 里常见"只下载了 `config.json`"的半成品目录。这种目录指纹读起来完全正常，但 tokenizer 会加载成 `vocab=1` 的空壳，进而报出**误导性的**「词表不兼容」——实际只是文件没下完 |
| 2 | **tokenizer 兼容性** | vocab size 相等 + **BOS 归一化后**的探针编码逐 id 比对 |
| 3 | **规模关系** | 草稿的 `hidden_size` 必须严格小于目标。否则 `c ≥ 1`，投机必然亏损 |

**第 2 道的实现细节值得单独说**，因为第一版写错了两次：

```
坑 1：不同 tokenizer 的 encode() 对 BOS 处理不一致
  Llama-3.1-8B  encode("The capital") → [791, 6864]         （无 BOS）
  Llama-3.2-1B  encode("The capital") → [128000, 791, 6864] （有 BOS）
  两者其实是同一个词表（vocab 都是 128000，剥掉首位 BOS 后逐 id 一致）。
  直接比对原始输出 → 会把生产在用的合法草稿误判为不兼容。

坑 2：chat_template 字符串不等 ≠ 不兼容（所以刻意不检查它）
  两个模板确实不同，但差异是：
    target(Llama-3.1): "Today Date: 26 Jul 2024"   （写死）
    draft (Llama-3.2): "Today Date: 16 Sep 2026"   （strftime_now 取当天）
  更关键的是：网关的 _encode_chat() 只用 target 编码，draft 拿到的是
  target 已编码好的 token id，自己从不调用 chat_template。
  ⇒ 模板与 token id 空间正交，不应作为闸门条件。
```

**验证结果**（真实 tokenizer）：

| 草稿模型 | 判定 | 依据 |
|---|---|---|
| Llama-3.2-1B（生产在用） | ✅ 放行 | vocab 128000，探针全过 |
| Qwen2.5-0.5B | 🚫 拦截 | vocab 151643 vs 128000 |
| Qwen2.5-1.5B | 🚫 拦截 | 快照不完整（只有 config.json） |
| 手工指定更大草稿 | 🚫 拦截 | 规模关系不成立 |

**端到端负对照**：故意把配置改成 Qwen 草稿 → 闸门拦下、投机安全禁用、**网关照常服务**，`/stats` 给出明确原因：

```json
{"active": false,
 "disabled_reason": "tokenizer incompatible: vocab size differs
                     (target=128000, draft=151643)"}
```

### 27.1.2 诚实呈现：不支持时明确说不支持

`gm-probe` 遇到无法加速的模型时，会区分三种情况（因为它们给用户的行动完全不同）：

| 情况 | 输出 | 用户该做什么 |
|---|---|---|
| **结构性不可用** | 🟥 「不支持投机解码加速」+ 数学原因 | 换思路 |
| **尚未下载** | 🟨 「暂时无法判定——同族草稿尚未下载」 | 下载后重跑 |
| **快照不完整** | 🟥 「模型目录不完整」 | 重新下载 |

**并且会给出两个真正模型无关的杠杆**（虽然它们加速的是 TTFT/内存，不是 decode 吞吐）：

- **`prefix_cache`** —— 多轮对话复用 KV 前缀，只用 `trim_prompt_cache`，与模型族无关
- **`prefix_cache.kv_bits`** —— int8 KV 量化，`QuantizedKVCache` 是 mlx_lm 通用能力

### 27.1.3 `--sweep` 的一个自我修正

n_draft 扫描的第一版按 `nd=1→N` **顺序**各测一块，结果把 nd=4 测成 8.69 tok/s（nd=2 是 22.08），看起来像灾难性退化。

**交替复测的比值只有 0.969** —— 纯热假象（后面测的 nd 跑在更热的机器上）。这恰好**违反了项目自己的铁律**「顺序扫描若测项本身会致热，必须交错 + 冷却」。

改为**轮转交错**（每轮所有 nd 各测一次）后：

| nd | 顺序扫描（错误） | 轮转交错（正确） | accept_len |
|---:|---:|---:|---:|
| 1 | 21.86 | 12.06 (0.926) | 1.49 |
| 2 | 22.08 | **13.02 (1.000)** | 2.00 |
| 3 | 18.50 | 11.99 (0.920) | 2.08 |
| 4 | **8.69** ← 假崩塌 | **12.71 (0.976)** | 2.38 |

但四次独立扫描仍给出**四个不同的最优值**（2/2/1/3），逐 nd 比值跨度最高 0.190。因此工具增加了**可信度分级**：并列时标注 `LOW` 并报出整个并列区间，而不是给一个伪精确的"最优值"。真正稳定的信号是 `accept_len`（纯算法量、不受热态影响）。

---

## 27.2 实际投产：网关改造

### 27.2.1 环境阻塞与解决

投产过程中踩到三个环境问题，都记录在此以免重犯：

| 问题 | 真因 | 解决 |
|---|---|---|
| 网关反复报 `Resource deadlock avoided` | **launchd 进程读 iCloud 目录里的 `.py` 会触发 fileprovider 死锁**（终端跑同一份代码正常，实测同一包在 `/tmp` 下可导入、在 iCloud 下报 EDEADLK） | **项目迁到 `~/GeneralModel/`**（本地） |
| Proteus-1 报 `Unable to load libmodelpackage` | 系统 Python 3.14 的 coremltools **缺 `libcoremlpython` 原生库** | 网关改用 **Python 3.11 venv** |
| 重启后偶发端口占用 | KeepAlive 与服务端 socket 未设重用 | `allow_reuse_address = True` |

> 📌 **通用教训**：**服务不该跑在 iCloud 目录里**。这与项目早期「工作台.app 构建时 SYMROOT 必须指到 iCloud 外」是同一类摩擦。

### 27.2.2 ★ 最严重的一个 bug：网关"一次对话后自动离线"

**现象**：GUI 发完一次对话后显示"网关离线"，但 `launchctl` 显示进程一直好好地跑着。

**诊断**：问题不在**存活**，而在**响应能力**。决定性实验 —— 长流式请求进行中，并发探测 `/stats`：

| | 修复前 | 修复后 |
|---|---|---|
| 第 1 次 | **HTTP 000，超时 15035ms** | HTTP 200，**29ms** |
| 第 2 次 | **HTTP 000，超时 15036ms** | HTTP 200，**17ms** |
| 第 3 次 | **HTTP 000，超时 15033ms** | HTTP 200，**14ms** |

**根因**：`gm/server.py` 用的是**单线程** `HTTPServer`。一次 SSE 流式请求会独占唯一的处理线程几十秒 —— 期间 `/stats`、`/v1/models` 全部卡在 accept 队列里超时。而 GUI 每几秒轮询 `/stats` 判存活 → 全部超时 → 显示"离线"。

原代码的注释给的理由是：

> MLX 的 KV cache state 绑定创建它的线程/stream，跨线程会抛 `no Stream(gpu, 1)`

**但这个理由已经被 `gen_lock` 完全覆盖了** —— 核查所有生成路径（`server.py` 第 169、227、301 行），全部在 `with self.manager.gen_lock:` 内。也就是说：

```
连接处理并发（多线程）      ← 需要
推理串行化（gen_lock）      ← 已实现
```

**单线程 HTTP 没有提供任何 gen_lock 没提供的东西，只额外带来了"流式独占"这个坏处。**

**修法**：`make_server()` 改回 `ThreadingHTTPServer` + `daemon_threads=True` + `allow_reuse_address=True`。

**完整场景验证**（一边跑流式对话、一边每 2 秒轮询，共 20 次）：

```
✅ 成功 20 次 / ❌ 失败 0 次        （修复前：全部超时）
```

> 🔒 **新增铁律**：**HTTP 层的连接处理与模型推理的串行化是两件事，不要用"单线程"同时实现两者。**

### 27.2.3 线上配置（投产实态）

`models.json` 收敛为两条，命名遵循明确的约定：

| 名称 | aliases | 含义 | 配置 |
|---|---|---|---|
| **`proteus-1`** | `default` / `general` / `proteus1` | **当前全部优化（最新路线）** | 投机解码 ✅ + prefix cache ✅ + KV int8 ✅ |
| **`gpu-baseline`** | `gpu` / `raw` | **研发前最原生 MLX 运行（基线对照）** | 三项全关 |

> **命名约定（Tristan 2026-09-16 明确）**：
> - **Proteus-1** = 投机解码 + prefix cache + KV int8，即当前全部优化
> - **GPU** = 研发前的最原生 MLX 运行，无任何优化，作基线

**实测对照**（同一 prompt，60 token，热态）：

| 方案 | tok/s | TTFT | 标记 |
|---|---|---|---|
| **Proteus-1** | 23.77 / **32.25** / **31.95** | 0.84 / 0.37 / 0.35 s | `spec=True` |
| **GPU** | 8.89 / 23.57 / 24.03 | 4.43 / 0.42 / 0.36 s | `spec=False` |

---

## 27.3 Proteus Studio —— 一份可用的桌面工具

### 27.3.1 为什么推翻了第一版

第一版 GUI 用 Python tkinter 写。**结论：不可用** —— tkinter 的渲染能力有硬性天花板，做不到体面的 macOS 界面（无真正圆角、无毛玻璃材质、无原生动画、控件样式陈旧）。

第二版改用 **SwiftUI 原生重写**。这不是"换个配色"，是**换技术栈**：

| 维度 | tkinter 版 | SwiftUI 版 |
|---|---|---|
| 气泡 | Canvas 手绘多边形凑圆角 | 原生 `RoundedRectangle(.continuous)` 连续曲率 |
| 材质 | 纯色块 | `.ultraThinMaterial` / `.bar` 原生毛玻璃 |
| 输入框 | 扁平 Text | `TextEditor` + 聚焦描边动画 + 自适应高度 |
| 侧边栏 | `ttk.Notebook` 标签 | `NavigationSplitView` 原生分栏 |
| 图标 | 无 | SF Symbols |
| 动效 | 无 | 发送按钮弹簧缩放、打字指示点动画 |
| 菜单 | 无 | ⌘N 新对话 / ⌘. 停止 / ⌘R 刷新 |

### 27.3.2 结构

```
Proteus Studio.app
├── 对话        分段控件选方案 + 实时指标（tok/s、TTFT、accept）
│               + 气泡式消息流 + 每条的性能脚注
├── 接入模型    三步卡片流程，直接驱动 gm-probe
└── 服务        网关状态、端点表、可复制的 agent 接入片段、限制说明
```

**技术要点**：

- **零第三方依赖** —— 纯 SwiftUI + Foundation，符合项目"不引重框架"的铁律
- **`xcodegen` 生成工程** —— `project.yml` 声明式配置，无 `.xcodeproj` 手工维护
- **复用 Python 侧逻辑** —— 接入页直接调 `gm.probe_cli`，不重复实现探测

### 27.3.3 开发中修掉的问题（都是真实故障）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 程序频繁"未响应" | `Process.waitUntilExit()` 是同步阻塞，直接在 `@MainActor` 上调用 → 主线程被占死 | 挪到后台队列 + `CheckedContinuation` |
| 2 | 程序频繁"未响应" | **管道死锁**：先 `waitUntilExit()` 再读管道；子进程输出超 64KB 缓冲时阻塞在 write，父进程永远等不到 | 改为**先读到 EOF 再 wait** |
| 3 | **无法流式输出** | `onDelta` 在后台线程同步调用，却直接改 `@Published`。Swift 6 下是数据竞争；`firstDelta` 被多条并发路径争抢 | 加带锁的 `FirstDeltaClock`；UI 更新统一 hop 主线程 |
| 4 | 重启按钮无效 | `try? p.run()` 把失败静默吞掉；也没有进行中提示 | 捕获 stderr + 退出码；加 `ProgressView` 与"重启中…"；重启后轮询探测是否真的就绪 |
| 5 | 接入页误写入配置 | 测试时点了"探测+写入"，真的往 `models.json` 写进第三条 | 清理配置；`--write` 保持显式确认 |

> ⚠️ **第 3 条特别值得记录**：我先用独立的最小 Swift 程序验证了**传输层没问题**（16 个增量块按 0.12s 间隔到达，首块延迟 0.00s），才确定 bug 在自己的回调代码里。**先隔离验证再改代码**，比直接猜要快得多。

### 27.3.4 交付物

| 文件 | 行数 | 作用 |
|---|---:|---|
| `ProteusStudioApp.swift` | ~150 | 应用入口、侧边栏、导航 |
| `ChatView.swift` | ~370 | 对话页：气泡流、工具条、指标 |
| `ComposerView.swift` | ~150 | 输入区：自适应高度、快捷键 |
| `SetupView.swift` | ~260 | 接入页：三步流程 |
| `ServiceView.swift` | ~240 | 服务页：状态、端点、接入片段 |
| `AppStore.swift` | ~190 | 状态中枢 |
| `ChatEngine.swift` | ~130 | 对话引擎（流式、取消、指标） |
| `GMGateway.swift` | ~150 | 网关客户端（SSE 解析） |

**构建与安装**：

```bash
cd ~/GeneralModel/GMStudio
xcodegen generate
xcodebuild -scheme ProteusStudio -configuration Release build
cp -R <build>/"Proteus Studio.app" ~/Applications/
open ~/Applications/"Proteus Studio.app"
```

---

## 27.4 本章新增的方法论铁律

在既有 26 条之外，本章新增 4 条：

| # | 铁律 | 触发它的事故 |
|---|---|---|
| 27 | **HTTP 层的连接处理与模型推理的串行化是两件事**，不要用"单线程"同时实现两者 | 网关"一次对话后自动离线" |
| 28 | **服务不该跑在 iCloud 目录里** —— launchd 进程读 iCloud `.py` 会触发 fileprovider 死锁 | `Resource deadlock avoided` 连环失败 |
| 29 | **子进程通信必须先读到 EOF 再等退出** —— 反了就是管道死锁 | GUI 频繁"未响应" |
| 30 | **后台线程不得直接改 UI 状态** —— 尤其流式回调，必须显式 hop 到主线程 | 流式输出完全不可见 |

以及一条**关于工具设计的**：

> **诚实的工具比"看起来能用"的工具更有价值。** `gm-probe` 会明确报告"该模型不支持加速"并给出数学原因，而不是硬配一个草稿让用户以为有加速。这与项目一贯的 `NO FAKE SPEEDUP` 红线一致。

---

## 27.5 投产后的项目状态

| 维度 | 状态 |
|---|---|
| **研究** | ✅ Proteus-1/2 全部结论已归档（第 1–26 章） |
| **通用性** | 🟨 有条件的普适 —— 有更小同族草稿的模型可自动加速；小模型诚实报不支持 |
| **线上服务** | ✅ `proteus-1` / `gpu-baseline` 两方案，ThreadingHTTPServer，20/20 并发可用 |
| **桌面工具** | ✅ Proteus Studio（SwiftUI，无第三方依赖） |
| **对外接口** | ✅ 标准 OpenAI 兼容，任意 agent 客户端可直接接入 |
| **可复现性** | ✅ 每处改动都有验证记录；配置改动自动备份 |

**最终一句话**：

> **Proteus 从"证明了 ANE 路线走不通、并找到投机解码这条真出路"的研究项目，落地为"一个能对多数 MLX 模型自动加速、且对不能加速的模型诚实说明原因"的可用工具。**

---
