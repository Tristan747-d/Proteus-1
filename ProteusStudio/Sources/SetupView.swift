import SwiftUI

// MARK: - 接入模型页

struct SetupView: View {
    @EnvironmentObject var store: AppStore
    @State private var path = ""
    @State private var name = ""
    @State private var report = ""
    @State private var verdict = ""
    @State private var verdictKind: Kind = .none
    @State private var running = false
    @State private var writeEnabled = false

    enum Kind { case none, good, warn, bad }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 状态总览：让「接入模型」页自己说清楚当前到底有没有模型。
                // 原先这页不显示任何当前状态，本地又没模型时整页看起来是空的，
                // 与聊天页声称「有 Proteus-1 / GPU 可选」直接矛盾。
                StatusCard()

                // 步骤 1
                Card(title: "选择模型目录", step: "1") {
                    VStack(alignment: .leading, spacing: 10) {
                        if store.setup.candidates.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                                Text("未在 ~/Models 或 HuggingFace 缓存中发现模型。"
                                     + "请手动选择目录，或先用 mlx_lm 下载一个。")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.045))
                            }
                        }
                        HStack(spacing: 8) {
                            TextField("/path/to/model", text: $path)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button("浏览…") { pick() }
                                .controlSize(.regular)
                        }
                        if !store.setup.candidates.isEmpty {
                            Picker("本地已发现", selection: $path) {
                                Text("（选择）").tag("")
                                ForEach(store.setup.candidates, id: \.self) { c in
                                    Text(shortPath(c)).tag(c)
                                }
                            }
                            .onChange(of: path) { _, v in
                                if name.isEmpty {
                                    name = URL(fileURLWithPath: v).lastPathComponent
                                }
                            }
                        }
                        Text("探测阶段只读，不会修改任何配置文件。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                // 步骤 2
                Card(title: "探测与配置", step: "2") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button {
                                probe()
                            } label: {
                                HStack(spacing: 6) {
                                    if running {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "magnifyingglass")
                                    }
                                    Text(running ? "探测中…" : "探测（只读）")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(running || path.isEmpty)

                            TextField("模型名", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)

                            Spacer()

                            Button("写入配置") { write() }
                                .buttonStyle(.bordered)
                                .disabled(!writeEnabled)
                        }

                        if !verdict.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: kindIcon)
                                    .foregroundStyle(kindColor)
                                Text(verdict)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(kindColor)
                                Spacer()
                            }
                            .padding(10)
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(kindColor.opacity(0.10))
                            }
                        }
                    }
                }

                // 步骤 3
                Card(title: "结果", step: "3") {
                    ScrollView {
                        Text(report.isEmpty ? "尚未探测" : report)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(minHeight: 220)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { store.setup.scanLocal() }
    }

    private var kindIcon: String {
        switch verdictKind {
        case .good: return "checkmark.seal.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .none: return "info.circle"
        }
    }
    private var kindColor: Color {
        switch verdictKind {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .none: return .secondary
        }
    }

    private func shortPath(_ p: String) -> String {
        p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.message = "选择模型目录（需含 config.json）"
        if p.runModal() == .OK, let u = p.url {
            path = u.path
            if name.isEmpty { name = u.lastPathComponent }
        }
    }

    // 调 Python 的 gm-probe（复用已有 CLI，不重复实现探测逻辑）
    private func probe() {
        running = true
        writeEnabled = false
        report = ""
        verdict = "正在探测…"
        verdictKind = .none

        let args = ["-m", "gm.probe_cli", path]
        let root = store.gatewayRoot
        Task.detached {
            let out = runPython(args, cwd: root)
            await MainActor.run {
                running = false
                report = out.text
                let t = out.text
                if t.contains("推荐配置") {
                    verdict = "支持加速 —— 已找到可用的同族草稿"
                    verdictKind = .good
                    writeEnabled = true
                } else if t.contains("不支持投机解码加速") {
                    verdict = "不支持投机加速（详见下方原因）"
                    verdictKind = .bad
                } else if t.contains("尚未下载") {
                    verdict = "需先下载同族草稿模型"
                    verdictKind = .warn
                } else {
                    verdict = "探测完成"
                    verdictKind = .warn
                }
            }
        }
    }

    private func write() {
        let root = store.gatewayRoot
        let n = name.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : name
        let out = runPython(["-m", "gm.probe_cli", path, "--write", "--name", n],
                            cwd: root)
        report += "\n\n" + out.text

        // 判定要用**退出码**，不能只看文本里有没有「已写入」。
        // 旧实现在失败时（例如 models.json 归 root 所有、不可写）留下的是
        // 一句 stderr 警告，界面只笼统显示「写入失败」而不知道原因，用户
        // 也无从下手。现在把 CLI 给出的可操作提示直接转述出来。
        if out.code == 0, out.text.contains("已写入") {
            verdict = "已写入配置"
            verdictKind = .good
        } else if out.text.contains("不可写") {
            verdict = "写入失败：配置文件不可写（可能是 root 所有）—— 详见下方"
            verdictKind = .bad
        } else if out.text.contains("不支持投机解码加速") {
            verdict = "未写入：该模型不支持投机加速（详见下方原因）"
            verdictKind = .bad
        } else {
            verdict = "写入失败（退出码 \(out.code)）—— 详见下方输出"
            verdictKind = .bad
        }
        Task { await store.refresh() }
    }
}

