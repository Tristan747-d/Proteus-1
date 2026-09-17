import SwiftUI
import AppKit

// MARK: - 应用入口（Proteus Studio）

@main
struct ProteusStudioApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 940, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("对话") {
                Button("新对话") { store.newChat() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("停止生成") { store.chat.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            }
            CommandMenu("网关") {
                Button("刷新状态") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("重启网关") { Task { await store.restartGateway() } }
            }
        }
    }
}

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab: Tab = .chat

    enum Tab: String, CaseIterable, Identifiable {
        case chat = "对话"
        case setup = "接入模型"
        case service = "服务"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .chat: return "bubble.left.and.bubble.right.fill"
            case .setup: return "square.stack.3d.up.fill"
            case .service: return "network"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(tab: $tab)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch tab {
                case .chat: ChatView()
                case .setup: SetupView()
                case .service: ServiceView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .task { await store.refresh() }
        // 「去接入模型」按钮的落地：store 置位 → 这里消费并切页。
        .onChange(of: store.requestSetupTab) { _, want in
            if want { tab = .setup; store.requestSetupTab = false }
        }
    }
}

// MARK: - 侧边栏

struct Sidebar: View {
    @EnvironmentObject var store: AppStore
    @Binding var tab: RootView.Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌区
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.10, green: 0.52, blue: 1.0),
                                     Color(red: 0.20, green: 0.36, blue: 0.95)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Proteus Studio")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Proteus 推理工作台")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 14)

            // 导航
            VStack(spacing: 2) {
                ForEach(RootView.Tab.allCases) { t in
                    SidebarRow(tab: t, selected: tab == t) { tab = t }
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            // 网关状态
            GatewayBadge()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
    }
}

struct SidebarRow: View {
    let tab: RootView.Tab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14)
                                   : (hovering ? Color.primary.opacity(0.06) : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct GatewayBadge: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(store.gatewayAlive ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .shadow(color: (store.gatewayAlive ? Color.green : .red).opacity(0.6),
                        radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.gatewayAlive ? "网关在线" : "网关离线")
                    .font(.system(size: 11, weight: .medium))
                Text("127.0.0.1:8320")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }
}
