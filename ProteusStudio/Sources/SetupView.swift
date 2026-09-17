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
                // 步骤 1
                Card(title: "选择模型目录", step: "1") {
                    VStack(alignment: .leading, spacing: 10) {
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
        let root = NSHomeDirectory() + "/GeneralModel"
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
        let root = NSHomeDirectory() + "/GeneralModel"
        let n = name.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : name
        let out = runPython(["-m", "gm.probe_cli", path, "--write", "--name", n],
                            cwd: root)
        report += "\n\n" + out.text
        verdict = out.text.contains("已写入") ? "已写入配置" : "写入失败"
        verdictKind = out.text.contains("已写入") ? .good : .bad
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
func runPython(_ args: [String], cwd: String) -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3"] + args
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
