import Foundation
import SwiftUI
import Combine

// MARK: - 数据模型

// 注：原先这里有一个 `struct Scheme`（id/title/detail/badge/isBaseline）。
// 它已被 ModelEntryInfo（GMGateway.swift）取代 —— 后者直接来自网关的
// /v1/models，带着 weight 与真实 params，不再需要界面自己编造文案。

/// 一条对话消息。
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: Role
    var text: String
    var createdAt = Date()
    var ttft: Double?
    var elapsed: Double?
    var charsPerSec: Double?
    /// 该条消息附带的文件名（仅用于展示气泡上的附件标签）。
    /// 不存内容 —— 附件数据只在发送那一刻存在于 payload 里。
    var attachmentNames: [String] = []

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
    /// 本次请求的验证轮数与 completion token 数 —— 后者用于**归属校验**：
    /// /stats.last_meta 是全局字段，只有 token 数对得上才能确认这条记录
    /// 属于我们的请求（见 ChatEngine.mergeAccept）。
    var acceptRounds = 0
    var completionTokens = 0
    var prefixCached = 0
    var uptime: Double = 0
}

/// 一个权重模型（LLM 维度）。
///
/// 对应网关 config 里的一个权重路径。同一个权重下可以有多条 entry，
/// 它们是「加速方案」维度上的不同运行配置。
struct WeightModel: Identifiable, Hashable {
    let path: String      // 权重目录的绝对路径（唯一键）
    let name: String      // 显示名，如 "Llama-3.1-8B-Instruct-4bit"

    var id: String { path }

    /// 把目录名收拾成适合展示的样子。
    /// 例：Llama-3.1-8B-Instruct-4bit → "Llama 3.1 8B Instruct"
    var displayName: String {
        var s = name
        // 去掉量化后缀（参数量已在名字里体现，位宽属于运行配置不属于模型）
        for suffix in ["-4bit", "-8bit", "-6bit", "-bf16", "-fp16"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)); break }
        }
        s = s.replacingOccurrences(of: "-Instruct", with: "")
        s = s.replacingOccurrences(of: "-", with: " ")
        return s.isEmpty ? name : s
    }

    /// 参数量标签，如 "8B"。取名字里第一个「数字+B/b」片段。
    ///
    /// 用手写扫描而不是正则字面量 `/.../`：后者需要 Swift 5.7+ 的
    /// bare-slash 正则并受 `-enable-bare-slash-regex` 影响，本项目按
    /// Swift 5.10 配置编译时不受支持（实测报 "expected expression"）。
    var sizeTag: String? {
        let chars = Array(name)
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
            // 数字后面必须紧跟 B/b，且不能是更长的单词的一部分
            if j < chars.count, chars[j] == "B" || chars[j] == "b" {
                let after = j + 1
                let boundary = after >= chars.count || !chars[after].isLetter
                if boundary {
                    // chars[i...j] 已含末尾的 B/b，不要再补一个
                    // （早期版本写成 + "B"，输出 "8BB"）。
                    return String(chars[i...j]).uppercased()
                }
            }
            i = j + 1
        }
        return nil
    }

    /// 量化位宽标签，如 "4-bit"。
    var quantTag: String? {
        for q in ["4bit", "8bit", "6bit"] where name.lowercased().contains(q) {
            return q.replacingOccurrences(of: "bit", with: "-bit")
        }
        return nil
    }
}

// MARK: - AppStore

@MainActor
final class AppStore: ObservableObject {
    // 模型选择被拆成**两个正交维度**（用户明确要求）：
    //
    //   ① LLM      —— 加载哪个权重模型（Llama-3.1-8B / 将来的 Qwen 等）
    //   ② 加速方案 —— 同一权重下用哪套运行时配置（Proteus-1 / GPU 基线）
    //
    // 为什么必须拆：当前 `proteus-1` 与 `gpu-baseline` **指向同一个权重**
    // （Llama-3.1-8B-Instruct-4bit），只是参数不同。把它们当成两个「模型」
    // 平铺在一个列表里，等于把「换模型」和「换运行配置」混为一谈 ——
    // 用户看到两个名字，会以为背后是两个不同的模型。
    //
    // 数据来源是网关 /v1/models 的 weight 字段：同一 weight 的多条 entry
    // 归为一组，组内按参数区分方案。
    @Published private(set) var entries: [ModelEntryInfo] = []

    /// 全部权重模型（去重后的 weight）。
    var weightModels: [WeightModel] {
        var seen = Set<String>()
        var out: [WeightModel] = []
        for e in entries where !seen.contains(e.weight) {
            seen.insert(e.weight)
            out.append(WeightModel(path: e.weight, name: e.weightName))
        }
        return out
    }

