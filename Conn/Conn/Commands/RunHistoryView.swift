import ConnKit
import ConnUI
import SwiftUI

/// 执行历史（审计，Phase 8/9）：容器操作与片段执行的本地记录。
struct RunHistoryView: View {
    private let dependencies: AppDependencies
    @State private var entries: [RunHistoryEntry] = []
    @State private var hostNames: [String: String] = [:]

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    var body: some View {
        ScrollView {
            if entries.isEmpty {
                EmptyState(
                    systemName: "clock.arrow.circlepath",
                    title: L("还没有执行记录"),
                    message: L("容器操作与片段执行会记录在这里")
                )
                .padding(.top, ConnSpacing.xxl)
            } else {
                LazyVStack(spacing: ConnSpacing.sm) {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                .padding(ConnSpacing.page)
            }
        }
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("执行历史"))
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func row(_ entry: RunHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hostNames[entry.hostUUID] ?? L("主机"))
                    .font(.connFootnote).foregroundStyle(.connMuted)
                Spacer()
                if entry.state != .known || entry.exitCode == nil {
                    Text(L("结果未知"))
                        .font(.connData(.caption2)).foregroundStyle(.connMuted)
                } else if let code = entry.exitCode {
                    Text("exit \(code)")
                        .font(.connData(.caption2)).connTabularNumbers()
                        .foregroundStyle(entry.isSuccess ? .connGood : .connCrit)
                }
                Text(timeText(entry.ranAt)).font(.connData(.caption2)).foregroundStyle(.connMuted)
            }
            VStack(alignment: .leading, spacing: ConnSpacing.xxs) {
                Text(entry.interpreter.displayName)
                    .font(.connData(.caption2))
                    .foregroundStyle(.connAccent)
                Text(entry.script)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.connInk)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private func load() {
        entries = (try? dependencies.runHistory.recent(hostUUID: nil, limit: 100)) ?? []
        let hosts = (try? dependencies.hostRepository.allHosts()) ?? []
        hostNames = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0.name) })
    }

    private func timeText(_ millis: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = ConnLanguage.currentLocale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Timestamp.date(from: millis), relativeTo: Date())
    }
}
