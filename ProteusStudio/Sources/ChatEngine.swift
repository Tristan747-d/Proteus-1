import Foundation
import SwiftUI

/// 一个待发送的附件。
///
/// 只保留展示所需的元信息，原始数据以 base64 随请求发出 —— 文本提取在
/// **网关侧**做（见 gm/attachments.py），这样其他 OpenAI 兼容客户端也能
/// 享受同一套支持，而不只是本应用。
struct ChatAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let byteCount: Int
    let base64: String

    /// 人类可读的大小。
    var sizeText: String {
        if byteCount < 1024 { return "\(byteCount) B" }
        let kb = Double(byteCount) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    /// 图标（按类型给个直观提示）。
    var icon: String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "docx", "doc", "rtf", "odt": return "doc.text"
        case "csv", "tsv", "xlsx": return "tablecells"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "md", "markdown", "txt": return "text.alignleft"
        case "swift", "py", "js", "ts", "c", "cpp", "h", "go", "rs", "java":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// 对话引擎 —— 管理消息列表、流式接收、性能指标。
@MainActor
final class ChatEngine: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var streaming = false
    @Published var liveText = ""
    @Published var errorText: String?
    @Published var temperature: Double = 0.7
    @Published var lastTTFT: Double = 0
    /// 待发送的附件（发送后清空）。
    @Published var pendingAttachments: [ChatAttachment] = []
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
        pendingAttachments = []
        sessionID = UUID().uuidString
    }

    func stop() {
        cancelled = true
        task?.cancel()
        task = nil
        streaming = false
    }

    /// 发送一条消息。`attachments` 会作为 content parts 的 file 项附带。
    func send(_ text: String, model: String,
              attachments: [ChatAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只有附件、没有文字，也应该能发出去（「看看这个文件」是常见用法）。
        guard !trimmed.isEmpty || !attachments.isEmpty, !streaming else { return }

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
        messages.append(ChatMessage(role: .user, text: trimmed,
                                    attachmentNames: attachments.map(\.name)))
        liveText = ""
        streaming = true
        cancelled = false
        lastTTFT = 0
        lastTPS = 0

        // 构造发给网关的消息序列（[[String: Any]]，因为 content 可以是
        // 字符串或 content parts 数组）。
        //
        // 附件只挂在**最后一条**用户消息上：历史消息里若重复附带同一份
        // 文件，prompt 会随轮数线性膨胀，很快撑爆上下文。
        var payload: [[String: Any]] = messages
            .filter { $0.role != .system }
            .map { m -> [String: Any] in
                ["role": m.role == .user ? "user" : "assistant",
                 "content": m.text]
            }

        if !attachments.isEmpty {
            var parts: [[String: Any]] = []
            if !trimmed.isEmpty {
                parts.append(["type": "text", "text": trimmed])
            }
            for a in attachments {
                parts.append([
                    "type": "file",
                    "file": ["name": a.name, "data": a.base64],
                ])
            }
            if let last = payload.indices.last,
               payload[last]["role"] as? String == "user" {
                payload[last]["content"] = parts
            }
        }

        // 附件已进入 payload，清空待发列表，避免下一条消息被重复附带
        // （那会让 prompt 随轮数线性膨胀）。
        pendingAttachments = []

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
                            hint = "无法连接网关（\(GatewayLocator.displayAddress())）。"
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

/// 附件的读取与限额（GUI 侧）。
///
/// 与网关侧的限额保持一致（gm/attachments.py）。GUI 这里先拦一道，是为了
/// 在用户选文件的当下就给出反馈，而不是等请求跑完才报错 —— 尤其是要读
/// 几十 MB 的文件时。
enum AttachmentLoader {
    /// 与网关 gm/attachments.py MAX_FILE_BYTES 对齐。
    static let maxBytes = 20 * 1024 * 1024
    /// 一次最多几个附件（防止误选整个目录）。
    static let maxCount = 8

    enum LoadError: LocalizedError {
        case tooLarge(String, Int)
        case tooMany(Int)
        case unreadable(String, String)
        case binary(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let n, let mb):
                return "「\(n)」超过 \(mb) MB 上限"
            case .tooMany(let n):
                return "一次最多 \(n) 个附件"
            case .unreadable(let n, let why):
                return "无法读取「\(n)」：\(why)"
            case .binary(let n):
                return "「\(n)」是二进制文件，无法作为文本发送（图片请改用支持视觉的模型）"
            }
        }
    }

    /// 读取一个文件为可发送的附件。
    static func load(url: URL) throws -> ChatAttachment {
        let name = url.lastPathComponent
        // 目录会被 NSOpenPanel 挡掉，但拖放可能带进来
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            throw LoadError.unreadable(name, "不是普通文件")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes {
            throw LoadError.tooLarge(name, maxBytes / 1048576)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(name, error.localizedDescription)
        }
        return ChatAttachment(name: name, byteCount: data.count,
                              base64: data.base64EncodedString())
    }

    /// 批量读取，返回成功项与失败原因（失败不阻断其它文件）。
    static func loadAll(urls: [URL]) -> ([ChatAttachment], [String]) {
        var ok: [ChatAttachment] = []
        var errs: [String] = []
        for (i, u) in urls.enumerated() {
            if i >= maxCount {
                errs.append(LoadError.tooMany(maxCount).errorDescription ?? "")
                break
            }
            do {
                ok.append(try load(url: u))
            } catch {
                errs.append(error.localizedDescription)
            }
        }
        return (ok, errs)
    }

    /// 文件选择面板允许的类型（文本类为主；网关侧做真正的提取）。
    static let allowedExtensions: [String] = [
        "txt", "md", "markdown", "rst", "log",
        "py", "js", "ts", "tsx", "jsx", "swift", "c", "h", "cpp", "hpp",
        "m", "mm", "java", "kt", "go", "rs", "rb", "php", "sh", "zsh", "bash",
        "sql", "r", "jl", "lua", "pl", "scala", "clj", "hs", "ml", "ex",
        "html", "htm", "xml", "css", "scss", "less", "svg",
        "json", "jsonl", "yaml", "yml", "toml", "csv", "tsv", "ini", "cfg",
        "conf", "tex", "env",
        "pdf", "docx", "doc", "rtf", "odt",
    ]
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
