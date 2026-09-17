import SwiftUI

// MARK: - 对话页

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ChatToolbar()
            Divider()
            TranscriptView(focused: $inputFocused)
            Divider()
            ComposerView(draft: $draft, focused: $inputFocused)
        }
    }
}

// MARK: - 顶部工具条

struct ChatToolbar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 16) {
            // ① LLM —— 加载哪个权重模型
            LLMPicker()

            Divider().frame(height: 26)

            // ② 加速方案 —— 同一权重下用哪套运行配置（与选模型正交）
            SchemePicker()

            Spacer()

            StatsStrip()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// LLM 选择器：按**权重模型**分组，而不是按网关 entry 平铺。
///
/// 原先这里是「Proteus-1 / GPU」二选一 —— 那两项其实指向同一个权重
/// （Llama-3.1-8B-Instruct-4bit），只是运行参数不同。把它们摆在「模型」
/// 位置上会让人以为背后是两个模型。现在这里只列真正的权重模型，
/// 参数差异交给旁边的 SchemePicker。
struct LLMPicker: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("模型")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            if store.weightModels.isEmpty {
                Text("未接入")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 210, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
            } else {
                Picker("", selection: Binding(
                    get: { store.selectedWeight ?? "" },
                    set: { newValue in
                        store.selectedWeightPath = newValue
                        // 换模型时清掉方案选择，让它落到新权重下的默认方案 ——
                        // 否则会残留上一个模型的 entry id，选中项不可预测。
                        store.selectedSchemeEntryID = nil
                    }
                )) {
                    ForEach(store.weightModels) { w in
                        Text(w.displayName).tag(w.path)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .disabled(store.weightModels.count <= 1)
                .help(store.weightModels.count <= 1
                      ? "当前只接入了一个权重模型"
                      : "选择要加载的权重模型")
            }
        }
    }
}

/// 加速方案选择器：当前权重下可用的运行配置。
///
/// 只显示**实质性差异**（投机是否开、nd、prefix cache、KV 位宽），
/// 因为同一权重的各方案跑的是同一批权重，参数才是唯一区别。
struct SchemePicker: View {
    @EnvironmentObject var store: AppStore

    private var schemes: [ModelEntryInfo] { store.availableSchemes }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("加速方案")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { store.selectedEntry?.id ?? "" },
                    set: { store.selectedSchemeEntryID = $0 }
                )) {
                    ForEach(schemes) { s in
                        Text(shortTitle(s)).tag(s.id)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(schemes.isEmpty)

                // 当前方案的参数详情 —— 这是「我到底在跑哪套」的唯一依据
                if let s = store.selectedEntry {
                    Text(s.schemeDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(s.isBaseline ? .tertiary : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
        }
    }

    /// entry 的短标签：已知 id 用友好名，未知的用 id 本身。
    private func shortTitle(_ s: ModelEntryInfo) -> String {
        switch s.id {
        case "gpu-baseline", "gpu", "raw": return "GPU 基线"
        case "proteus-1", "proteus1", "default": return "Proteus-1"
        default: return s.id
        }
    }
}

struct StatsStrip: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 14) {
            // 对话轮数 —— 只统计**已完成的问答对**（用户一条 + 助手一条）。
            // 正在生成中的那条不算，否则数字会在流式期间来回跳。
            MetricChip(icon: "bubble.left.and.bubble.right",
                       value: "\(store.chat.turnCount)",
                       unit: "轮")

            if store.stats.tps > 0 {
                MetricChip(icon: "speedometer", value: String(format: "%.1f", store.stats.tps),
                           unit: "tok/s")
            }
            if store.stats.ttft > 0 {
                MetricChip(icon: "bolt.fill", value: String(format: "%.2f", store.stats.ttft),
                           unit: "s TTFT")
            }
            if store.stats.speculative {
                MetricChip(icon: "wand.and.stars",
                           value: String(format: "%.1f", store.stats.acceptLen),
                           unit: "accept", tint: .accentColor)
            }
        }
        .animation(.default, value: store.stats)
        .animation(.default, value: store.chat.turnCount)
    }
}

struct MetricChip: View {
    let icon: String
    let value: String
    let unit: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 9))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - 消息流

struct TranscriptView: View {
    @EnvironmentObject var store: AppStore
    var focused: FocusState<Bool>.Binding

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // 未接入模型时，最上面放一张明确的引导卡。
                    // 这是「首次打开无配置」的正确状态：聊天页保留可用，
                    // 但明确告诉用户为什么发不出去、该去哪里配。
                    if store.needsSetup {
                        NeedsSetupBanner()
                    }

