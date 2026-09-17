import SwiftUI

// MARK: - 服务 / 接入页

struct ServiceView: View {
    @EnvironmentObject var store: AppStore
    @State private var copied: String?

    // 跟随 models.json 的 server.port，不写死。
    private var base: String { store.gateway.baseURLString }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                endpointsCard
                clientCard
                limitsCard
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { await store.refresh() }
    }

    // MARK: 状态

    private var statusCard: some View {
        Card(title: "网关状态", step: "●") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.stats.alive ? Color.green : Color.red)
                        .frame(width: 9, height: 9)
                    Text(store.stats.alive ? "运行中" : "未运行")
                        .font(.system(size: 13, weight: .semibold))
                    Text("已运行 \(Int(store.stats.uptime / 60)) 分钟")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    Button {
                        Task { await store.restartGateway() }
                    } label: {
                        HStack(spacing: 5) {
                            if store.restarting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "power")
                            }
                            Text(store.restarting ? "重启中…" : "重启网关")
                        }
                    }
                    .controlSize(.small)
                    .disabled(store.restarting)
                }

                if let msg = store.restartMessage {
                    HStack(spacing: 7) {
                        Image(systemName: msg.contains("失败") || msg.contains("尚未")
                              ? "exclamationmark.triangle.fill"
                              : "info.circle.fill")
                        Text(msg).font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundStyle(msg.contains("失败") || msg.contains("尚未")
                                     ? Color.orange : Color.secondary)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    }
                }

                HStack(spacing: 8) {
                    Text(base + "/v1")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        }
                    Button {
                        copy(base + "/v1", tag: "base")
                    } label: {
                        Label(copied == "base" ? "已复制" : "复制",
                              systemImage: copied == "base" ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                    Spacer()
                }

                if !store.stats.loadedModels.isEmpty {
                    HStack(spacing: 6) {
                        Text("当前驻留")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        ForEach(store.stats.loadedModels, id: \.self) { m in
                            Text(m)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: 端点

    private var endpointsCard: some View {
        Card(title: "可用端点", step: "→") {
            VStack(spacing: 0) {
                endpoint("POST", "/v1/chat/completions", "对话（stream 支持）")
                Divider().padding(.leading, 52)
                endpoint("POST", "/v1/completions", "原始补全")
                Divider().padding(.leading, 52)
                endpoint("GET", "/v1/models", "模型列表")
                Divider().padding(.leading, 52)
                endpoint("GET", "/stats", "运行指标（TTFT / TPOT / 接受率）")
            }
        }
    }

    private func endpoint(_ method: String, _ path: String, _ desc: String) -> some View {
        HStack(spacing: 12) {
            Text(method)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(method == "GET" ? Color.blue : Color.green)
                .frame(width: 40, alignment: .leading)
            Text(path)
                .font(.system(size: 11.5, design: .monospaced))
            Spacer()
            Text(desc)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    // MARK: 客户端接入

    private var clientCard: some View {
        Card(title: "其他 agent 客户端如何接入", step: "⌘") {
            VStack(alignment: .leading, spacing: 12) {
                Text("网关是标准 OpenAI 兼容端点。任何支持自定义 base_url 的客户端都能直接接入，无需改动。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                snippet("环境变量",
                        "OPENAI_BASE_URL=\(base)/v1\nOPENAI_API_KEY=local\nOPENAI_MODEL=default")
                snippet("Python (openai SDK)",
                        "from openai import OpenAI\nc = OpenAI(base_url=\"\(base)/v1\", api_key=\"local\")\nc.chat.completions.create(model=\"default\", messages=[...])")

                Button {
                    copy("OPENAI_BASE_URL=\(base)/v1", tag: "env")
                } label: {
                    Label(copied == "env" ? "已复制配置片段" : "复制配置片段",
                          systemImage: copied == "env" ? "checkmark" : "doc.on.clipboard")
                }
                .controlSize(.small)
            }
        }
    }

    private func snippet(_ title: String, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
        }
    }

    // MARK: 限制

    private var limitsCard: some View {
        Card(title: "当前限制", step: "!") {
            VStack(alignment: .leading, spacing: 8) {
                limitRow("只监听 127.0.0.1", "仅本机可访问。局域网接入需把 models.json 的 server.host 改为 0.0.0.0")
                limitRow("不校验 API key", "任何 key 都接受（本机使用可接受）")
                limitRow("生成串行", "mlx_lm 单模型推理有 gen_lock，多客户端会排队而非并行")
            }
        }
    }

    private func limitRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ s: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copied == tag { copied = nil }
        }
    }
}
