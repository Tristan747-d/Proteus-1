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
        HStack(spacing: 14) {
            // 加速方案选择器 —— 分段控件，一眼看出当前跑哪套
            VStack(alignment: .leading, spacing: 3) {
                Text("加速方案")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $store.selectedScheme) {
                    ForEach(store.schemes) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }

            // 方案说明
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let b = store.selectedScheme.badge {
                        Text(b)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(store.selectedScheme.isBaseline
                                               ? Color.secondary.opacity(0.15)
                                               : Color.accentColor.opacity(0.15)))
                            .foregroundStyle(store.selectedScheme.isBaseline
                                             ? .secondary : Color.accentColor)
                    }
                    Text(store.selectedScheme.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if store.selectedScheme.isBaseline {
                    Text("基线会明显慢于 Proteus-1，这是预期结果")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // 实时指标
            StatsStrip()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct StatsStrip: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 14) {
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
                    if store.chat.isEmpty {
                        EmptyChatView { text in
                            store.chat.send(text, model: store.selectedScheme.id)
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
