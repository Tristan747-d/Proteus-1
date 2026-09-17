import Foundation
import SwiftUI

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
    // 方案定义 —— 与 models.json 的 aliases 对应。
    // 命名约定：Proteus-1 = 当前全部优化（投机+prefix cache+KV int8）；
    //           GPU = 研发前最原生 MLX 运行，作基线。
    let schemes: [Scheme] = [
        Scheme(id: "proteus-1", title: "Proteus-1",
               detail: "投机解码 + prefix cache + KV int8",
               badge: "最新", isBaseline: false),
        Scheme(id: "gpu-baseline", title: "GPU",
               detail: "原生 MLX 运行，无任何优化",
               badge: "基线", isBaseline: true),
    ]

    /// 网关是否在线（供侧边栏指示灯用）。
    var gatewayAlive: Bool { stats.alive }

    @Published var selectedScheme: Scheme
    @Published var stats = GatewayStats()
    @Published var models: [String] = []
    @Published var busy = false
    @Published var setup = SetupStore()

    let chat = ChatEngine()
    let gateway = GMGateway()

    init() {
        selectedScheme = schemes[0]
    }

    func refresh() async {
        async let alive = gateway.alive()
        async let s = gateway.stats()
        let (a, st) = await (alive, s)
        stats = st
        stats.alive = a
        models = (try? await gateway.modelIDs()) ?? []
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
