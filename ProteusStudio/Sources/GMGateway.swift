import Foundation

/// 网关地址解析 —— 端口的唯一真相源是 `models.json` 的 `server.port`。
///
/// 为什么不让 GUI 自己存一份端口：用户可能同时用 CLI（`proteus port 9000`）
/// 或手改 models.json。GUI 里若再存一份，两边就会分叉 —— 表现为「CLI 说在线、
/// GUI 说离线」，而且用户完全看不出为什么。
///
/// 因此每次启动都重新读文件，与 `proteus` CLI 用同一份来源。
enum GatewayLocator {
    /// 候选配置目录，按优先级排列。
    ///
    /// 第一项来自 launchd plist 的 WorkingDirectory —— 那是**实际在跑**的
    /// 服务目录，权威性最高。其余是常见安装位置。
    static func candidateDirs() -> [String] {
        var out: [String] = []
        let home = NSHomeDirectory()
        let plist = home + "/Library/LaunchAgents/com.tristan.gm.gateway.plist"
        if let d = FileManager.default.contents(atPath: plist),
           let s = String(data: d, encoding: .utf8),
           let r = s.range(of: "<key>WorkingDirectory</key>") {
            let tail = s[r.upperBound...]
            if let a = tail.range(of: "<string>"),
               let b = tail.range(of: "</string>", range: a.upperBound..<tail.endIndex) {
                let v = String(tail[a.upperBound..<b.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if v.hasPrefix("/") { out.append(v) }
            }
        }
        out.append(home + "/Proteus-Release")
        out.append(home + "/GeneralModel")
        out.append(Bundle.main.bundleURL.deletingLastPathComponent().path)
        return out
    }

    /// 解析出的 (host, port, 配置路径)。找不到配置时回落到 127.0.0.1:8320。
    static func resolve() -> (host: String, port: Int, configPath: String?) {
        for dir in candidateDirs() {
            let p = dir + "/models.json"
            guard let data = FileManager.default.contents(atPath: p),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let srv = obj["server"] as? [String: Any] else { continue }
            let host = (srv["host"] as? String) ?? "127.0.0.1"
            // port 可能是 Int 也可能是 NSNumber
            let port = (srv["port"] as? Int)
                ?? (srv["port"] as? NSNumber)?.intValue
                ?? 8320
            if port > 0 && port <= 65535 {
                return (host, port, p)
            }
        }
        return ("127.0.0.1", 8320, nil)
    }

    static func baseURL() -> URL {
        let r = resolve()
        return URL(string: "http://\(r.host):\(r.port)")!
            ?? URL(string: "http://127.0.0.1:8320")!
    }

    /// 供界面展示的可读地址。
    static func displayAddress() -> String {
        let r = resolve()
        return "\(r.host):\(r.port)"
    }
}

/// 网关的一条模型条目，含它绑定的权重与运行时参数。
///
/// 注意 `weight` 与 `id` 的区别：`id` 是发给网关的 model 字段（一个运行配置），
/// `weight` 是它加载的权重文件。多条 entry 可以共享同一个 weight —— 当前
/// `proteus-1` 与 `gpu-baseline` 就是这种情况。界面据此分成两个维度。
struct ModelEntryInfo: Identifiable, Hashable {
    let id: String
    let weight: String
    let weightName: String
    let speculative: Bool
    let numDraftTokens: Int
    let prefixCache: Bool
    let kvBits: Int

    /// 「加速方案」维度的说明文案。
    var schemeDetail: String {
        if !speculative && !prefixCache && kvBits == 0 {
            return "原生 MLX 运行，无任何优化"
        }
        var parts: [String] = []
        if speculative { parts.append("投机解码 nd=\(numDraftTokens)") }
        if prefixCache { parts.append("prefix cache") }
        if kvBits > 0 { parts.append("KV int\(kvBits)") }
        return parts.joined(separator: " + ")
    }

    /// 是否是一套「无优化」的基线配置。
    var isBaseline: Bool { !speculative && !prefixCache && kvBits == 0 }
}

/// gm 网关客户端 —— OpenAI 兼容，支持 SSE 流式。
actor GMGateway {
    let base: URL

    init(base: URL? = nil) {
        self.base = base ?? GatewayLocator.baseURL()
    }

    /// 供界面展示/拼接端点用的地址字符串（跟随 models.json 的端口）。
    nonisolated var baseURLString: String {
        base.absoluteString
    }

    private var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 900
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    func alive() async -> Bool {
        var r = URLRequest(url: base.appendingPathComponent("stats"))
        r.timeoutInterval = 4
        guard let (_, resp) = try? await session.data(for: r),
              let h = resp as? HTTPURLResponse, h.statusCode == 200 else { return false }
        return true
    }

    func modelIDs() async throws -> [String] {
        try await modelEntries().map(\.id)
    }

    /// 拉取网关的模型条目（含 weight 与 params）。
    ///
    /// 为什么需要比 id 更多的信息：同一个权重可以配成多条 entry（当前
    /// `proteus-1` 与 `gpu-baseline` 就都指向 Llama-3.1-8B-Instruct-4bit，
    /// 只有运行时参数不同）。界面要分成「选哪个 LLM」和「用哪套加速配置」
    /// 两个正交维度，就必须能看出哪些 entry 共享同一个权重 —— 只看 id
    /// 是分辨不出来的。
    ///
    /// 兼容性：`weight` / `params` 是本网关新增字段。旧版网关不返回时，
    /// 退化为「每条 entry 自成一个 weight」，界面仍能工作（只是不再分组）。
    func modelEntries() async throws -> [ModelEntryInfo] {
        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        req.timeoutInterval = 6
        let (data, _) = try await session.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            let weight = (d["weight"] as? String) ?? id
            let wname = (d["weight_name"] as? String)
                ?? weight.split(separator: "/").last.map(String.init) ?? id
            let p = d["params"] as? [String: Any] ?? [:]
            return ModelEntryInfo(
                id: id,
                weight: weight,
                weightName: wname,
                speculative: (p["speculative"] as? Bool) ?? false,
                numDraftTokens: (p["num_draft_tokens"] as? Int) ?? 0,
                prefixCache: (p["prefix_cache"] as? Bool) ?? false,
                kvBits: (p["kv_bits"] as? Int) ?? 0)
        }
    }

    func stats() async -> GatewayStats {
        var out = GatewayStats()
        var r = URLRequest(url: base.appendingPathComponent("stats"))
        r.timeoutInterval = 4
        guard let (data, _) = try? await session.data(for: r) else { return out }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return out }
        out.alive = true
        out.loadedModels = (obj["loaded"] as? [String]) ?? []
        out.uptime = (obj["uptime_s"] as? Double) ?? 0
        if let m = obj["last_meta"] as? [String: Any] {
            out.tps = (m["tps"] as? Double) ?? 0
            out.ttft = (m["ttft_s"] as? Double) ?? 0
            out.tpot = (m["tpot_s"] as? Double) ?? 0
            out.speculative = (m["speculative"] as? Bool) ?? false
            out.acceptRule = (m["accept_rule"] as? String) ?? ""
            out.numDraft = (m["num_draft_tokens"] as? Int) ?? 0
            out.acceptLen = (m["accept_len_median"] as? Double) ?? 0
            out.acceptRounds = (m["accept_rounds"] as? Int) ?? 0
            out.completionTokens = (m["completion_tokens"] as? Int) ?? 0
            out.prefixCached = (m["prefix_cached_tokens"] as? Int) ?? 0
        }
        return out
    }

