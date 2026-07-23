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
                // 切换语言即 bump id → 整树重建，全 App 立即改语言（含各包 L() 读取）。
                rootView.id(localization.language)
            }
            .environment(localization)
            // 深色是主人格（设计规范 §1：OLED + 运维人群夜间审美）。
            // Phase 11 接入「跟随系统 / 手动切换」的设置项。
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
            if ProcessInfo.processInfo.environment["CONN_SMOKE_DIAGNOSTICS"] != nil {
                DiagnosticsSmokeView(transport: dependencies.diagnosticsTransport)
            } else if ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL"] != nil {
                NavigationStack {
                    TerminalScreen(
                        host: Host(name: "spike-ubuntu24", address: "127.0.0.1", username: "deploy", port: 2202),
                        // 冒烟专用：固定密码 resolver（正常路径走 Keychain）
                        connectionManager: ConnectionManager(
                            transport: dependencies.diagnosticsTransport
                        ) { _ in .password("conntest123") },
                        autoCommand: "echo '中文渲染测试 你好世界 café 日本語 🚀 制表符'; ls /"
                    )
                }
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
            default: .overview
            }
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
    let groupRepository: any HostGroupRepository
    let keyRepository: any SSHKeyRepository
    let credentialStore: any CredentialStore
    /// 连接池管理器。主机详情、监控采集、Docker/日志、片段执行都经它取会话。
    let connectionManager: ConnectionManager
    /// 连接测试用的传输层（与 connectionManager 同引擎，供诊断树直接调用）。
    let diagnosticsTransport: any SSHTransport
    /// 指标时序仓库（Phase 7）。离线快照 + 48h 原始样本。
    let metricStore: any MetricRepository
    /// 监控采集调度（Phase 7）。仪表盘 30s / 详情 3s。
    let monitor: MonitorScheduler
    /// 执行审计仓库（Phase 8/9）。容器启停、片段执行写入。
    let runHistory: any RunHistoryRepository
    /// 片段仓库（Phase 9）。首启导入内置模板库。
    let snippetRepository: any SnippetRepository
    /// 应用锁 + 隐私遮罩。默认关闭，设置页开启（Phase 5）。
    let appLock: AppLockController

    /// 生产依赖：GRDB 落盘库 + Citadel 引擎 + 持久化 TOFU 指纹库。
    static func live() -> AppDependencies {
        do {
            let database = try AppDatabase.onDisk(at: databaseURL())
            let hostStore = HostStore(database: database)
            let groupStore = HostGroupStore(database: database)
            let keyStore = SSHKeyStore(database: database)
            try seedIfNeeded(hostStore)

            // SSH 栈：Citadel 引擎 + GRDB 指纹库（TOFU 跨重启留存）。
            let hostKeyStore = GRDBHostKeyStore(database: database)
            let transport = CitadelTransport(hostKeyStore: hostKeyStore)
            let credentialStore = KeychainCredentialStore()
            let connectionManager = ConnectionManager(transport: transport) { host in
                // 从 Keychain 取该主机凭据（Phase 5 会扩展密钥/SE）
                let password = (try? credentialStore.password(forHost: host.id)) ?? ""
                return .password(password)
            }

            // 监控栈：指标仓库 + 采集调度。启动时清理超 48h 的原始样本。
            let metricStore = MetricStore(database: database)
            let cutoff = Timestamp.now() - 48 * 3600 * 1000
            try? metricStore.pruneSamples(olderThan: cutoff)
            let monitor = MonitorScheduler(connectionManager: connectionManager, store: metricStore)

            let snippetStore = SnippetStore(database: database)
            try importBuiltinSnippetsIfNeeded(snippetStore)

            return AppDependencies(
                hostRepository: hostStore,
                groupRepository: groupStore,
                keyRepository: keyStore,
                credentialStore: credentialStore,
                connectionManager: connectionManager,
                diagnosticsTransport: transport,
                metricStore: metricStore,
                monitor: monitor,
                runHistory: RunHistoryStore(database: database),
                snippetRepository: snippetStore,
                appLock: AppLockController(
                    authenticator: LABiometricAuthenticator(),
                    // DEBUG 冒烟可强制开启应用锁验证锁屏；正常默认关闭（设置页开启）
                    isEnabled: ProcessInfo.processInfo.environment["CONN_SMOKE_APPLOCK"] != nil
                )
            )
        } catch {
            // 数据库开不了是不可恢复的：此时 App 无法承载任何功能。
            // 与其静默降级成空界面，不如带着原因崩溃，便于用户导出诊断。
            fatalError("数据库初始化失败：\(error)")
        }
    }

    /// 演示依赖：内存库 + Mock 引擎（假指标/容器/日志）。无需任何服务器即可
    /// 完整体验监控/Docker/日志/片段（Phase 7–9），也是 App Store 审核走查路径。
    /// 演示数据由 `DemoData` 生成并经 `MockSSHTransport.dynamicResponder` 注入。
    static func demo() -> AppDependencies {
        do {
            let database = try AppDatabase.inMemory()
            let hostStore = HostStore(database: database)
            let groupStore = HostGroupStore(database: database)
            let keyStore = SSHKeyStore(database: database)
            try DemoData.seedHosts(into: hostStore)

            let transport = MockSSHTransport(behavior: DemoData.behavior())
            let credentialStore = InMemoryCredentialStore()
            let connectionManager = ConnectionManager(transport: transport) { _ in .password("demo") }
            let metricStore = MetricStore(database: database)
            let monitor = MonitorScheduler(connectionManager: connectionManager, store: metricStore)
            let snippetStore = SnippetStore(database: database)
            try importBuiltinSnippetsIfNeeded(snippetStore)

            return AppDependencies(
                hostRepository: hostStore,
                groupRepository: groupStore,
                keyRepository: keyStore,
                credentialStore: credentialStore,
                connectionManager: connectionManager,
                diagnosticsTransport: transport,
                metricStore: metricStore,
                monitor: monitor,
                runHistory: RunHistoryStore(database: database),
                snippetRepository: snippetStore,
                appLock: AppLockController(authenticator: LABiometricAuthenticator(), isEnabled: false)
            )
        } catch {
            fatalError("演示库初始化失败：\(error)")
        }
    }

    /// `Application Support/Conn/conn.sqlite`
    private static func databaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Conn/conn.sqlite")
    }

    /// 首次启动写入几台示例主机，让仪表盘不是空的。
    ///
    /// Phase 10 会用完整的演示模式（`MockSSHTransport` + 假指标发生器）替换它。
    private static func seedIfNeeded(_ store: HostStore) throws {
        guard try store.allHosts().isEmpty else { return }
        let samples = [
            Host(name: "web-01", address: "10.0.0.1", username: "root", tags: ["prod", "web"], status: .ok),
            Host(name: "db-master", address: "10.0.0.2", username: "root", tags: ["prod", "db"], status: .warn),
            Host(
                name: "cache-01",
                address: "10.0.0.3",
                username: "deploy",
                port: 2222,
                tags: ["staging"],
                status: .crit
            ),
            Host(name: "nas", address: "192.168.1.10", username: "admin", tags: ["home"], status: .unknown)
        ]
        for host in samples {
            try store.save(host)
        }
    }

    /// 首启把内置模板库导入 `snippet` 表（幂等：已有片段则跳过）。
    private static func importBuiltinSnippetsIfNeeded(_ store: SnippetStore) throws {
        guard try store.count() == 0 else { return }
        for snippet in BuiltinSnippets.load() {
            try store.save(snippet)
        }
    }
}
