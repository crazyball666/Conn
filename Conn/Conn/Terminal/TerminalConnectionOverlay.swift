import ConnKit
import ConnTerminal
import ConnUI
import SwiftUI
import UIKit

/// 新建连接和重连共用的阶段卡片。
///
/// 终端页会先出现，卡片覆盖在终端画布上；失败时卡片保留在页面上，用户可以直接重试
/// 或关闭，不需要回到上一页再猜是哪一步失败。
struct TerminalConnectionOverlay: View {
    let activity: TerminalConnectionActivity?
    let host: Host
    let onCancel: () -> Void
    let onRetry: (() -> Void)?

    @State private var showsLogs = false

    private var isFailed: Bool {
        activity?.state == .failed
    }

    var body: some View {
        ZStack {
            Color.connTermBg.opacity(0.86)
                .ignoresSafeArea()
            VStack(spacing: ConnSpacing.md) {
                Spacer(minLength: 0)
                card
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.top, ConnSpacing.xl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.connection.overlay")
        .task {
            // The sheet that started this connection can still be dismissing,
            // so retry after its keyboard animation has settled.
            for delay in [0, 250, 650] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.md) {
            header
            titleRow
            stageList
            if let error = activity?.errorMessage, !error.isEmpty {
                errorRow(error)
            }
            logs
            actions
        }
        .padding(ConnSpacing.page)
        .background(
            Color.connSurface,
            in: RoundedRectangle(cornerRadius: ConnRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.card, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
    }

    private var header: some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.connAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name.isEmpty ? host.address : host.name)
                    .font(.connHeadline)
                    .foregroundStyle(.connInk)
                    .lineLimit(1)
                Text(host.displayAddress)
                    .font(.connData(.caption2))
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: ConnSpacing.sm)
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            if isFailed {
                Image(systemName: "xmark.circle.fill")
            } else if activity?.state == .connected {
                Image(systemName: "checkmark.circle.fill")
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor)
            }
            Text(statusText)
                .font(.connCaption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(titleText)
                .font(.connSectionTitle)
                .foregroundStyle(.connInk)
            Spacer()
            if let activity {
                elapsedText(from: activity.startedAt)
                    .font(.connData(.caption))
                    .foregroundStyle(.connMuted)
            }
        }
    }

