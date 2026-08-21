import ConnCrypto
import ConnKit
import ConnMonitor
import ConnMultiplexer
import ConnOps
import ConnRunner
import ConnSSH
import ConnSSHCitadel
import ConnStore
import ConnTerminal
import ConnUI
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// App 组装根：依赖注入、路由、场景生命周期（技术实现方案 §5）。
@main
struct ConnApp: App {
    @State private var bootstrap: BootstrapState
    @State private var localization = LocalizationManager()
    @State private var settings = SettingsStore()
    @State private var toastCenter = ConnToastCenter()

    init() {
        _bootstrap = State(initialValue: Self.makeDependencies())
        // 在任何视图（含 .searchable 搜索框）创建前配置 UIKit 外观——appearance 只对
        // 之后创建的实例生效，放到 onAppear 里会与首个搜索框的创建竞态导致背景色不生效。
        ConnAppearance.configureIfNeeded()
        #if DEBUG
            // 终端粘贴的 UI 冒烟由 App 自己预置文本，避免 UI Test Runner 作为跨 App
            // 剪贴板来源触发系统权限弹窗；发布包不会执行这段。
            if let smokePasteText = ProcessInfo.processInfo.environment["CONN_SMOKE_PASTE_TEXT"] {
                UIPasteboard.general.string = smokePasteText
            }
        #endif
    }

