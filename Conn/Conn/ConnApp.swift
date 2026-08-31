import ConnCrypto
import ConnEntitlement
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
    }

    /// 生产依赖使用 Citadel + GRDB 落盘库。
    private static func makeDependencies() -> BootstrapState {
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
                case .loading:
                    DatabaseInitializationLoadingView()
                case .failed(let message):
                    DatabaseInitializationFailureView(message: message, retry: retryBootstrap)
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

    private func retryBootstrap() {
        bootstrap = .loading
        Task { @MainActor in
            // 先让 SwiftUI 提交 loading 状态，避免同步初始化失败时看起来没有响应。
            await Task.yield()
            do {
                try AppDependencies.resetLocalDatabase()
                bootstrap = Self.makeDependencies()
            } catch {
                bootstrap = .failed(error.friendlyDiagnosis)
            }
        }
    }

    @ViewBuilder
    private func rootView(dependencies: AppDependencies) -> some View {
        RootTabView(dependencies: dependencies)
    }
}

/// 生产依赖的启动状态。数据库初始化失败时保留在可恢复页面，避免 Release 直接崩溃。
private enum BootstrapState {
    case ready(AppDependencies)
    case loading
    case failed(String)
}

/// 重试本地数据初始化时的明确反馈，避免同步失败造成按钮看似无响应。
private struct DatabaseInitializationLoadingView: View {
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(L("正在重新加载本地数据…"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("database.initialization.loading")
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

/// 本地数据无法打开时的恢复页。
private struct DatabaseInitializationFailureView: View {
    let message: String
    let retry: () -> Void
    @State private var isShowingDetails = false

    var body: some View {
        GeometryReader { geometry in
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
                    .accessibilityIdentifier("database.failure.retry")

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
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("database.failure.content")
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

/// 依赖容器。
///
/// 技术实现方案 §1.1：**禁止单例直取**——所有跨层交互经协议注入，
/// 保证测试可整体替换数据层与传输层。
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
    /// 持久化 TOFU 主机指纹库。与 CitadelTransport 共用同一实例，供确认轮换时条件覆盖。
    let hostKeyStore: any HostKeyStore
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
    /// App Store 订阅状态与 Pro 权益门控。
    let subscription: SubscriptionStore

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
            let subscription = SubscriptionStore.appDefault()
            subscription.start()

            return AppDependencies(
                hostRepository: hostStore,
                hostGroupRepository: groupStore,
                keyRepository: keyStore,
                credentialStore: credentialStore,
                connectionManager: connectionManager,
                snippetExecutionPlanner: snippetExecutionPlanner,
                diagnosticsTransport: transport,
                hostKeyStore: hostKeyStore,
                monitor: monitor,
                runHistory: runHistoryStore,
                snippetRepository: snippetStore,
                snippetGroupRepository: snippetGroupStore,
                terminalSessions: terminalSessions,
                appLock: AppLockController(
                    authenticator: LABiometricAuthenticator(),
                    // 设置页持久化的开关。
                    isEnabled: UserDefaults.standard.bool(forKey: AppLockController.storageKey)
                ),
                subscription: subscription
            )
    }

    static func resetLocalDatabase() throws {
        try AppDatabase.removeOnDiskStore(at: databaseURL())
    }

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
