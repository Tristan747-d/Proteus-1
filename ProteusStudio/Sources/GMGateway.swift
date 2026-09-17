import Foundation

/// gm 网关客户端 —— OpenAI 兼容，支持 SSE 流式。
actor GMGateway {
    let base: URL

    init(base: URL = URL(string: "http://127.0.0.1:8320")!) {
        self.base = base
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
        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        req.timeoutInterval = 6
        let (data, _) = try await session.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }
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
        messages: [[String: String]],
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
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
            throw GatewayError.http((resp as? HTTPURLResponse)?.statusCode ?? -1,
                                    "流式请求失败")
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
