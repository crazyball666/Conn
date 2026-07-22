import ConnCrypto
import ConnKit
import ConnSSH
import ConnSSHCitadel
import ConnStore
import SwiftUI

/// App 组装根：依赖注入、路由、场景生命周期（技术实现方案 §5）。
@main
struct ConnApp: App {
    private let dependencies = AppDependencies.live()

    var body: some Scene {
        WindowGroup {
            AppLockGate(lock: dependencies.appLock) {
                rootView
            }
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
            } else {
                RootTabView(dependencies: dependencies)
            }
        #else
            RootTabView(dependencies: dependencies)
        #endif
    }
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
    /// 连接池管理器。主机详情、Phase 7 的监控采集经它取会话。
    let connectionManager: ConnectionManager
    /// 连接测试用的传输层（与 connectionManager 同引擎，供诊断树直接调用）。
    let diagnosticsTransport: any SSHTransport
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

            return AppDependencies(
                hostRepository: hostStore,
                groupRepository: groupStore,
                keyRepository: keyStore,
                credentialStore: credentialStore,
                connectionManager: connectionManager,
                diagnosticsTransport: transport,
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
}