    /// 依赖选择：DEBUG 下 `CONN_DEMO=1` 走演示模式（Mock 引擎 + 假数据），
    /// 否则走生产（Citadel + GRDB 落盘）。Phase 10 会把演示开关搬到设置页。
    private static func makeDependencies() -> BootstrapState {
        #if DEBUG
            if ProcessInfo.processInfo.environment["CONN_DEMO"] != nil {
                return .ready(AppDependencies.demo())
            }
        #endif
        do {
            return .ready(try AppDependencies.live())
        } catch {
            return .failed(error.friendlyDiagnosis)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch bootstrap {
                case .ready(let dependencies):
                    AppLockGate(lock: dependencies.appLock) {
                        // 切换语言 / 主题色即 bump id → 整树重建：语言令各包 L() 重取，
                        // 主题色令 40+ 处 connAccent 重读 ConnTheme（见 SettingsStore）。
                        rootView(dependencies: dependencies)
                            .id("\(localization.language.rawValue)-\(settings.accent.rawValue)")
                    }
                case .failed(let message):
                    DatabaseInitializationFailureView(message: message) {
                        bootstrap = Self.makeDependencies()
                    }
                }
            }
            .environment(localization)
            .environment(settings)
            // 主题色着色系统控件（原生底栏选中态等）。
            .tint(settings.accent.color)
            // 深浅色：跟随系统 / 强制浅 / 强制深（设置页）。
            .preferredColorScheme(settings.appearance.colorScheme)
            .connGlobalToast()
            // Toast 中心放在全局 modifier 外层，确保根提示层和所有页面读取同一实例。
            .environment(\.connToastCenter, toastCenter)
            // 全局「点击空白处收起键盘」。
            .onAppear { KeyboardDismisser.shared.installIfNeeded() }
        }
    }

    @ViewBuilder
    private func rootView(dependencies: AppDependencies) -> some View {
        #if DEBUG
            if ProcessInfo.processInfo.environment["CONN_SMOKE_DIAGNOSTICS"] != nil {
                DiagnosticsSmokeView(transport: dependencies.diagnosticsTransport)
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL"] != nil {
                // `TerminalScreen` 现在自己包了一层 `NavigationStack`（配合 6 个调用点
                // 都改成 `.fullScreenCover`），这里不再外包一层，否则嵌两层导航栈。
                TerminalSmokeLaunchView(
                    host: smokeTerminalHost(dependencies: dependencies),
                    dependencies: dependencies,
                    // 冒烟专用：固定密码 resolver（正常路径走 Keychain）。
                    terminalSessions: TerminalSessionCoordinator(
                        hostRepository: dependencies.hostRepository,
                        connectionManager: ConnectionManager(
                            transport: dependencies.diagnosticsTransport
                        ) { _ in .password("conntest123") }
                    ),
                    initialCommand: smokeTerminalCommand()
                )
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_CENTER"] != nil {
                TerminalSessionCenterSmokeView(dependencies: dependencies)
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_DETAIL"] != nil,
                      let host = smokeDetailHost(dependencies: dependencies) {
                NavigationStack {
                    HostDetailView(host: host, dependencies: dependencies, initialSegment: smokeSegment())
                }
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_LOGSTREAM"] != nil,
                      let host = smokeDetailHost(dependencies: dependencies) {
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
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_SCRIPT_RUN"] != nil {
                SnippetRunView(
                    snippet: BuiltinSnippets.load().first
                        ?? Snippet(title: "System Overview", script: "uname -a; uptime"),
                    dependencies: dependencies
                )
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_HOSTFORM"] != nil {
                HostFormView(dependencies: dependencies, initialDraft: HostDraft(), editingHostID: nil) { _ in }
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_CARDS"] != nil {
                CardStatesSmokeView()
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_ME"] != nil {
                NavigationStack { MeView(dependencies: dependencies) }
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_EDITOR"] != nil, let host = smokeDetailHost(dependencies: dependencies) {
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
        /// 终端 UI 冒烟使用本地 Spike；协调器会校验主机仍在仓库中，故把这台仅测试用的
        /// 主机写入演示内存库。它不进入生产依赖，也不会出现在发布版的数据里。
        private func smokeTerminalHost(dependencies: AppDependencies) -> Host {
            let host = Host(
                id: "conn.smoke.terminal",
                name: "ops-node-01",
                address: "127.0.0.1",
                username: "deploy",
                port: 2202
            )
            try? dependencies.hostRepository.save(host)
            return host
        }

        /// 冒烟：优先取演示故障机（有高负载 + 进程列表），否则第一台。
        private func smokeDetailHost(dependencies: AppDependencies) -> Host? {
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
            if ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_SCREENSHOT"] != nil {
                return "ls -a"
            }
            guard ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_LONG_OUTPUT"] != nil else {
                return "echo '中文渲染测试 你好世界 café 日本語 🚀 制表符'; ls /"
            }
            return (1 ... 120)
                .map { String(format: "terminal output line %03d", $0) }
                .joined(separator: "\r\n")
        }
    #endif
}

/// 生产依赖的启动状态。数据库初始化失败时保留在可恢复页面，避免 Release 直接崩溃。
private enum BootstrapState {
    case ready(AppDependencies)
    case failed(String)
}

/// 本地数据无法打开时的恢复页。
private struct DatabaseInitializationFailureView: View {
    let message: String
    let retry: () -> Void
    @State private var isShowingDetails = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.red)

                VStack(spacing: 8) {
                    Text(L("无法打开本地数据"))
                        .font(.title2.weight(.semibold))
                    Text(L("无法读取本地配置，请重试。本地数据不会上传。"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(action: retry) {
                    Label(L("重试"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                DisclosureGroup(L("错误详情"), isExpanded: $isShowingDetails) {
                    Text(message)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, minHeight: 420)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
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
    /// 片段执行准备器。复用连接池，并在 App 边界组合平台执行与能力适配器。
    let snippetExecutionPlanner: SnippetExecutionPlanner
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
    /// 全局终端会话中心。活动 PTY 驻留内存；可恢复 provider 仅保存本地恢复书签。
    /// SSH 连接仍统一复用 `connectionManager` 的连接池。
    let terminalSessions: TerminalSessionCoordinator
    /// 应用锁。默认关闭，设置页开启（Phase 5）。
    let appLock: AppLockController

    private static func makeSnippetExecutionPlanner(
        connectionManager: ConnectionManager
    ) -> SnippetExecutionPlanner {
        SnippetExecutionPlanner(
            connectionManager: connectionManager,
            executionProviderRegistry: .default,
            requirementAdapterRegistry: SnippetRequirementAdapterRegistry(adapters: [
                DockerSnippetRequirementAdapter(registry: .default),
            ])
        )
    }

    /// 生产依赖：GRDB 落盘库 + Citadel 引擎 + 持久化 TOFU 指纹库。
    static func live() throws -> AppDependencies {
            let database = try AppDatabase.onDisk(at: databaseURL())
            let hostStore = makeHostStore(database: database)
            let groupStore = HostGroupStore(database: database)
            let keyStore = SSHKeyStore(database: database)

            // SSH 栈：Citadel 引擎 + GRDB 指纹库（TOFU 跨重启留存）。
            let hostKeyStore = GRDBHostKeyStore(database: database)
            let transport = CitadelTransport(hostKeyStore: hostKeyStore)
            let credentialStore = KeychainCredentialStore()
            _ = try credentialStore.recoverLegacyKeyMetadata()
            // Keychain 在卸载应用后仍保留密钥元数据；SQLite 会随应用容器删除。
            // 启动时先恢复缺失的记录，保证主机表单和密钥管理页都能继续使用。
            for key in try credentialStore.allKeyMetadata() {
                if try keyStore.key(id: key.id) == nil {
                    try keyStore.save(key)
                }
            }
            let authResolver: AuthResolver = { host in
                if host.authKind == .key {
                    guard let keyID = host.keyUUID else {
                        throw SSHError.missingPrivateKey
                    }
                    guard let key = try keyStore.key(id: keyID),
                          let material = try credentialStore.privateKey(forKey: keyID)
                    else {
                        throw SSHError.missingPrivateKey
                    }
                    switch key.kind {
                    case .ed25519, .ecdsaP256:
                        if material.contains("BEGIN ") {
                            return .key(SSHPrivateKeyMaterial(kind: key.kind, pem: material))
                        }
                        if let raw = Data(base64Encoded: material) {
                            return .key(SSHPrivateKeyMaterial(kind: key.kind, raw: raw))
                        }
                        throw SSHError.missingPrivateKey
                    case .rsa:
                        return .key(SSHPrivateKeyMaterial(kind: .rsa, pem: material))
                    }
                }
                // Keychain 读取失败不能静默降级为空密码；否则真实的存储故障
                // 会被误报成远端认证失败，并反复重试浪费连接资源。
                let password = try credentialStore.password(forHost: host.id) ?? ""
                return .password(password)
            }
            let connectionManager = ConnectionManager(
                transport: transport,
                resolveAuth: authResolver,
                resolveJumpChain: { host in
                    var hops: [SSHJumpHop] = []
                    for (index, jumpID) in host.jumpChain.enumerated() {
                        guard let jumpHost = try hostStore.host(id: jumpID) else {
                            throw SSHError.jumpChainFailed(hopIndex: index, hopHost: jumpID)
                        }
                        let auth = try await authResolver(jumpHost)
                        hops.append(SSHJumpHop(
                            endpoint: SSHEndpoint(host: jumpHost.address, port: jumpHost.port),
                            username: jumpHost.username,
                            auth: auth
                        ))
                    }
                    return hops
                }
            )
            let terminalSessions = TerminalSessionCoordinator(
                hostRepository: hostStore,
                connectionManager: connectionManager,
                resumeRepository: PersistentTerminalResumeStore(database: database)
            )
            let snippetExecutionPlanner = makeSnippetExecutionPlanner(
                connectionManager: connectionManager
            )

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
                snippetExecutionPlanner: snippetExecutionPlanner,
                diagnosticsTransport: transport,
                monitor: monitor,
                runHistory: runHistoryStore,
                snippetRepository: snippetStore,
                snippetGroupRepository: snippetGroupStore,
                terminalSessions: terminalSessions,
                appLock: AppLockController(
                    authenticator: LABiometricAuthenticator(),
                    // 设置页持久化的开关；DEBUG 冒烟可强制开启验证锁屏。
                    isEnabled: UserDefaults.standard.bool(forKey: AppLockController.storageKey)
                        || ProcessInfo.processInfo.environment["CONN_SMOKE_APPLOCK"] != nil
                )
            )
    }

    #if DEBUG
    /// 演示依赖（**仅 DEBUG 编译**）：内存库 + Mock 引擎（假指标/容器/日志）。
    /// 不进入发行包——仅供开发期截图与冒烟联调（`CONN_DEMO` / `CONN_SMOKE_*`）。
    /// 演示数据由 `DemoData` 生成并经 `MockSSHTransport.dynamicResponder` 注入。
    static func demo() -> AppDependencies {
        do {
            let database = try AppDatabase.inMemory()
            let hostStore = makeHostStore(database: database)
            let groupStore = HostGroupStore(database: database)
            let keyStore = SSHKeyStore(database: database)
            try DemoData.seedHosts(into: hostStore, groups: groupStore)

            let transport = MockSSHTransport(behavior: DemoData.behavior())
            let credentialStore = InMemoryCredentialStore()
            let connectionManager = ConnectionManager(transport: transport) { _ in .password("demo") }
            let isResumeSmoke =
                ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_RESUME"] != nil
            let resumeProvider = TerminalResumeSmokeProvider()
            let resumeRecords: [PersistentTerminalResumeRecord]
            if isResumeSmoke, let host = try hostStore.allHosts().first {
                resumeRecords = [PersistentTerminalResumeRecord(
                    id: "smoke-resume",
                    hostID: host.id,
                    hostName: host.name,
                    hostAddress: host.displayAddress,
                    descriptor: resumeProvider.attachmentDescriptor,
                    automaticAlias: "saved-session"
                )]
            } else {
                resumeRecords = []
            }
            let terminalSessions = TerminalSessionCoordinator(
                hostRepository: hostStore,
                connectionManager: connectionManager,
                providerRegistry: isResumeSmoke
                    ? try PersistentTerminalProviderRegistry(providers: [resumeProvider])
                    : .default,
                resumeRepository: InMemoryTerminalResumeRepository(records: resumeRecords)
            )
            let snippetExecutionPlanner = makeSnippetExecutionPlanner(
                connectionManager: connectionManager
            )
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
                snippetExecutionPlanner: snippetExecutionPlanner,
                diagnosticsTransport: transport,
                monitor: monitor,
                runHistory: runHistoryStore,
                snippetRepository: snippetStore,
                snippetGroupRepository: snippetGroupStore,
                terminalSessions: terminalSessions,
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

    nonisolated private static func makeHostStore(database: AppDatabase) -> HostStore {
        HostStore(database: database)
    }

    /// 按数据库中的目录版本和稳定 key 导入内置命令。旧 UserDefaults 标记只作为
    /// v1 → v2 的迁移输入：先 suppression 原十条 key，避免随机 id 遗留项被复制。
    private static func importBuiltinSnippetsIfNeeded(
        _ store: SnippetStore,
        _ groups: SnippetGroupStore
    ) throws {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: SettingsStore.builtinSnippetsImportedKey),
           try store.builtinCatalogVersion() == 0 {
            try BuiltinSnippets.adoptLegacyImport(in: store)
        }
        _ = try BuiltinSnippets.importIfNeeded(into: store, groups: groups)
        defaults.set(true, forKey: SettingsStore.builtinSnippetsImportedKey)
    }
}
