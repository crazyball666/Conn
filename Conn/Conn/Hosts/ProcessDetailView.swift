import ConnKit
import ConnMonitor
import ConnUI
import SwiftUI
import UIKit

/// 单进程详情：运维视角的完整信息（属主 / 状态 / 线程 / RSS / 运行时长 / 完整命令行）
/// + 结束进程。值随采集实时刷新（按 PID 从最新快照回读），进程退出后回落为入场快照。
struct ProcessDetailView: View {
    let process: RemoteProcess
    let viewModel: HostOverviewViewModel

    @State private var commandExpanded = false
    @State private var killTarget: RemoteProcess?
    @State private var resultMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                usageSection
                infoSection
                commandSection
                killButton
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(live.command)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(KillProcessAlert(viewModel: viewModel, target: $killTarget, result: $resultMessage))
    }

    /// 最新快照里的同 PID 进程；已退出则回落入场快照。
    private var live: RemoteProcess {
        viewModel.processes.first { $0.pid == process.pid } ?? process
    }

    // MARK: - 占用

    private var usageSection: some View {
        section(L("占用")) {
            HStack(spacing: 0) {
                usageColumn("CPU", String(format: "%.1f%%", live.cpu), warn: live.cpu > ConnThreshold.warn)
                columnDivider
                usageColumn(L("内存"), String(format: "%.1f%%", live.mem), warn: live.mem > ConnThreshold.warn)
                columnDivider
                usageColumn(L("常驻内存"), MetricFormat.bytes(live.memBytes), warn: false)
            }
        }
    }

    private func usageColumn(_ label: String, _ value: String, warn: Bool) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .connTabularNumbers().foregroundStyle(warn ? Color.connWarn : .connInk)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var columnDivider: some View {
        Rectangle().fill(Color.connLine).frame(width: 0.5, height: 30)
    }

    // MARK: - 信息

    private var infoSection: some View {
        section(L("信息")) {
            infoRows([
                (L("进程 PID"), String(live.pid)),
                (L("父进程 PID"), live.ppid.map(String.init) ?? "—"),
                (L("属主"), live.user ?? "—"),
                (L("状态"), ProcessFormat.stateDetail(live.state)),
                (L("线程数"), live.threads.map(String.init) ?? "—"),
                (L("运行时长"), MetricFormat.duration(live.elapsedSeconds))
            ])
        }
    }

    // MARK: - 命令行（终端风代码块 + 复制 + 折叠）

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack {
                Text(L("命令行")).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
                Spacer()
                Button {
                    UIPasteboard.general.string = commandText
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.connAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("复制命令"))
            }
            codeBlock
            if isLongCommand {
                Button(commandExpanded ? L("收起") : L("展开全部")) {
                    withAnimation(.easeInOut(duration: 0.2)) { commandExpanded.toggle() }
                }
                .font(.connData(.caption2)).foregroundStyle(.connAccent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            }
        }
    }

    private var codeBlock: some View {
        Text(commandText)
            .font(.connData(.caption2)).foregroundStyle(.connTermFg)
            .lineSpacing(3)
            .textSelection(.enabled)
            .lineLimit(commandExpanded ? nil : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ConnSpacing.cardPadding)
            .background(Color.connTermBg, in: .rect(cornerRadius: ConnRadius.card, style: .continuous))
    }

    private var commandText: String { live.fullCommand ?? live.command }

    /// 折叠阈值：长命令（如采集脚本本身）默认收起，避免整屏刷屏。
    private var isLongCommand: Bool {
        commandText.count > 140 || commandText.contains("\n")
    }

    private var killButton: some View {
        Button {
            killTarget = live
        } label: {
            Label(L("结束进程"), systemImage: "xmark.octagon")
                .font(.connBody).foregroundStyle(.connCrit)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ConnSpacing.sm)
                .connSurface(cornerRadius: ConnRadius.control)
        }
        .buttonStyle(.plain)
        .padding(.top, ConnSpacing.xs)
    }

    // MARK: - 通用块

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(title).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                content()
            }
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .connSurface(cornerRadius: ConnRadius.card)
        }
    }

    private func infoRows(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(Color.connLine).frame(height: 0.5)
                }
                HStack(spacing: ConnSpacing.sm) {
                    Text(row.0).font(.connSubheadline).foregroundStyle(.connMuted)
                    Spacer()
                    Text(row.1).font(.connData()).connTabularNumbers().foregroundStyle(.connInk)
                        .lineLimit(1).minimumScaleFactor(0.6).multilineTextAlignment(.trailing)
                }
                .padding(.vertical, ConnSpacing.sm)
            }
        }
    }
}

/// 进程展示格式化（状态码 → 本地化标签）。
enum ProcessFormat {
    /// `stat` 首字符 → 中文状态标签。
    static func stateLabel(_ code: String?) -> String {
        guard let first = code?.first else { return "—" }
        switch first {
        case "R": return L("运行")
        case "S": return L("睡眠")
        case "D": return L("不可中断")
        case "Z": return L("僵尸")
        case "T", "t": return L("停止")
        case "I": return L("空闲")
        case "X", "x": return L("死亡")
        default: return String(code ?? "—")
        }
    }

    /// 「睡眠（Ssl）」——标签 + 原始码，保留 s/l/+ 等修饰位供进阶排查。
    static func stateDetail(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "—" }
        return "\(stateLabel(code))（\(code)）"
    }
}
