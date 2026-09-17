import Foundation
import SwiftUI
import Combine

// MARK: - 数据模型

/// 一个可选的加速方案。对应 models.json 里的一条 model 条目。
struct Scheme: Identifiable, Hashable {
    let id: String          // 模型名（发给网关的 model 字段）
    let title: String       // 显示名
    let detail: String      // 说明
    let badge: String?      // 角标，如 "最新"
    let isBaseline: Bool
}

/// 一条对话消息。
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: Role
    var text: String
    var createdAt = Date()
    var ttft: Double?
    var elapsed: Double?
    var charsPerSec: Double?

    enum Role { case user, assistant, system }
}

/// 网关的运行指标。
struct GatewayStats: Equatable {
    var alive = false
    var loadedModels: [String] = []
    var tps: Double = 0
    var ttft: Double = 0
    var tpot: Double = 0
    var speculative = false
    var acceptRule = ""
    var numDraft = 0
    var acceptLen: Double = 0
    var prefixCached = 0
    var uptime: Double = 0
}

// MARK: - AppStore

@MainActor
final class AppStore: ObservableObject {
    // 方案定义 —— **不再是硬编码列表**，而是从网关的 /v1/models 动态构建。
    //
    // 为什么改（用户报障）：原先把两条 scheme 写死在代码里，而 refresh() 拿到
    // 的 models 从未被使用。后果是：网关里根本没有模型（首次安装、models.json
    // 尚未生成）时，界面依然列出 "Proteus-1 / GPU" 两个可选项，用户能选、能
    // 发消息，然后失败 —— 而「接入模型」页此刻是空的，因为本地确实没模型。
    // 逻辑自相矛盾：界面声称有东西，另一页证明没有。
    //
    // 现在 schemes 由真实模型列表驱动；空列表 = 未配置，聊天页据此禁用输入。
    // 只有标题/说明这类展示性文案用 id 做已知映射，未知模型也能正常工作。
    @Published private(set) var schemes: [Scheme] = []

    /// 展示信息映射：已知模型 → 人类可读的标题与说明。
    /// 未登记的模型不会被隐藏，只是用 id 本身当标题。
    private static func describe(_ id: String) -> (String, String, String?, Bool) {
        switch id {
        case "proteus-1":
            return ("Proteus-1", "投机解码 + prefix cache + KV int8", "最新", false)
        case "gpu-baseline":
            return ("GPU", "原生 MLX 运行，无任何优化", "基线", true)
        default:
            return (id, "自定义模型", nil, false)
        }
    }

    /// 从网关返回的模型 id 列表重建方案表。
    private func rebuildSchemes(from ids: [String]) {
        let next = ids.map { id -> Scheme in
            let (title, detail, badge, isBaseline) = Self.describe(id)
            return Scheme(id: id, title: title, detail: detail,
                          badge: badge, isBaseline: isBaseline)
        }
        schemes = next
        // 选中项若已不存在（模型被删/网关换了配置），回落到第一个；
        // 列表为空时保持 nil，由界面呈现「未接入」状态。
        if let cur = selectedSchemeID, next.contains(where: { $0.id == cur }) {
            // 保留当前选择，但刷新它的展示字段
            selectedSchemeID = cur
        } else {
            selectedSchemeID = next.first?.id
        }
    }

    /// 当前选中的方案。未配置时为 nil。
    var selectedScheme: Scheme? {
        guard let id = selectedSchemeID else { return nil }
        return schemes.first { $0.id == id }
    }

    /// 是否已接入至少一个模型（决定聊天页能否发送）。
    var isConfigured: Bool { !schemes.isEmpty }

    /// 网关在线但没有任何模型 —— 首次安装的典型状态。
    var needsSetup: Bool { stats.alive && schemes.isEmpty }

    /// 网关是否在线（供侧边栏指示灯用）。
    var gatewayAlive: Bool { stats.alive }

    @Published var selectedSchemeID: String?
    @Published var stats = GatewayStats()
    @Published var models: [String] = []
    @Published var busy = false
    @Published var setup = SetupStore()

    /// 置位后由 RootView 消费并跳到「接入模型」页。
    /// 用一个一次性标志而不是直接持有 tab 状态：tab 属于 RootView 的
    /// @State，store 不该反向拥有它，否则两边都可能改、状态就分叉了。
    @Published var requestSetupTab = false

