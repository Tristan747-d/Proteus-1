import Foundation
import SwiftUI

/// 对话引擎 —— 管理消息列表、流式接收、性能指标。
@MainActor
final class ChatEngine: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var streaming = false
    @Published var liveText = ""
    @Published var errorText: String?
    @Published var temperature: Double = 0.7
    @Published var lastTTFT: Double = 0
    @Published var lastTPS: Double = 0

    private var task: Task<Void, Never>?
    private var cancelled = false
    private var sessionID = UUID().uuidString
    private let gateway = GMGateway()

    var isEmpty: Bool { messages.isEmpty && liveText.isEmpty }

    /// 已完成的对话轮数。
    ///
    /// 定义：一个「用户提问 + 助手回答」算一轮，只数**已落库**的助手消息。
    /// 正在流式生成的那条不计入 —— 否则数字会在生成期间提前 +1，看起来像
    /// 统计错了。被用户中断的（"（已停止）"）也算一轮，因为它确实发生了。
    ///
    /// 用 assistant 消息数而不是 messages.count/2：后者在用户消息已入库、
    /// 助手还没回时会算出小数般的偏差，且中断、出错等情况都会失真。
    var turnCount: Int {
        messages.reduce(0) { acc, m in
            m.role == .assistant ? acc + 1 : acc
        }
    }

    func reset() {
        stop()
        messages = []
        liveText = ""
        errorText = nil
        lastTTFT = 0
        lastTPS = 0
        sessionID = UUID().uuidString
    }

    func stop() {
        cancelled = true
        task?.cancel()
        task = nil
        streaming = false
    }

    func send(_ text: String, model: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !streaming else { return }

        // ⚠️ 实质性拦截，而不只是把按钮变灰。
        // 按钮禁用是 UI 层的礼貌，不能当作唯一防线：快捷键、菜单项、
        // 代码路径都可能绕过它。没有模型 id 就绝不该发出请求 —— 那会往
        // messages 里塞一条用户消息、再以失败告终，留下一段无法继续的
        // 假对话。这里直接拒绝并给出可操作的原因。
        guard !model.isEmpty else {
            errorText = "尚未接入模型：网关没有可用的模型配置。"
                + "请到「接入模型」页选择本地模型目录并写入配置。"
            return
        }

        errorText = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        liveText = ""
        streaming = true
        cancelled = false
        lastTTFT = 0
        lastTPS = 0

        // 构造发给网关的消息序列
        var payload: [[String: String]] = messages
            .filter { $0.role != .system }
            .map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] }

        let temp = temperature
        let sess = sessionID
        let t0 = Date()

        // ⚠️ 并发要点（第一版在这里出错，表现为"流式完全没有输出"）：
        //   · 流式回调是在非主线程上同步调用的，直接碰 @Published 会违反
        //     主线程约束（Swift 6 下是数据竞争）；
        //   · firstDelta 若用捕获的可变 var，会被多条并发路径同时写。
        // 做法：把「首次到达时间」放进一个带锁的盒子，UI 更新统一跳主线程。
        let clock = FirstDeltaClock(start: t0)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let full = try await gateway.stream(
                    model: model,
                    messages: payload,
                    temperature: temp,
                    maxTokens: 2048,
                    session: sess,
                    stop: { [weak self] in
                        guard let self else { return true }
                        return self.cancelled
                    },
                    onDelta: { piece in
                        // 这一段在后台线程同步执行 —— 只做线程安全的记录，
                        // 然后 hop 到主线程改 @Published。
                        let ttft = clock.markIfFirst()
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let ttft { self.lastTTFT = ttft }
                            self.liveText += piece
                        }
                    }
                )
                let elapsed = Date().timeIntervalSince(t0)
                let ttft = clock.value
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !full.isEmpty {
                        let msg = ChatMessage(
                            role: .assistant, text: full,
                            ttft: ttft, elapsed: elapsed,
                            charsPerSec: elapsed > 0 ? Double(full.count) / elapsed : 0)
                        self.messages.append(msg)
                        self.lastTPS = msg.charsPerSec ?? 0
                    } else if self.cancelled {
                        self.messages.append(ChatMessage(role: .assistant, text: "（已停止）"))
                    }
                    self.liveText = ""
                    self.streaming = false
                }
            } catch {
                let desc = error.localizedDescription
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // 把底层网络错误翻译成可操作的话。原文形如
                    // "Could not connect to the server."（NSURLError -1004），
                    // 对用户没有指向性 —— 真正该做的是启动网关。
                    let hint: String
                    let ns = error as NSError
                    if ns.domain == NSURLErrorDomain {
                        switch ns.code {
                        case NSURLErrorCannotConnectToHost,
                             NSURLErrorNetworkConnectionLost,
                             NSURLErrorTimedOut:
                            hint = "无法连接网关（127.0.0.1:8320）。"
                                + "请在终端运行 proteus startup，或用「网关 → 重启网关」。"
                        default:
                            hint = desc
                        }
                    } else {
                        hint = desc
                    }
                    self.errorText = hint
                    self.streaming = false
                    self.liveText = ""
                }
            }
        }
    }
}

/// 线程安全的「首个增量到达时间」记录盒。
private final class FirstDeltaClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var first: Double?

    init(start: Date) { self.start = start }

    /// 首次调用返回耗时，之后返回 nil。
    func markIfFirst() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard first == nil else { return nil }
        let d = Date().timeIntervalSince(start)
        first = d
        return d
    }

    var value: Double? {
        lock.lock(); defer { lock.unlock() }
        return first
    }
}
