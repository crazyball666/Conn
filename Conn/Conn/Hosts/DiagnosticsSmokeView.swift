#if DEBUG
    import ConnKit
    import ConnSSH
    import ConnSSHCitadel
    import SwiftUI

    /// DEBUG-only 冒烟：直接对 Spike 容器跑一次连接诊断，用于开发期验证
    /// 「App 内真连一台服务器」。通过 `CONN_SMOKE_DIAGNOSTICS` 环境变量启用，
    /// 不影响正常启动路径。发布构建不含此文件。
    struct DiagnosticsSmokeView: View {
        let transport: any SSHTransport

        private var host: Host {
            Host(name: "spike-ubuntu22", address: "127.0.0.1", username: "deploy", port: 2201)
        }

        var body: some View {
            DiagnosticsView(
                host: host,
                username: "deploy",
                auth: .password("conntest123"),
                transport: transport
            )
        }
    }
#endif
