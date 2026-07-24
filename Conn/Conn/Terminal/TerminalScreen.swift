import ConnKit
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// 单个主机的终端会话屏。
///
/// Phase 4a：单会话直连。多标签会话中心（S4）在 Phase 4b。
struct TerminalScreen: View {
    let host: Host
    let connectionManager: ConnectionManager
    /// 连接就绪后自动发送的命令（仅 DEBUG 冒烟用，验证中文渲染）。
    let autoCommand: String?

    @State private var phase: Phase = .connecting

    init(host: Host, connectionManager: ConnectionManager, autoCommand: String? = nil) {
        self.host = host
        self.connectionManager = connectionManager
        self.autoCommand = autoCommand
    }

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        connectionManager = dependencies.connectionManager
        autoCommand = nil
    }

    enum Phase {
        case connecting
        case ready(TerminalSession)
        case failed(String)
    }

    var body: some View {
        ZStack {
            Color.connTermBg.ignoresSafeArea()
            switch phase {
            case .connecting:
                connecting
            case let .ready(session):
                TerminalHostingView(session: session, theme: .conn)
                    .ignoresSafeArea(.container, edges: .bottom)
            case let .failed(message):
                failure(message)
            }
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await connect() }
    }

    private var connecting: some View {
        VStack(spacing: ConnSpacing.sm) {
            ProgressView().controlSize(.large).tint(.connAccent)
            Text(String(format: L("正在连接 %@…"), host.name))
                .font(.connData())
                .foregroundStyle(.connMuted)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: ConnSpacing.sm) {
            Image(systemName: "xmark.octagon").font(.system(size: 40)).foregroundStyle(.connCrit)
            Text(message)
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ConnSpacing.xl)
        }
    }

    private func connect() async {
        do {
            let session = try await connectionManager.session(for: host)
            let channel = try await session.openShell(term: TermSize(cols: 80, rows: 24))
            let terminalSession = TerminalSession(channel: channel)
            phase = .ready(terminalSession)

            if let autoCommand {
                // 等 shell 就绪后自动发一条命令（冒烟：验证中文渲染）
                Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    await terminalSession.send([UInt8]("\(autoCommand)\n".utf8))
                }
            }
        } catch let error as SSHError {
            phase = .failed(error.diagnosis)
        } catch {
            phase = .failed("连接失败：\(error.localizedDescription)")
        }
    }
}
