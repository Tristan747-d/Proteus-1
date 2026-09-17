import SwiftUI

// MARK: - 输入区

struct ComposerView: View {
    @EnvironmentObject var store: AppStore
    @Binding var draft: String
    @FocusState.Binding var focused: Bool
    @State private var hoveringSend = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.chat.streaming
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                // 输入框：多行自适应，聚焦时描边高亮
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("输入消息…")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.tertiary)
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
        guard canSend else { return }
        let text = draft
        draft = ""
        store.chat.send(text, model: store.selectedScheme.id)
    }
}