    /// 非流式（用于接入页的连通性测试）
    func complete(model: String, messages: [[String: String]],
                  maxTokens: Int = 32, temperature: Double = 0) async throws -> String {
        var r = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages,
            "max_tokens": maxTokens, "temperature": temperature,
        ] as [String: Any])
        let (data, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw GatewayError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, msg)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ch = (obj["choices"] as? [[String: Any]])?.first,
              let m = ch["message"] as? [String: Any] else {
            throw GatewayError.decode("响应结构异常")
        }
        return (m["content"] as? String) ?? ""
    }

    /// SSE 流式。onDelta 在每段增量到达时调用；返回完整文本。
    /// stop 是一个 closure，返回 true 时中止读取（关连接让网关感知取消）。
    nonisolated func stream(
        model: String,
        messages: [[String: Any]],
        temperature: Double,
        maxTokens: Int,
        session sessionID: String?,
        stop: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        var r = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model, "messages": messages,
            "temperature": temperature, "max_tokens": maxTokens, "stream": true,
        ]
        if let s = sessionID { body["session"] = s }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 900
        let (bytes, resp) = try await URLSession(configuration: cfg).bytes(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            // ⚠️ 必须把网关的错误正文读出来。附件被拒（400）时网关会在 body
            // 里写明原因（例如「不支持的文件类型：.png」）；旧实现只丢一句
            // 笼统的 "流式请求失败"，用户根本不知道附件哪里出了问题。
            var detail = "流式请求失败"
            var buf = Data()
            for try await b in bytes {
                buf.append(b)
                if buf.count > 8192 { break }
            }
            if let obj = try? JSONSerialization.jsonObject(with: buf) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String, !msg.isEmpty {
                detail = msg
            } else if let s = String(data: buf, encoding: .utf8), !s.isEmpty {
                detail = String(s.prefix(400))
            }
            throw GatewayError.http(status, detail)
        }

        var full = ""
        for try await line in bytes.lines {
            if stop() { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ch = (obj["choices"] as? [[String: Any]])?.first,
                  let delta = ch["delta"] as? [String: Any],
                  let piece = delta["content"] as? String, !piece.isEmpty
            else { continue }
            full += piece
            onDelta(piece)
        }
        return full
    }
}

enum GatewayError: LocalizedError {
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "网关错误 \(code)：\(msg)"
        case .decode(let m): return m
        }
    }
}
