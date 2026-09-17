# Proteus-2 起点备忘

> **写于 2026-09-16**，为约一周后启动的 Proteus-2 留下干净的起点。
> 本文不是设计文档，只是**状态快照 + 已知边界 + 别再踩的坑**。

---

## 1. 当前可用状态（已验证）

| 组件 | 位置 | 状态 |
|---|---|---|
| 网关源码 | `~/GeneralModel/gm/` | ✅ 运行中 |
| 桌面应用 | `~/Applications/Proteus Studio.app` | ✅ 已安装 |
| 发布包 | `~/Proteus-Release/` | ✅ git 已初始化，1 次提交 |
| 研究记录 | `~/Proteus-Release/docs/` | ✅ 27 章完整报告 |
| iCloud 镜像 | `Corp AI/General Model/` | ✅ 与本机一致（710 文件） |

**双方案（投产配置）**：

| 名称 | 含义 | 配置 |
|---|---|---|
| `proteus-1` | 当前全部优化（最新路线） | 投机 + prefix cache + KV int8 |
| `gpu-baseline` | 研发前最原生 MLX 运行 | 三项全关 |

**实测**（M5，热态，60 token）：`proteus-1` ~32 tok/s / `gpu-baseline` ~24 tok/s。

---

## 2. 环境事实（重建时必须知道）

### 2.1 服务不能跑在 iCloud

**launchd 进程读 iCloud 目录里的 `.py` 会触发 fileprovider 死锁**（`Errno 11 Resource deadlock avoided`）。终端里跑同一份代码正常。

- 实测：同一个包，`/tmp` 下可导入，iCloud 下报 EDEADLK
- 因此源码放在 `~/GeneralModel/`（本地），iCloud 只作镜像
- 同类摩擦：工作台.app 构建时 `SYMROOT` 必须指到 iCloud 外

### 2.2 网关的 Python 必须是 3.11

系统 Python 3.14 的 coremltools **缺 `libcoremlpython` 原生库**，加载 `.mlpackage` 时报：

```
Unable to load libmodelpackage. Cannot make save spec.
```

本机网关用的是 ANEProbe 实验台里的 3.11 venv（coremltools 9.0 + mlx-lm）；路径见 launchd plist。

> 如果 Proteus-2 不碰 CoreML，用哪个 Python 都行；一旦要加载 CoreML 模型，必须是 3.11。

### 2.3 本机 quirk

- **没有 `timeout` 命令**（写脚本时用别的方式限时）
- 无风扇 M5，热态漂移可达 50%+，顺序扫描不可信

---

## 3. 已知边界（别再撞一次）

### 3.1 ANE 路线：关闭

| 结论 | 依据 |
|---|---|
| `DIRECT_ANE_STATUS = PERFORMANCE DEAD END` | 0/34 配置 ANE 胜；权重流 ~20 GB/s vs GPU ~100 |
| 卸载在 decode 上**零和** | ane/dram = 0.906，结构化必然净损 |
| 障碍**不在硬件** | per-channel 在 ANE 上工作良好 → 编译器 + 带宽 + 算力三重限制 |
| 唯一重启条件 | Apple 提供**单 op 的 4-bit 分组 dequant 权重操作数** |

**已彻底移除**：`proteus1_backend.py`、`models.json` 条目、30GB 的 `int4_*` CoreML 图。

### 3.2 投机解码：有数学边界

```
收益 = 接受长度 / (1 + c),   c = 草稿时间 / 目标时间    必须 c < 1
```

- **8B 以上**：有同族小草稿 → 可加速
- **小模型（0.5B–3B）**：没有更小草稿 → `c ≥ 1` → **必然更慢**
- `gm-probe` 会诚实报告这一点，不硬配草稿

**n_draft 无法可靠测量**：四次独立扫描给出四个不同最优值（2/2/1/3），逐 nd 比值跨度最高 0.190。工具已加可信度分级（`LOW` 时报并列区间）。真正稳定的信号是 `accept_len`。

### 3.3 三条已封死的路

1. ANE 直连 / 权重补零
2. 3-bit / 2-bit 量化（权重 rel_rmse 崩到 0.22 / 0.41）
3. 用草稿量化压 c

---

## 4. 方法论铁律（30 条，最常用的几条）

| # | 铁律 |
|---|---|
| 1 | **单 campaign 的 speedup 不足以下结论** —— 必须 ≥2 轮独立 campaign 并报 range |
| 2 | **每配置必须独立进程** —— 同进程交替污染可达 2.75× |
| 3 | **burst probe 不能当门禁** —— 会给出假阴性 |
| 4 | **顺序扫描若测项本身会致热，必须交错 + 冷却** |
| 5 | **形状覆盖必须对维度本身正交** —— 否则把局部伪影当全局常数 |
| 6 | **HTTP 层连接处理与模型推理串行化是两件事** —— 别用"单线程"同时实现 |
| 7 | **服务不该跑在 iCloud 目录里** |
| 8 | **子进程通信必须先读到 EOF 再等退出** —— 反了就是管道死锁 |
| 9 | **后台线程不得直接改 UI 状态** —— 流式回调必须 hop 主线程 |
| 10 | **诚实的工具比"看起来能用"的工具更有价值** |

完整 30 条见研究报告 §21 与 §27.4。

---

## 5. 一周后的清理清单

启动 Proteus-2 前，建议先做：

- [ ] **决定 GUI 是否要视觉验证** —— 目前只做了编译与进程存活验证，**没有实际截图确认版式**
- [ ] **确认环境可复现** —— 在另一台 Apple Silicon 机器上跑 `./install.sh`，验证发布包
- [ ] **决定是否上传 GitHub** —— 发布包已就绪（MIT + NOTICE 完整），但需要你确认仓库名与可见性
- [ ] **清理 `~/GeneralModel/_archive/`** —— 目前存着 tkinter GUI 与旧配置，可保留可删
- [ ] **确认 Proteus-2 的方向** —— 现有边界显示：瓶颈是内存带宽（硬件常数），所以下一阶段的合理问题是「**能不能让同精度下需要流过的字节变少**」，而不是「怎么把 kernel 写得更快」

---

## 6. 一句话交接

> **Proteus-1 已经把「哪些路走不通」测绘完毕（11 条路线 + 30 条方法论），并把「哪条路走得通」落地成可用的工具（投机解码 + Proteus Studio）。Proteus-2 的起点不是空白，而是一张完整的边界图。**

起点文件：`~/Proteus-Release/`（源码 + 文档 + LICENSE + NOTICE）
完整记录：`~/Proteus-Release/docs/Proteus_全集技术报告.md`（27 章）
