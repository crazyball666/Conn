import ConnKit
import ConnOps
import ConnUI
import SwiftUI

/// 日志流视图（Phase 8）：跟随、暂停、关键词过滤、error/warn 高亮。
struct LogStreamView: View {
    @State private var viewModel: LogStreamViewModel

    init(host: Host, dependencies: AppDependencies, source: LogSource, sudo: Bool = false) {
        _viewModel = State(initialValue: LogStreamViewModel(
            host: host, dependencies: dependencies, source: source, sudo: sudo
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider().overlay(Color.connLine)
            logArea
        }
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(viewModel.source.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var controlBar: some View {
        HStack(spacing: ConnSpacing.xs) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.connMuted)
            TextField(L("过滤关键词"), text: $viewModel.filterText)
                .font(.connData(.footnote))
                .foregroundStyle(.connInk)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                viewModel.isFollowing.toggle()
            } label: {
                Label(
                    viewModel.isFollowing ? L("跟随中") : L("已暂停"),
                    systemImage: viewModel.isFollowing ? "pause.circle" : "play.circle"
                )
                .font(.connFootnote)
                .foregroundStyle(viewModel.isFollowing ? .connAccent : .connMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.vertical, ConnSpacing.sm)
    }

    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let error = viewModel.errorText {
                    ConnBanner(error, systemImage: "exclamationmark.triangle")
                        .padding(ConnSpacing.page)
                } else if viewModel.isConnecting {
                    ProgressView(L("连接中…"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, ConnSpacing.xxl)
                }
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(viewModel.visibleLines) { line in
                        Text(line.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(color(for: line.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, ConnSpacing.page)
                .padding(.vertical, ConnSpacing.xs)
            }
            // #6：观测单调递增的末行 id，而非 lines.count——环缓冲满 5000 行后
            // count 恒为 5000 不再变化，onChange 不触发，跟随会假死。id 一直增。
            .onChange(of: viewModel.lines.last?.id) {
                guard viewModel.isFollowing else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private let bottomAnchor = "log-bottom"

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .error: .connCrit
        case .warn: .connWarn
        case .normal: .connInk
        }
    }
}