    /// 网关源码根目录（gm 包所在处），供「接入模型」页调 gm.probe_cli 用。
    ///
    /// 原先写死成 `~/GeneralModel`，但工作目录后来改成了 ~/Proteus-Release，
    /// 于是探测一定失败（cwd 下没有 gm 包）。这里按优先级找第一个真含
    /// `gm/__main__.py` 的目录，找不到就让调用方明确报错，而不是拿一个
    /// 猜的路径去跑。
    var gatewayRoot: String {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/Proteus-Release",
            home + "/GeneralModel",
            Bundle.main.bundleURL.deletingLastPathComponent().path,
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c + "/gm/__main__.py") {
                return c
            }
        }
        return candidates[0]
    }

    let chat = ChatEngine()
    let gateway = GMGateway()

    // ⚠️ 关键：`chat` 是嵌套的 ObservableObject，SwiftUI **不会**自动观察它。
    // 症状（用户实测报障）：发一条消息后界面毫无反应，切到别的标签页再切回来
    // 才突然看到全部输出。
    //
    // 原因：View 里写的是 `store.chat.messages`。`store` 变化会触发重绘，但
    // `chat` 的 @Published 变化与 `store.objectWillChange` 没有任何关系 ——
    // AppStore 这个 ObservableObject 根本不知道 chat 变了。于是流式 token
    // 一直在写进 chat.liveText，View 却从不重绘；只有切换到别的 tab 导致
    // RootView 重新求值（整个 detail 分支重建），才顺便读到最新值。
    //
    // 修法：把 chat 的 objectWillChange 转发给 AppStore，使任何 chat 变化
    // 都上升为 store 变化，从而触发依赖 store 的 View 重绘。
    private var cancellables = Set<AnyCancellable>()

    init() {
        chat.objectWillChange
            .sink { [weak self] _ in
                // 转发到下一轮 runloop：objectWillChange 在变更**之前**发出，
                // 若同步转发，View 求值时 @Published 尚未写入新值，会渲染成
                // 旧内容。延迟一拍可保证读到的是变更后的值。
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    func refresh() async {
        async let alive = gateway.alive()
        async let s = gateway.stats()
        let (a, st) = await (alive, s)
        stats = st
        stats.alive = a
        let ids = (try? await gateway.modelIDs()) ?? []
        models = ids
        // 用真实模型列表驱动方案表 —— 这是「未配置」状态的唯一判据。
        rebuildSchemes(from: ids)
    }

    func newChat() { chat.reset() }

    @Published var restarting = false
    @Published var restartMessage: String?

    /// 重启网关。
    ///
    /// 之前"点了没反应"的两个原因，都已修：
    ///   1. 失败被静默吞掉 —— `try? p.run()` 出错也无声无息，用户只能看到
    ///      界面毫无变化。现在把 stderr 与退出码回报到 restartMessage。
    ///   2. 没有任何进行中提示 —— restarting 设了却没人显示。
    /// 另外 Process 不继承登录 shell 的 PATH（GUI 应用环境很干净），
    /// 所以 launchctl 必须用绝对路径，且失败时回退到另一处常见路径。
    func restartGateway() async {
        guard !restarting else { return }
        restarting = true
        restartMessage = nil
        defer { restarting = false }

        let label = "com.tristan.gm.gateway"
        let uid = getuid()

        // 全部放到后台：Process.run/waitUntilExit 是同步阻塞的，
        // 直接在 @MainActor 上跑会冻住整个界面。
        let result: (Int32, String) = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let candidates = ["/bin/launchctl",
                                  "/usr/bin/launchctl",
                                  "/sbin/launchctl"]
                guard let bin = candidates.first(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                }) else {
                    c.resume(returning: (-1, "找不到 launchctl"))
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                // kickstart -k 会先杀再起，服务端 KeepAlive 会重新拉起
                p.arguments = ["kickstart", "-k", "gui/\(uid)/\(label)"]
                let errPipe = Pipe()
                p.standardError = errPipe
                p.standardOutput = Pipe()
                do {
                    try p.run()
                } catch {
                    c.resume(returning: (-1, "启动 launchctl 失败：\(error.localizedDescription)"))
                    return
                }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let msg = String(data: errData, encoding: .utf8) ?? ""
                c.resume(returning: (p.terminationStatus, msg))
            }
        }

        if result.0 != 0 {
            restartMessage = "重启失败（退出码 \(result.0)）：\(result.1.isEmpty ? "未知错误" : result.1)"
            return
        }

        // 等模型重新加载（不阻塞 UI），然后探测是否真的起来了
        restartMessage = "已发送重启指令，等待网关就绪…"
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refresh()
            if stats.alive { break }
        }
        restartMessage = stats.alive
            ? "网关已重启并就绪"
            : "重启指令已发出，但网关尚未就绪 —— 请查看 /tmp/gm-gateway.log"
        // 3 秒后自动清除提示
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        restartMessage = nil
    }
}

/// 接入页的状态。
struct SetupStore {
    var path = ""
    var modelName = ""
    var candidates: [String] = []
    var report: String = ""
    var probing = false
    var writeEnabled = false
    var verdict = ""
    var verdictKind: VerdictKind = .none

    enum VerdictKind { case none, good, warn, bad }

    mutating func scanLocal() {
        var out: [String] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = [home.appendingPathComponent("Models"),
                     home.appendingPathComponent(".cache/huggingface/hub")]
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root,
                                                          includingPropertiesForKeys: nil)
            else { continue }
            for d in items {
                if d.lastPathComponent.hasPrefix("models--") {
                    let snaps = d.appendingPathComponent("snapshots")
                    if let ss = try? fm.contentsOfDirectory(at: snaps,
                                                            includingPropertiesForKeys: nil) {
                        for s in ss where fm.fileExists(
                            atPath: s.appendingPathComponent("config.json").path) {
                            out.append(s.path)
                            break
                        }
                    }
                } else if fm.fileExists(
                    atPath: d.appendingPathComponent("config.json").path) {
                    out.append(d.path)
                }
            }
        }
        candidates = out.sorted()
    }
}