    /// 当前权重模型下可用的加速方案。
    var availableSchemes: [ModelEntryInfo] {
        guard let w = selectedWeight else { return [] }
        return entries.filter { $0.weight == w }
    }

    /// 当前选中的权重模型（未配置时为 nil）。
    var selectedWeight: String? {
        if let w = selectedWeightPath, weightModels.contains(where: { $0.path == w }) {
            return w
        }
        return weightModels.first?.path
    }

    /// 当前选中的网关条目（= 权重 + 方案），就是发给网关的 model 字段。
    var selectedEntry: ModelEntryInfo? {
        let schemes = availableSchemes
        if let id = selectedSchemeEntryID,
           let hit = schemes.first(where: { $0.id == id }) {
            return hit
        }
        return schemes.first
    }

    /// 实际发给网关的 model 字段。
    var selectedEntryID: String? { selectedEntry?.id }

    /// 是否已接入至少一个模型（决定聊天页能否发送）。
    var isConfigured: Bool { !entries.isEmpty }

    /// 网关在线但没有任何模型 —— 首次安装的典型状态。
    var needsSetup: Bool { stats.alive && entries.isEmpty }

    /// 网关是否在线（供侧边栏指示灯用）。
    var gatewayAlive: Bool { stats.alive }

    @Published var selectedWeightPath: String?
    /// 用户在「加速方案」控件里显式选中的条目 id（nil = 用该权重下的第一个）。
    @Published var selectedSchemeEntryID: String?
    @Published var stats = GatewayStats()
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

    // MARK: 端口（读/改 models.json 的 server.port）

    /// 当前 models.json 里记录的端口（真相源）。
    var configuredPort: Int { GatewayLocator.resolve().port }

    /// 解析到的配置文件路径（供界面显示「端口来自哪里」）。
    var configPath: String? { GatewayLocator.resolve().configPath }

    @Published var portEditing = false
    @Published var portMessage: String?

    /// 修改端口：校验 → 写 models.json → 提示需重启。
    ///
    /// 与 CLI 的 `proteus port` 语义一致。GUI 侧不做「静默生效」——
    /// 网关进程持有的是旧 socket，必须重启才能换端口，所以这里明确告知。
    ///
    /// 返回是否写入成功。
    func setPort(_ newPort: Int) async -> Bool {
        portMessage = nil
        guard let path = configPath else {
            portMessage = "找不到 models.json，无法修改端口。"
            return false
        }
        guard (1024...65535).contains(newPort) else {
            portMessage = "端口需在 1024–65535 之间（<1024 需要 root）。"
            return false
        }
        if newPort == configuredPort {
            portMessage = "端口已经是 \(newPort)，无需改动。"
            return true
        }
        // 可写性：models.json 若归 root 所有（早期用 sudo 装过就会这样），
        // 写入必然失败。提前拦下并给出确切命令，而不是抛一个看不懂的错误。
        guard FileManager.default.isWritableFile(atPath: path) else {
            let owner = (try? FileManager.default
                .attributesOfItem(atPath: path)[.ownerAccountName] as? String) ?? nil
            portMessage = "\(path) 不可写"
                + (owner.map { "（归 \($0) 所有）" } ?? "")
                + "。修复归属：sudo chown $(id -un) \"\(path)\""
            return false
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard var obj = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                portMessage = "models.json 结构异常，无法解析。"
                return false
            }
            var srv = (obj["server"] as? [String: Any]) ?? [:]
            let old = (srv["port"] as? Int) ?? Int((srv["port"] as? NSNumber)?.intValue ?? 0)
            srv["port"] = newPort
            obj["server"] = srv
            // 备份后写入，与 CLI 行为一致
            let bak = path + ".bak." + Self.stamp()
            try? FileManager.default.copyItem(atPath: path, toPath: bak)
            let out = try JSONSerialization.data(withJSONObject: obj,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: path))
            portMessage = "已保存：\(old) → \(newPort)。"
                + "端口改动不会自动生效，请重启网关。"
            return true
        } catch {
            portMessage = "写入失败：\(error.localizedDescription)"
            return false
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

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
        let list = (try? await gateway.modelEntries()) ?? []
        entries = list
        // 权重选择失效（模型被删 / 配置换了）时回落到第一个。
        if let w = selectedWeightPath,
           list.contains(where: { $0.weight == w }) {
            // 保留
        } else {
            selectedWeightPath = list.first?.weight
        }
        // 方案选择同理：当前 id 已不存在就清空，由 selectedEntry 回落到第一个。
        if let id = selectedSchemeEntryID,
           list.contains(where: { $0.id == id }) {
            // 保留
        } else {
            selectedSchemeEntryID = nil
        }
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