    private func elapsedText(from start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 0.1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            Text(String(format: "%.1fs", elapsed))
        }
    }

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stageRow(step, isLast: index == steps.count - 1)
            }
        }
    }

    private var steps: [TerminalConnectionStep] {
        activity?.steps ?? TerminalConnectionStepID.allCases.map { TerminalConnectionStep(id: $0) }
    }

    private func stageRow(_ step: TerminalConnectionStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: ConnSpacing.sm) {
            VStack(spacing: 0) {
                stageIcon(step.state)
                    .frame(width: 26, height: 26)
                if !isLast {
                    Rectangle()
                        .fill(step.state == .completed ? Color.connGood.opacity(0.55) : Color.connLine)
                        .frame(width: 2, height: 22)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stageTitle(step.id, activity: activity))
                    .font(.connSubheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(step.state == .pending ? .connMuted : .connInk)
                if let detail = step.detail ?? stageDetail(step, activity: activity), !detail.isEmpty {
                    Text(detail)
                        .font(.connFootnote)
                        .foregroundStyle(step.state == .failed ? .connCrit : .connMuted)
                        .lineLimit(2)
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
            if let durationMs = step.durationMs, step.state == .completed {
                Text(String(format: "%.1fs", Double(durationMs) / 1000))
                    .font(.connData(.caption2))
                    .foregroundStyle(.connMuted)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.connection.stage.\(step.id.rawValue)")
    }

    @ViewBuilder
    private func stageIcon(_ state: TerminalConnectionStepState) -> some View {
        switch state {
        case .pending:
            Circle()
                .strokeBorder(Color.connMuted.opacity(0.5), lineWidth: 1.5)
                .frame(width: 20, height: 20)
        case .active:
            ProgressView()
                .controlSize(.small)
                .tint(.connAccent)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.connGood)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 21))
                .foregroundStyle(.connCrit)
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: ConnSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.connCrit)
            Text(message)
                .font(.connFootnote)
                .foregroundStyle(.connCrit)
                .lineLimit(4)
        }
        .padding(ConnSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.connCrit.opacity(0.08), in: RoundedRectangle(cornerRadius: ConnRadius.control))
    }

    @ViewBuilder
    private var logs: some View {
        let entries = activity?.logs ?? []
        if !entries.isEmpty {
            DisclosureGroup(isExpanded: $showsLogs) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: ConnSpacing.xs) {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.connData(.caption2))
                                    .foregroundStyle(.connTermDim)
                                Text(entry.message)
                                    .font(.connData(.caption2))
                                    .foregroundStyle(logColor(entry.level))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(.top, ConnSpacing.xs)
            } label: {
                HStack(spacing: ConnSpacing.xs) {
                    Image(systemName: "text.alignleft")
                    Text(L("日志"))
                    Text("\(entries.count)")
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.connMuted.opacity(0.12), in: Capsule())
                }
                .font(.connCaption)
                .foregroundStyle(.connInk)
            }
            .tint(.connMuted)
        }
    }

    private var actions: some View {
        HStack(spacing: ConnSpacing.sm) {
            Button(role: .cancel) {
                onCancel()
            } label: {
                Text(L("取消"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("terminal.connection.cancel")

            if isFailed, let onRetry {
                Button {
                    onRetry()
                } label: {
                    Text(L("重试"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("terminal.connection.retry")
            }
        }
    }

    private var statusText: String {
        guard let activity else { return L("连接中…") }
        switch activity.state {
        case .connecting: return activity.kind == .reconnect ? L("正在重连") : L("连接中…")
        case .connected: return L("已连接")
        case .failed: return L("连接失败")
        case .cancelled: return L("取消")
        }
    }

    private var statusColor: Color {
        guard let activity else { return .connAccent }
        switch activity.state {
        case .connecting: return activity.kind == .reconnect ? .connWarn : .connAccent
        case .connected: return .connGood
        case .failed: return .connCrit
        case .cancelled: return .connMuted
        }
    }

    private var titleText: String {
        guard let activity else { return L("连接中…") }
        switch activity.state {
        case .failed:
            return L("连接失败")
        case .connected:
            return L("已连接")
        case .cancelled:
            return L("取消")
        case .connecting:
            return activity.kind == .reconnect ? L("正在重连") : L("连接中…")
        }
    }

    private func stageTitle(
        _ id: TerminalConnectionStepID,
        activity: TerminalConnectionActivity?
    ) -> String {
        switch id {
        case .profile: activity?.routeLabel ?? "Headscale"
        case .credential: L("凭据")
        case .state: L("节点")
        case .route:
            if activity?.steps.contains(where: { $0.id == .profile }) == true {
                L("路由")
            } else {
                activity?.routeLabel ?? L("网络")
            }
        case .socks: "SOCKS"
        case .network: "SSH"
        case .authentication: L("认证")
        case .shell: L("终端")
        case .ready: L("已连接")
        }
    }

    private func stageDetail(
        _ step: TerminalConnectionStep,
        activity: TerminalConnectionActivity?
    ) -> String? {
        switch step.id {
        case .profile: activity?.routeDetail
        case .credential: "Keychain"
        case .state: activity?.routeDetail
        case .route:
            activity?.steps.contains(where: { $0.id == .profile }) == true
                ? nil
                : activity?.routeDetail
        case .socks: nil
        case .network: activity?.routeLabel == nil ? host.displayAddress : "SSH"
        case .authentication: nil
        case .shell: "PTY"
        case .ready: nil
        }
    }

    private func logColor(_ level: TerminalConnectionLogLevel) -> Color {
        switch level {
        case .info: .connTermFg
        case .success: .connGood
        case .error: .connCrit
        }
    }
}
