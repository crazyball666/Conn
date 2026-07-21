import ConnKit
import ConnSSH
import ConnUI
import SwiftUI

/// 连接诊断树（原型 S16）。
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tester: ConnectionTester
    private let host: Host
    private let username: String
    private let auth: SSHAuth

    init(host: Host, username: String, auth: SSHAuth, transport: any SSHTransport) {
        self.host = host
        self.username = username
        self.auth = auth
        _tester = State(initialValue: ConnectionTester(transport: transport))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ConnSpacing.md) {
                    targetHeader
                    stepList
                    if !tester.isRunning {
                        resultBanner
                    }
                }
                .padding(ConnSpacing.page)
            }
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle("连接诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await runTest() }
        }
    }

    private var targetHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.name).font(.connHeadline).foregroundStyle(.connInk)
            // 端口用 String(host.port) 而非插值：SwiftUI 的 \(Int) 会按 locale
            // 加千分位（2201 → "2,201"），端口号绝不能有分隔符。
            Text("\(username)@\(host.address):\(String(host.port))")
                .font(.connData())
                .foregroundStyle(.connMuted)
        }
    }

    private var stepList: some View {
        VStack(spacing: ConnSpacing.xs) {
            ForEach(tester.steps) { step in
                stepCard(step)
            }
        }
    }

    private func stepCard(_ step: DiagnosticStep) -> some View {
        ConnCard {
            HStack(alignment: .top, spacing: ConnSpacing.sm) {
                stepIcon(step.state)
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(.connBody)
                        .foregroundStyle(.connInk)
                    if let detail = step.detail {
                        Text(detail)
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ state: DiagnosticStep.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.connDim)
        case .running:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.connGood)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.connCrit)
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        if tester.succeeded {
            ConnBanner("连接成功，主机可达", systemImage: "checkmark.circle", kind: .info)
        } else {
            ConnBanner("连接未通过，请按上方提示排查", systemImage: "exclamationmark.triangle", kind: .warn)
        }
    }

    private func runTest() async {
        await tester.run(host: host, username: username, auth: auth)
    }
}
