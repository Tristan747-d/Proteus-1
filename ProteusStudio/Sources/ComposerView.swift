import SwiftUI

// MARK: - 输入区

struct ComposerView: View {
    @EnvironmentObject var store: AppStore
    @Binding var draft: String
    @FocusState.Binding var focused: Bool
    @State private var hoveringSend = false

    private var canSend: Bool {
        // ⚠️ 必须同时要求「已选中一个模型」。原先只检查文本非空与是否在流式，
        // 于是网关没有任何模型时输入框依然可发 —— 发出去必然失败，而用户
        // 不知道原因（见 AppStore.isConfigured 的说明）。
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 只有附件、没有文字也应可发：「看看这个文件」是常见用法。
        let hasAttach = !store.chat.pendingAttachments.isEmpty
        return store.isConfigured && (hasText || hasAttach) && !store.chat.streaming
    }

    /// 无法发送时的原因，用于占位符与提示。
    private var blockedReason: String? {
        if !store.stats.alive { return "网关未运行 —— 先在终端执行 proteus startup" }
        if !store.isConfigured { return "尚未接入模型 —— 请到「接入模型」页配置" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // 待发送的附件条
            if !store.chat.pendingAttachments.isEmpty {
                AttachmentBar()
            }

            HStack(alignment: .bottom, spacing: 10) {
                // 附件按钮
                Button(action: pickFiles) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(!store.isConfigured || store.chat.streaming)
                .help("添加附件（文本 / 代码 / PDF / docx…）")

                // 输入框：多行自适应，聚焦时描边高亮
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(blockedReason ?? "输入消息…")
                            .font(.system(size: 13.5))
                            .foregroundStyle(blockedReason == nil ? .tertiary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(.system(size: 13.5))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .focused($focused)
                        .frame(minHeight: 40, maxHeight: 130)
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(!store.isConfigured)
                        .onKeyPress(.return) {
                            if NSEvent.modifierFlags.contains(.shift) {
                                draft += "\n"
                                return .handled
                            }
                            send()
                            return .handled
                        }
                }
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(focused ? Color.accentColor.opacity(0.75)
                                                      : Color.primary.opacity(0.10),
                                              lineWidth: focused ? 1.5 : 1)
                        }
                }
                .animation(.easeOut(duration: 0.12), value: focused)

                // 发送 / 停止
                if store.chat.streaming {
                    Button {
                        store.chat.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .help("停止生成")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle().fill(canSend
                                              ? AnyShapeStyle(LinearGradient(
                                                    colors: [Color.accentColor,
                                                             Color.accentColor.opacity(0.82)],
                                                    startPoint: .top, endPoint: .bottom))
                                              : AnyShapeStyle(Color.secondary.opacity(0.35))))
                            .scaleEffect(hoveringSend && canSend ? 1.06 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .onHover { hoveringSend = $0 }
                    .animation(.spring(response: 0.22, dampingFraction: 0.7),
                               value: hoveringSend)
                    .help("发送 (⏎)")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // 底部提示行
            HStack(spacing: 12) {
                Label("⏎ 发送", systemImage: "return")
                Label("⇧⏎ 换行", systemImage: "shift")
                Spacer()
                // 温度
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 10))
                    Slider(value: Binding(
                        get: { store.chat.temperature },
                        set: { store.chat.temperature = $0 }), in: 0...1.5)
                        .frame(width: 90)
                        .controlSize(.mini)
                    Text(String(format: "%.2f", store.chat.temperature))
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .frame(width: 30, alignment: .leading)
                }
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 22)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }

    private func send() {
        guard canSend, let model = store.selectedEntryID else { return }
        let text = draft
        draft = ""
        store.chat.send(text, model: model,
                        attachments: store.chat.pendingAttachments)
    }

    /// 选择附件。读取放在后台线程 —— 大文件的 Data(contentsOf:) 是阻塞的，
    /// 在主线程做会让界面卡住（本文件顶部的 runPython 注释里记过同类事故）。
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要发送给模型的文本 / 代码 / 文档"
        panel.prompt = "添加"
        // 不硬性限制类型：用户可能想发无扩展名的文件，网关侧会做二进制探测。
        // 但把常见文本类型排在前面，方便选择。
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task.detached {
                let (ok, errs) = AttachmentLoader.loadAll(urls: urls)
                await MainActor.run {
                    store.chat.pendingAttachments.append(contentsOf: ok)
                    // 读取失败要显式告诉用户，不能静默少一个文件。
                    if !errs.isEmpty {
                        store.chat.errorText = errs.joined(separator: "\n")
                    }
                }
            }
        }
    }
}

// MARK: - 待发送附件条

/// 输入框上方的附件chips，每个可单独移除。
struct AttachmentBar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.chat.pendingAttachments) { a in
                    HStack(spacing: 6) {
                        Image(systemName: a.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text(a.sizeText)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            store.chat.pendingAttachments.removeAll { $0.id == a.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("移除")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(maxWidth: 220)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                            }
                    }
                }

                Button("全部移除") {
                    store.chat.pendingAttachments.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 10)
    }
}
