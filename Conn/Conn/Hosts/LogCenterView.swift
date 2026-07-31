import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import Observation
import SwiftUI

/// 日志中心 ViewModel（Phase 8）：一趟探测出该机存在的日志源。
@Observable
@MainActor
final class LogCenterViewModel {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    private(set) var sources: [LogSource] = []
    /// 首次加载后置真——切换分段时不再自动重探（日志源基本静态）。
    private(set) var hasLoaded = false

    private let host: Host
    private let connectionManager: ConnectionManager

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        connectionManager = dependencies.connectionManager
    }

    /// 仅首次加载（分段出现时调用）。已加载则跳过。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        hasLoaded = true
        loadState = .loading
        do {
            let session = try await connectionManager.session(for: host)
            let output = try await session.exec(LogPresets.discoveryCommand).stdoutText
            sources = LogPresets.parseDiscovery(output)
            loadState = .ready
        } catch {
            if let sshError = error as? SSHError {
                loadState = .failed(sshError.diagnosis.split(separator: "\n").first.map(String.init) ?? L("连接失败"))
            } else {
                loadState = .failed(error.friendlyDiagnosis)
            }
        }
    }
}

/// 日志中心（Phase 8）：journalctl / 常见日志文件快捷入口。
struct LogCenterView: View {
    // VM 由详情级持有（HostDetailView）——切换分段时不重建、不重探（改按需/重试）。
    let viewModel: LogCenterViewModel
    @State private var selectedSource: LogSource?
    private let host: Host
    private let dependencies: AppDependencies

    init(host: Host, dependencies: AppDependencies, viewModel: LogCenterViewModel) {
        self.host = host
        self.dependencies = dependencies
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .task { await viewModel.loadIfNeeded() }
            .navigationDestination(item: $selectedSource) { source in
                LogStreamView(host: host, dependencies: dependencies, source: source)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView(L("探测日志源…")).font(.connFootnote).foregroundStyle(.connMuted)
                .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xxl)
        case let .failed(message):
            VStack(spacing: ConnSpacing.sm) {
                ConnBanner(message, systemImage: "exclamationmark.triangle")
                Button(L("重试")) { Task { await viewModel.load() } }.font(.connBody).foregroundStyle(.connAccent)
            }
            .padding(.vertical, ConnSpacing.md)
        case .ready:
            sourceList
        }
    }

    private var sourceList: some View {
        ScrollView {
            VStack(spacing: ConnSpacing.sm) {
                if viewModel.sources.isEmpty {
                    Text(L("未发现常见日志源。\n可在终端里直接查看自定义路径。"))
                        .font(.connSubheadline).foregroundStyle(.connMuted).multilineTextAlignment(.center)
                        .padding(.vertical, ConnSpacing.xl)
                } else {
                    ForEach(viewModel.sources) { source in
                        Button { selectedSource = source } label: { row(source) }
                            .buttonStyle(ConnPressStyle())
                    }
                }
            }
            .padding(.bottom, ConnSpacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }

    private func row(_ source: LogSource) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: icon(for: source.kind))
                .font(.system(size: 18)).foregroundStyle(.connAccent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(.connSubheadline).foregroundStyle(.connInk)
                Text(source.subtitle).font(.connData(.caption2)).foregroundStyle(.connMuted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.connMuted)
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private func icon(for kind: LogSource.Kind) -> String {
        switch kind {
        case .journal: "list.bullet.rectangle"
        case .file: "doc.text"
        case .container: "shippingbox"
        case .compose: "square.stack.3d.up"
        }
    }
}
