import ConnCrypto
import ConnKit
import ConnMonitor
import ConnOps
import ConnRunner
import ConnSSH
import ConnSSHCitadel
import ConnStore
import SwiftUI

/// App 组装根：依赖注入、路由、场景生命周期（技术实现方案 §5）。
@main
struct ConnApp: App {
    private let dependencies = ConnApp.makeDependencies()
    @State private var localization = LocalizationManager()
    @State private var settings = SettingsStore()

    init() {
        // 在任何视图（含 .searchable 搜索框）创建前配置 UIKit 外观——appearance 只对
        // 之后创建的实例生效，放到 onAppear 里会与首个搜索框的创建竞态导致背景色不生效。
        ConnAppearance.configureIfNeeded()
    }

    /// 依赖选择：DEBUG 下 `CONN_DEMO=1` 走演示模式（Mock 引擎 + 假数据），
    /// 否则走生产（Citadel + GRDB 落盘）。Phase 10 会把演示开关搬到设置页。
    private static func makeDependencies() -> AppDependencies {
        #if DEBUG
            if ProcessInfo.processInfo.environment["CONN_DEMO"] != nil {
                return AppDependencies.demo()
            }
        #endif
        return AppDependencies.live()
    }

    var body: some Scene {
        WindowGroup {
            AppLockGate(lock: dependencies.appLock) {
                // 切换语言 / 主题色即 bump id → 整树重建：语言令各包 L() 重取，
                // 主题色令 40+ 处 connAccent 重读 ConnTheme（见 SettingsStore）。
                rootView.id("\(localization.language.rawValue)-\(settings.accent.rawValue)")
            }
            .environment(localization)
            .environment(settings)
            // 主题色着色系统控件（原生底栏选中态等）。
            .tint(settings.accent.color)
            // 深浅色：跟随系统 / 强制浅 / 强制深（设置页）。
            .preferredColorScheme(settings.appearance.colorScheme)
            // 全局「点击空白处收起键盘」。
            .onAppear { KeyboardDismisser.shared.installIfNeeded() }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
            if ProcessInfo.processInfo.environment["CONN_SMOKE_DIAGNOSTICS"] != nil {
                DiagnosticsSmokeView(transport: dependencies.diagnosticsTransport)
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL"] != nil {
                // `TerminalScreen` 现在自己包了一层 `NavigationStack`（配合 6 个调用点
                // 都改成 `.fullScreenCover`），这里不再外包一层，否则嵌两层导航栈。
                TerminalScreen(
                    host: Host(name: "spike-ubuntu24", address: "127.0.0.1", username: "deploy", port: 2202),
                    // 冒烟专用：固定密码 resolver（正常路径走 Keychain）
                    connectionManager: ConnectionManager(
                        transport: dependencies.diagnosticsTransport
                    ) { _ in .password("conntest123") },
                    autoCommand: smokeTerminalCommand(),
                    snippetRepository: dependencies.snippetRepository,
                    snippetGroupRepository: dependencies.snippetGroupRepository
                )
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_DETAIL"] != nil,
                      let host = smokeDetailHost() {
                NavigationStack {
                    HostDetailView(host: host, dependencies: dependencies, initialSegment: smokeSegment())
                }
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_LOGSTREAM"] != nil,
                      let host = smokeDetailHost() {
                NavigationStack {
                    LogStreamView(
                        host: host, dependencies: dependencies,
                        source: LogSource(
                            id: "smoke-nginx", title: "Nginx 错误",
                            subtitle: "/var/log/nginx/error.log",
                            kind: .file(path: "/var/log/nginx/error.log")
                        )
                    )
                }
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_SNIPPETS"] != nil {
                NavigationStack { SnippetsView(dependencies: dependencies) }
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_HOSTFORM"] != nil {
                HostFormView(dependencies: dependencies, initialDraft: HostDraft(), editingHostID: nil) {}
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_CARDS"] != nil {
                CardStatesSmokeView()
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_ME"] != nil {
                NavigationStack { MeView(dependencies: dependencies) }
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_EDITOR"] != nil, let host = smokeDetailHost() {
                NavigationStack {
                    FileEditorView(
                        host: host, dependencies: dependencies,
                        entry: FileEntry(
                            name: "nginx.conf", path: "/etc/nginx/nginx.conf",
                            size: 200, permissions: 0o100644, kind: .file
                        )
                    )
                }
            } else {
                RootTabView(dependencies: dependencies)
            }
        #else
            RootTabView(dependencies: dependencies)
        #endif
    }

    #if DEBUG
        /// 冒烟：优先取演示故障机（有高负载 + 进程列表），否则第一台。
        private func smokeDetailHost() -> Host? {
            let hosts = (try? dependencies.hostRepository.allHosts()) ?? []
            return hosts.first { $0.address == DemoData.faultHostAddress } ?? hosts.first
        }

        /// 冒烟：CONN_SMOKE_SEGMENT 指定初始段（docker / logs / files / overview）。
        private func smokeSegment() -> HostDetailView.Segment {
            switch ProcessInfo.processInfo.environment["CONN_SMOKE_SEGMENT"] {
            case "docker": .docker
            case "logs": .logs
            case "files": .files
            case "processes": .processes
            default: .overview
            }
        }

        /// 终端冒烟可切换成长输出，用同一个入口验证键盘可见区与自动跟随。
        private func smokeTerminalCommand() -> String {
            guard ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_LONG_OUTPUT"] != nil else {
                return "echo '中文渲染测试 你好世界 café 日本語 🚀 制表符'; ls /"
            }
            return (1 ... 120)
                .map { String(format: "terminal output line %03d", $0) }
                .joined(separator: "\r\n")
        }
    #endif
}

/// 依赖容器。
///
/// 技术实现方案 §1.1：**禁止单例直取**——所有跨层交互经协议注入，
/// 保证演示模式与测试可整体替换数据层与传输层。
@MainActor
struct AppDependencies {
    let hostRepository: any HostRepository
    /// 主机分组仓库。与 `snippetGroupRepository`（命令分组）同构。
    let hostGroupRepository: any HostGroupRepository
    let keyRepository: any SSHKeyRepository
    let credentialStore: any CredentialStore
    /// 连接池管理器。主机详情、监控采集、Docker/日志、片段执行都经它取会话。
    let connectionManager: ConnectionManager
    /// 连接测试用的传输层（与 connectionManager 同引擎，供诊断树直接调用）。
    let diagnosticsTransport: any SSHTransport
    /// 监控采集调度（Phase 7）。仪表盘 30s / 详情 3s。
    let monitor: MonitorScheduler
    /// 执行审计仓库（Phase 8/9）。容器启停、片段执行写入。
    let runHistory: any RunHistoryRepository
    /// 片段仓库（Phase 9）。首启导入内置模板库。
    let snippetRepository: any SnippetRepository
    /// 命令分组仓库。与 `hostGroupRepository`（主机分组）同构。
    let snippetGroupRepository: any SnippetGroupRepository
    /// 应用锁。默认关闭，设置页开启（Phase 5）。
    let appLock: AppLockController

    /// 生产依赖：GRDB 落盘库 + Citadel 引擎 + 持久化 TOFU 指纹库。
    static func live() -> AppDependencies {
        do {
            let database = try AppDatabase.onDisk(at: databaseURL())
            let hostStore = HostStore(database: database)
            let groupStore = HostGroupStore(database: database)
            let keyStore = SSHKeyStore(database: database)

            // SSH 栈：Citadel 引擎 + GRDB 指纹库（TOFU 跨重启留存）。
            let hostKeyStore = GRDBHostKeyStore(database: database)
            let transport = CitadelTransport(hostKeyStore: hostKeyStore)
            let credentialStore = KeychainCredentialStore()
            let connectionManager = ConnectionManager(transport: transport) { host in
                // 从 Keychain 取该主机凭据（Phase 5 会扩展密钥/SE）
                let password = (try? credentialStore.password(forHost: host.id)) ?? ""
                return .password(password)
            }

            // 监控栈：采集调度。指标为纯内存态，不落库。
            let monitor = MonitorScheduler(connectionManager: connectionManager)

            let snippetStore = SnippetStore(database: database)
            let snippetGroupStore = SnippetGroupStore(database: database)
            let runHistoryStore = RunHistoryStore(database: database)
            // 遗留 pending 表示应用上次在等待流式命令终态时退出；远端是否最终完成
            // 无法可靠推断，必须在依赖注入前同步转为 unknown，失败则让启动明确失败。
            try runHistoryStore.recoverPending()
            try importBuiltinSnippetsIfNeeded(snippetStore, snippetGroupStore)

            return AppDependencies(
                hostRepository: hostStore,
                hostGroupRepository: groupStore,
                keyRepository: keyStore,
                credentialStore: credentialStore,
                connectionManager: connectionManager,
                diagnosticsTransport: transport,
                monitor: monitor,
                runHistory: runHistoryStore,
                snippetRepository: snippetStore,
                snippetGroupRepository: snippetGroupStore,
                appLock: AppLockController(
                    authenticator: LABiometricAuthenticator(),
                    // 设置页持久化的开关；DEBUG 冒烟可强制开启验证锁屏。
                    isEnabled: UserDefaults.standard.bool(forKey: AppLockController.storageKey)
                        || ProcessInfo.processInfo.environment["CONN_SMOKE_APPLOCK"] != nil
                )
            )
        } catch {
            // 数据库开不了是不可恢复的：此时 App 无法承载任何功能。
            // 与其静默降级成空界面，不如带着原因崩溃，便于用户导出诊断。
            fatalError("数据库初始化失败：\(error)")
        }
    }

    #if DEBUG
    /// 演示依赖（**仅 DEBUG 编译**）：内存库 + Mock 引擎（假指标/容器/日志）。
    /// 不进入发行包——仅供开发期截图与冒烟联调（`CONN_DEMO` / `CONN_SMOKE_*`）。
    /// 演示数据由 `DemoData` 生成并经 `MockSSHTransport.dynamicResponder` 注入。
    static func demo() -> AppDependencies {
        do {
            let database = try AppDatabase.inMemory()
            let hostStore = HostStore(database: database)
            let groupStore = HostGroupStore(database: database)
            let keyStore = SSHKeyStore(database: database)
            try DemoData.seedHosts(into: hostStore, groups: groupStore)

            let transport = MockSSHTransport(behavior: DemoData.behavior())
            let credentialStore = InMemoryCredentialStore()
            let connectionManager = ConnectionManager(transport: transport) { _ in .password("demo") }
            let monitor = MonitorScheduler(connectionManager: connectionManager)
            let snippetStore = SnippetStore(database: database)
            let snippetGroupStore = SnippetGroupStore(database: database)
            let runHistoryStore = RunHistoryStore(database: database)
            try runHistoryStore.recoverPending()
            try importBuiltinSnippetsIfNeeded(snippetStore, snippetGroupStore)

            return AppDependencies(
                hostRepository: hostStore,
                hostGroupRepository: groupStore,
                keyRepository: keyStore,
                credentialStore: credentialStore,
                connectionManager: connectionManager,
                diagnosticsTransport: transport,
                monitor: monitor,
                runHistory: runHistoryStore,
                snippetRepository: snippetStore,
                snippetGroupRepository: snippetGroupStore,
                appLock: AppLockController(authenticator: LABiometricAuthenticator(), isEnabled: false)
            )
        } catch {
            fatalError("演示库初始化失败：\(error)")
        }
    }
    #endif

    /// `Application Support/Conn/conn.sqlite`
    private static func databaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Conn/conn.sqlite")
    }

    /// 仅首次启动时把内置 JSON 中的分组和命令写入数据库。
    /// 首启导入内置命令库。
    ///
    /// 用 UserDefaults 标记而非数据行数——改真删除后墓碑不存在，
    /// 数行数会把「用户删光默认命令」误判为「从未导入」并重新灌回去。
    private static func importBuiltinSnippetsIfNeeded(
        _ store: SnippetStore,
        _ groups: SnippetGroupStore
    ) throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsStore.builtinSnippetsImportedKey) else { return }
        try BuiltinSnippets.importIfNeeded(into: store, groups: groups)
        defaults.set(true, forKey: SettingsStore.builtinSnippetsImportedKey)
    }
}