/// 同步跑 python（在后台线程调用）。
struct ProcResult { let text: String; let code: Int32 }

/// 同步跑 python。
///
/// ⚠️ 必须**先读管道再等退出**：python 输出超过管道缓冲区（64KB）时，
/// 子进程会阻塞在 write 上，而父进程若先 waitUntilExit 就永远等不到 ——
/// 经典管道死锁，表现为「程序未响应」。这里先 readDataToEndOfFile（它会
/// 读到 EOF 才返回，此时子进程已写完），再 waitUntilExit。
///
/// 另外：本函数本身是阻塞的，调用方必须在后台线程里跑。
///
/// ⚠️ 解释器必须与网关**同一个**。原先写死 `/usr/bin/env python3`，在 PATH
/// 里解析到的是系统 Python（本机 3.14），而 mlx_lm 装在网关的 venv 里 ——
/// 于是探测要么 import 失败、要么行为与网关不一致。这里按优先级找第一个
/// 真能 `import mlx_lm` 的解释器；找不到就退回 `/usr/bin/env python3`，
/// 让调用方从输出里看到 import 错误，而不是静默拿到错误结果。
func resolveProbePython() -> String {
    let fm = FileManager.default
    var candidates: [String] = []
    // 1) 网关服务实际用的解释器（launchd plist 是权威来源）
    let plist = NSHomeDirectory() + "/Library/LaunchAgents/com.tristan.gm.gateway.plist"
    if let d = fm.contents(atPath: plist),
       let s = String(data: d, encoding: .utf8) {
        // 取 <array> 里第一个 <string>，即 ProgramArguments[0]
        let parts = s.components(separatedBy: "<string>")
        if parts.count > 1 {
            let v = parts[1].components(separatedBy: "</string>")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("/") { candidates.append(v) }
        }
    }
    // 2) 常见 venv 位置
    let home = NSHomeDirectory()
    candidates.append(home + "/Proteus-Release/.venv/bin/python")
    candidates.append(home + "/GeneralModel/.venv/bin/python")
    candidates.append(home + "/ANEProbe/P6Model/phase4/.venv/bin/python")
    // 3) PATH 上的 python3
    candidates.append("/usr/bin/env")

    for c in candidates {
        if c == "/usr/bin/env" { return c }
        if fm.isExecutableFile(atPath: c) { return c }
    }
    return "/usr/bin/env python3"
}

func runPython(_ args: [String], cwd: String) -> ProcResult {
    let p = Process()
    let py = resolveProbePython()
    if py == "/usr/bin/env" {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3"] + args
    } else {
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = args
    }
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch {
        return ProcResult(text: "启动失败：\(error)", code: -1)
    }
    // 先读完（EOF 即子进程写完/退出），再 wait
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ProcResult(text: String(data: data, encoding: .utf8) ?? "",
                      code: p.terminationStatus)
}

// MARK: - 通用卡片

/// 「接入模型」页顶部的当前状态卡。
struct StatusCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("刷新") { Task { await store.refresh() } }
                .controlSize(.small)
        }
        .padding(13)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint.opacity(0.09))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                }
        }
    }

    private var icon: String {
        if !store.stats.alive { return "bolt.horizontal.circle" }
        return store.isConfigured ? "checkmark.seal.fill" : "square.stack.3d.up.slash"
    }
    private var tint: Color {
        if !store.stats.alive { return .orange }
        return store.isConfigured ? .green : .orange
    }
    private var title: String {
        if !store.stats.alive { return "网关未运行" }
        let n = store.weightModels.count
        return store.isConfigured
            ? "已接入 \(n) 个模型"
            : "尚未接入任何模型"
    }
    private var detail: String {
        if !store.stats.alive {
            return "在终端运行 proteus startup，或用菜单「网关 → 重启网关」。"
        }
        if store.isConfigured {
            // 按权重模型列，并注明每个权重下有几套运行配置 —— 这两件事
            // 是正交的，混在一起说会让人以为装了多个模型。
            let parts = store.weightModels.map { w -> String in
                let n = store.entries.filter { $0.weight == w.path }.count
                return n > 1 ? "\(w.displayName)（\(n) 套配置）" : w.displayName
            }
            return "可用：" + parts.joined(separator: "、")
                + "。可继续在下方探测并写入新的模型。"
        }
        return "网关在线但没有模型配置。在下方选择本地模型目录，探测通过后写入配置即可。"
    }
}

struct Card<Content: View>: View {
    let title: String
    let step: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text(step)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(Color.accentColor))
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
            }
            content
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
    }
}