                    if store.chat.isEmpty {
                        EmptyChatView { text in
                            store.chat.send(text, model: store.selectedEntryID ?? "")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        ForEach(store.chat.messages) { m in
                            MessageRow(message: m).id(m.id)
                        }
                        if store.chat.streaming {
                            MessageRow(message: ChatMessage(
                                role: .assistant, text: store.chat.liveText),
                                streaming: true)
                                .id("live")
                        }
                        if let e = store.chat.errorText {
                            ErrorRow(text: e)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(store.chat.messages.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: store.chat.liveText) { _, _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onTapGesture { focused.wrappedValue = true }
    }
}

/// 「尚未接入模型」引导卡。
///
/// 原先的行为是：网关没有模型时，聊天页照样显示可用的输入框，用户发消息必然
/// 失败；而「接入模型」页此时是空的（本地确实没模型），两页逻辑互相矛盾。
/// 这里把状态说清楚，并给一个直接跳到接入页的按钮。
struct NeedsSetupBanner: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: store.stats.alive
                  ? "square.stack.3d.up.slash"
                  : "bolt.horizontal.circle")
                .font(.system(size: 15))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.stats.alive ? "尚未接入任何模型" : "网关未运行")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(store.stats.alive
                     ? "网关在跑，但它没有可用的模型配置。请到「接入模型」页选择本地模型目录并写入配置。"
                     : "先在终端运行 proteus startup，或到「服务」页查看状态。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if store.stats.alive {
                Button("去接入模型") { store.requestSetupTab = true }
                    .controlSize(.small)
            } else {
                Button("刷新") { Task { await store.refresh() } }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.22), lineWidth: 1)
                }
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    var streaming = false

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 60) }

            if !isUser { Avatar(role: .assistant) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser && !message.text.isEmpty {
                    Text("Proteus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Group {
                    if streaming && message.text.isEmpty {
                        TypingIndicator()
                    } else {
                        Text(message.text)
                            .font(.system(size: 13.5))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isUser ? AnyShapeStyle(LinearGradient(
                                        colors: [Color.accentColor,
                                                 Color.accentColor.opacity(0.86)],
                                        startPoint: .top, endPoint: .bottom))
                                     : AnyShapeStyle(Color.primary.opacity(0.055)))
                }
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .overlay(alignment: .bottomTrailing) {
                    if isUser {
                        CopyButton(text: message.text, onLight: true)
                            .padding(4)
                            .opacity(0.0)
                    }
                }

                // 性能脚注（仅助手）
                if !isUser, let t = message.ttft, let e = message.elapsed {
                    HStack(spacing: 8) {
                        Label(String(format: "%.2fs", t), systemImage: "bolt")
                        Label(String(format: "%.1f char/s", message.charsPerSec ?? 0),
                              systemImage: "speedometer")
                        Text(message.createdAt, style: .time)
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
                }
            }
            .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)

            if isUser { Avatar(role: .user) }
            if !isUser { Spacer(minLength: 60) }
        }
    }
}

struct Avatar: View {
    let role: ChatMessage.Role

    var body: some View {
        ZStack {
            if role == .user {
                Circle().fill(Color.primary.opacity(0.08))
                Image(systemName: "person.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Circle().fill(LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 26, height: 26)
    }
}

struct CopyButton: View {
    let text: String
    var onLight = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(onLight ? Color.white.opacity(0.9) : .secondary)
        }
        .buttonStyle(.plain)
        .help("复制")
    }
}

struct TypingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

struct ErrorRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("出错了").font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        }
    }
}

// MARK: - 空状态

struct EmptyChatView: View {
    let onPick: (String) -> Void

    private let samples = [
        ("text.alignleft", "用三句话解释什么是投机解码"),
        ("chevron.left.forwardslash.chevron.right", "写一个 Python 快排实现"),
        ("globe", "把这段话翻译成英文：今天天气很好"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.22),
                                 Color.accentColor.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 66, height: 66)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 5) {
                Text("开始对话")
                    .font(.system(size: 17, weight: .semibold))
                Text("本地模型运行，无需联网")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(samples, id: \.1) { item in
                    SampleChip(icon: item.0, text: item.1) { onPick(item.1) }
                }
            }
            .padding(.top, 4)
        }
    }
}

struct SampleChip: View {
    let icon: String
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(text).font(.system(size: 12.5))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .frame(width: 340)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.075 : 0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(hovering ? 0.12 : 0.06),
                                          lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
