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
            RootTabView(hostStore: dependencies.hostRepository)
                // 深色是主人格（设计规范 §1：OLED + 运维人群夜间审美）。
                // Phase 11 接入「跟随系统 / 手动切换」的设置项。
                .preferredColorScheme(.dark)
        }
    }
}

/// 依赖容器。
///
/// 技术实现方案 §1.1：**禁止单例直取**——所有跨层交互经协议注入，
/// 保证演示模式与测试可整体替换数据层与传输层。
struct AppDependencies {
    let hostRepository: any HostRepository
    /// 连接池管理器。Phase 3 的主机详情、Phase 7 的监控采集经它取会话。
    let connectionManager: ConnectionManager

    /// 生产依赖：GRDB 落盘库 + Citadel 引擎 + 持久化 TOFU 指纹库。
    static func live() -> AppDependencies {
        do {
            let database = try AppDatabase.onDisk(at: databaseURL())
            let store = HostStore(database: database)
            try seedIfNeeded(store)

            // SSH 栈：Citadel 引擎 + GRDB 指纹库（TOFU 跨重启留存）。
            // 凭据解析（AuthResolver）留待 Phase 5 接 Keychain；当前默认空密码，
            // 意味着连真实服务器会认证失败——这是预期的，真正的 App 内连接
            // 随 Phase 3 主机表单 + Phase 5 Keychain 一起到位。
            let hostKeyStore = GRDBHostKeyStore(database: database)
            let transport = CitadelTransport(hostKeyStore: hostKeyStore)
            let connectionManager = ConnectionManager(transport: transport)

            return AppDependencies(hostRepository: store, connectionManager: connectionManager)
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
