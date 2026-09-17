import SwiftUI

// MARK: - 服务 / 接入页

struct ServiceView: View {
    @EnvironmentObject var store: AppStore
    @State private var copied: String?

    // 跟随 models.json 的 server.port，不写死。
    private var base: String { store.gateway.baseURLString }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                portCard
                endpointsCard
                clientCard
                limitsCard
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { await store.refresh() }
    }

    // MARK: 端口

    /// 端口卡片：显示当前端口与来源，并允许就地修改。
    ///
    /// 端口是 models.json 的 server.port，是**唯一真相源**。界面不另存一份，
    /// 所以这里显示的就是网关真正会用的值 —— 不会出现「界面说 9000、网关在
    /// 8320」的分叉。
    private var portCard: some View {
        Card(title: "端口", step: "⇄") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("\(store.configuredPort)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(store.stats.alive ? "监听中" : "未监听")
                        .font(.system(size: 11))
                        .foregroundStyle(store.stats.alive ? Color.green : .secondary)
                    Spacer()
                    Button(store.portEditing ? "取消" : "修改端口") {
                        store.portEditing.toggle()
                        store.portMessage = nil
                    }
                    .controlSize(.small)
                }

                // 来源：让用户知道改的是哪个文件（多份安装时尤其重要）
                if let p = store.configPath {
                    Text("来自 \(p.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if store.portEditing {
                    PortEditor()
                }

                if let msg = store.portMessage {
                    let bad = msg.contains("失败") || msg.contains("不可写")
                        || msg.contains("找不到") || msg.contains("需在")
                    HStack(spacing: 7) {
                        Image(systemName: bad ? "exclamationmark.triangle.fill"
                                              : "info.circle.fill")
                        Text(msg).font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .foregroundStyle(bad ? Color.orange : .secondary)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    }
                } else {
                    Text("端口写在 models.json 的 server.port。"
                         + "改动后需重启网关才会生效 —— 网关进程持有的是旧端口。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 状态

    private var statusCard: some View {
        Card(title: "网关状态", step: "●") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.stats.alive ? Color.green : Color.red)
                        .frame(width: 9, height: 9)
                    Text(store.stats.alive ? "运行中" : "未运行")
                        .font(.system(size: 13, weight: .semibold))
                    Text("已运行 \(Int(store.stats.uptime / 60)) 分钟")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    Button {
                        Task { await store.restartGateway() }
                    } label: {
                        HStack(spacing: 5) {
                            if store.restarting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "power")
                            }
                            Text(store.restarting ? "重启中…" : "重启网关")
                        }
                    }
                    .controlSize(.small)
                    .disabled(store.restarting)
                }

                if let msg = store.restartMessage {
                    HStack(spacing: 7) {
                        Image(systemName: msg.contains("失败") || msg.contains("尚未")
                              ? "exclamationmark.triangle.fill"
                              : "info.circle.fill")
                        Text(msg).font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundStyle(msg.contains("失败") || msg.contains("尚未")
                                     ? Color.orange : Color.secondary)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    }
                }

                HStack(spacing: 8) {
                    Text(base + "/v1")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        }
                    Button {
                        copy(base + "/v1", tag: "base")
                    } label: {
                        Label(copied == "base" ? "已复制" : "复制",
                              systemImage: copied == "base" ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                    Spacer()
                }

                if !store.stats.loadedModels.isEmpty {
                    HStack(spacing: 6) {
                        Text("当前驻留")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        ForEach(store.stats.loadedModels, id: \.self) { m in
                            Text(m)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: 端点

    private var endpointsCard: some View {
        Card(title: "可用端点", step: "→") {
            VStack(spacing: 0) {
                endpoint("POST", "/v1/chat/completions", "对话（stream 支持）")
                Divider().padding(.leading, 52)
                endpoint("POST", "/v1/completions", "原始补全")
                Divider().padding(.leading, 52)
                endpoint("GET", "/v1/models", "模型列表")
                Divider().padding(.leading, 52)
                endpoint("GET", "/stats", "运行指标（TTFT / TPOT / 接受率）")
            }
        }
    }

    private func endpoint(_ method: String, _ path: String, _ desc: String) -> some View {
        HStack(spacing: 12) {
            Text(method)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(method == "GET" ? Color.blue : Color.green)
                .frame(width: 40, alignment: .leading)
            Text(path)
                .font(.system(size: 11.5, design: .monospaced))
            Spacer()
            Text(desc)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    // MARK: 客户端接入

    private var clientCard: some View {
        Card(title: "其他 agent 客户端如何接入", step: "⌘") {
            VStack(alignment: .leading, spacing: 12) {
                Text("网关是标准 OpenAI 兼容端点。任何支持自定义 base_url 的客户端都能直接接入，无需改动。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                snippet("环境变量",
                        "OPENAI_BASE_URL=\(base)/v1\nOPENAI_API_KEY=local\nOPENAI_MODEL=default")
                snippet("Python (openai SDK)",
                        "from openai import OpenAI\nc = OpenAI(base_url=\"\(base)/v1\", api_key=\"local\")\nc.chat.completions.create(model=\"default\", messages=[...])")

                Button {
                    copy("OPENAI_BASE_URL=\(base)/v1", tag: "env")
                } label: {
                    Label(copied == "env" ? "已复制配置片段" : "复制配置片段",
                          systemImage: copied == "env" ? "checkmark" : "doc.on.clipboard")
                }
                .controlSize(.small)
            }
        }
    }

    private func snippet(_ title: String, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
        }
    }

    // MARK: 限制

    private var limitsCard: some View {
        Card(title: "当前限制", step: "!") {
            VStack(alignment: .leading, spacing: 8) {
                limitRow("只监听 127.0.0.1", "仅本机可访问。局域网接入需把 models.json 的 server.host 改为 0.0.0.0")
                limitRow("不校验 API key", "任何 key 都接受（本机使用可接受）")
                limitRow("生成串行", "mlx_lm 单模型推理有 gen_lock，多客户端会排队而非并行")
            }
        }
    }

    private func limitRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ s: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copied == tag { copied = nil }
        }
    }
}

// MARK: - 端口编辑

/// 端口编辑行：输入 + 保存 + 保存后的一键重启。
///
/// 为什么保存后要单独给一个「重启网关」按钮，而不是自动重启：改端口会让
/// 正在进行的请求中断。自动重启等于替用户做了「现在可以断」的决定 —
/// 生成到一半的对话会突然失败。所以让重启成为一个显式动作。
struct PortEditor: View {
    @EnvironmentObject var store: AppStore
    @State private var draft = ""
    @State private var saving = false
    /// 是否刚刚保存过一个**当前进程还未使用**的新端口 —— 决定要不要提示重启。
    @State private var savedPendingRestart = false

    private var parsed: Int? { Int(draft.trimmingCharacters(in: .whitespaces)) }
    private var valid: Bool { (parsed.map { (1024...65535).contains($0) }) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("端口", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 100)
                    .onSubmit { save() }
                Text("1024–65535")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    save()
                } label: {
                    HStack(spacing: 5) {
                        if saving { ProgressView().controlSize(.mini) }
                        Text("保存")
                    }
                }
                .controlSize(.small)
                .disabled(!valid || saving || parsed == store.configuredPort)

                if savedPendingRestart {
                    Button {
                        Task {
                            await store.restartGateway()
                            savedPendingRestart = false
                        }
                    } label: {
                        Label("重启网关以生效", systemImage: "power")
                    }
                    .controlSize(.small)
                    .disabled(store.restarting)
                }
            }

            if !draft.isEmpty && !valid {
                Text("端口必须是 1024–65535 的整数")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { draft = "\(store.configuredPort)" }
    }

    private func save() {
        guard let p = parsed, valid else { return }
        let old = store.configuredPort      // 保存前先记住
        saving = true
        Task {
            let ok = await store.setPort(p)
            saving = false
            // 只有真的改了端口才提示重启（值相同或写失败时不必打扰）。
            savedPendingRestart = ok && p != old
            await store.refresh()
        }
    }
}
