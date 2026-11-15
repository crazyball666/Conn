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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isFailed: Bool {
        activity?.state == .failed
    }

    private var focusedStepID: TerminalConnectionStepID? {
        activity?.failedStep?.id ?? activity?.activeStep?.id
    }

    private let logsToggleID = "terminal.connection.logs-toggle"
    private let maximumStageListHeight: CGFloat = 242

    var body: some View {
        ZStack {
            Color.connTermBg.opacity(0.86)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }
                .accessibilityHidden(true)
            card
                .frame(maxWidth: 420)
                .padding(.horizontal, ConnSpacing.page)
                .padding(.vertical, ConnSpacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.connection.overlay")
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: ConnRadius.card, style: .continuous)
        return VStack(spacing: ConnSpacing.xs) {
            ViewThatFits(in: .vertical) {
                cardContent(stages: stageSection)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollViewReader { proxy in
                    ScrollView {
                        cardContent(stages: stageList)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: focusedStepID, initial: true) { oldID, newID in
                        guard !showsLogs, let newID else { return }
                        withAnimation(oldID == newID || reduceMotion ? nil : ConnMotion.enter) {
                            proxy.scrollTo(newID)
                        }
                    }
                    .onChange(of: showsLogs, initial: true) { oldValue, newValue in
                        if newValue {
                            withAnimation(oldValue == newValue || reduceMotion ? nil : ConnMotion.enter) {
                                proxy.scrollTo(logsToggleID, anchor: .top)
                            }
                        }
                    }
                }
            }

            actions
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .padding(ConnSpacing.md)
        .background(Color.connSurface, in: shape)
        .overlay {
            flowingBorder(shape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.24), radius: ConnSpacing.md, y: ConnSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.connection.card")
    }

    private func flowingBorder(_ shape: RoundedRectangle) -> some View {
        let isAnimating = activity?.state == .connecting && !reduceMotion
        let color = activity?.kind == .reconnect && activity?.state == .connecting
            ? Color.connWarn : statusColor
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { context in
            let angle = isAnimating
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) * 180
                : 0
            shape.strokeBorder(
                AngularGradient(
                    colors: [color.opacity(0.15), color, color.opacity(0.15),
                             color.opacity(0.8), color.opacity(0.15)],
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: 2
            )
            .shadow(color: color.opacity(0.35), radius: 8)
        }
    }

    private func cardContent<Stages: View>(stages: Stages) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.sm) {
            header
            titleRow
            stages
            if let error = activity?.errorMessage, !error.isEmpty {
                errorRow(error)
            }
            logs
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.connection.content")
    }

    private var header: some View {
        HStack(spacing: ConnSpacing.sm) {
            IconChip("terminal", tint: .accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ConnSpacing.xxs) {
                Text(host.name.isEmpty ? host.address : host.name)
                    .font(.connHeadline)
                    .foregroundStyle(.connInk)
                    .lineLimit(2)
                Text(host.displayAddress)
                    .font(.connData(.caption2))
                    .foregroundStyle(.connMuted)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ConnSpacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ConnSpacing.sm))
        return layout {
            Text(statusText)
                .font(.connSectionTitle)
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if let activity {
                Group {
                    if let endedAt = activity.endedAt {
                        elapsedLabel(from: activity.startedAt, to: endedAt)
                    } else {
                        elapsedText(from: activity.startedAt)
                    }
                }
                .font(.connData(.caption))
                .foregroundStyle(.connMuted)
            }
        }
    }

    private func elapsedText(from start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 0.1)) { context in
            elapsedLabel(from: start, to: context.date)
        }
    }

    private func elapsedLabel(from start: Date, to end: Date) -> some View {
        let elapsed = max(0, end.timeIntervalSince(start))
        return Text(String(format: "%.1fs", elapsed))
    }

    @ViewBuilder
    private var stageSection: some View {
        if steps.count > 6 {
            ScrollViewReader { proxy in
                ScrollView {
                    stageList
                }
                .frame(height: maximumStageListHeight)
                .scrollIndicators(.hidden)
                .onChange(of: focusedStepID, initial: true) { previous, current in
                    guard let current else { return }
                    withAnimation(previous == current || reduceMotion ? nil : ConnMotion.enter) {
                        proxy.scrollTo(current)
                    }
                }
            }
        } else {
            stageList
        }
    }

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stageRow(step, hasPrevious: index > 0, hasNext: index < steps.count - 1)
                    .id(step.id)
            }
        }
    }

    private var steps: [TerminalConnectionStep] {
        activity?.steps ?? TerminalConnectionStepID.allCases.map { TerminalConnectionStep(id: $0) }
    }

    private func stageRow(
        _ step: TerminalConnectionStep,
        hasPrevious: Bool,
        hasNext: Bool
    ) -> some View {
        let detail = step.detail ?? stageDetail(step, activity: activity)
        let duration = step.state == .completed ? step.durationMs : nil
        let highlight = switch step.state {
        case .active: Color.connAccentFill
        case .failed: Color.connCritFill
        default: Color.clear
        }
        return HStack(alignment: .center, spacing: ConnSpacing.sm) {
            stageIcon(step.state)
                .id(step.state)
                .transition(.opacity)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ConnSpacing.xxs) {
                Text(stageTitle(step.id, activity: activity))
                    .font(.connSubheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(stageTitleColor(step.state))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.connFootnote)
                        .foregroundStyle(step.state == .failed ? .connCrit : .connMuted)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
                if typeSize.isAccessibilitySize, let duration {
                    stepDuration(duration)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !typeSize.isAccessibilitySize, let duration {
                stepDuration(duration)
            }
        }
        .padding(.horizontal, ConnSpacing.xs)
        .padding(.vertical, ConnSpacing.xxs)
        .frame(minHeight: ConnSize.minTouchTarget)
        .background(alignment: .leading) {
            VStack(spacing: 0) {
                Rectangle().fill(hasPrevious ? Color.connLine : Color.clear)
                Color.clear.frame(height: 24)
                Rectangle().fill(hasNext ? Color.connLine : Color.clear)
            }
            .frame(width: 2)
            .frame(width: 24)
            .padding(.leading, ConnSpacing.xs)
            .accessibilityHidden(true)
        }
        .background(highlight, in: .rect(cornerRadius: ConnRadius.control))
        .animation(reduceMotion ? nil : ConnMotion.enter, value: step.state)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stageAccessibilityValue(step.state))
        .accessibilityIdentifier("terminal.connection.stage.\(step.id.rawValue)")
    }

    private func stageAccessibilityValue(_ state: TerminalConnectionStepState) -> String {
        switch state {
        case .pending: ""
        case .active: L("处理中…")
        case .completed: L("完成")
        case .failed: L("连接失败")
        }
    }

    private func stageTitleColor(_ state: TerminalConnectionStepState) -> Color {
        switch state {
        case .pending: .connMuted
        case .active: .connAccent
        case .completed, .failed: .connInk
        }
    }

    private func stepDuration(_ milliseconds: Int) -> some View {
        Text(String(format: "%.1fs", Double(milliseconds) / 1000))
            .font(.connData(.caption2))
            .foregroundStyle(.connMuted)
            .fixedSize()
    }

    @ViewBuilder
    private func stageIcon(_ state: TerminalConnectionStepState) -> some View {
        switch state {
        case .pending:
            Circle()
                .strokeBorder(Color.connMuted, lineWidth: 1.5)
                .frame(width: 20, height: 20)
        case .active:
            if reduceMotion {
                Image(systemName: "circle.inset.filled")
                    .font(.system(size: 20))
                    .foregroundStyle(.connAccent)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.connAccent)
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.connGood)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
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
                .textSelection(.enabled)
        }
        .padding(ConnSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.connCrit.opacity(0.08), in: RoundedRectangle(cornerRadius: ConnRadius.control))
    }

    @ViewBuilder
    private var logs: some View {
        let entries = activity?.logs ?? []
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: ConnSpacing.xxs) {
                Button {
                    withAnimation(reduceMotion ? nil : ConnMotion.enter) {
                        showsLogs.toggle()
                    }
                } label: {
                    HStack(spacing: ConnSpacing.xs) {
                        Label(L("日志"), systemImage: "text.alignleft")
                            .font(.connSubheadline.weight(.medium))
                            .foregroundStyle(.connInk)
                        Text("\(entries.count)")
                            .font(.connData(.caption2))
                            .foregroundStyle(.connMuted)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.connCaption.weight(.semibold))
                            .foregroundStyle(.connMuted)
                            .rotationEffect(.degrees(showsLogs ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: ConnSize.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ConnPressStyle())
                .id(logsToggleID)
                .accessibilityIdentifier(logsToggleID)
                .accessibilityAddTraits(showsLogs ? .isSelected : [])

                if showsLogs {
                    VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                        ForEach(entries) { entry in
                            logRow(entry)
                        }
                    }
                    .padding(ConnSpacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.connBg, in: .rect(cornerRadius: ConnRadius.control))
                    .transition(.opacity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("terminal.connection.logs-content")
                }
            }
        }
    }

    private func logRow(_ entry: TerminalConnectionLogEntry) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ConnSpacing.xxs))
            : AnyLayout(HStackLayout(alignment: .top, spacing: ConnSpacing.xs))
        return layout {
            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.connMuted)
                .fixedSize()
            Text(entry.message)
                .foregroundStyle(entry.level == .error ? .connCrit : .connInk)
                .textSelection(.enabled)
        }
        .font(.connData(.caption2))
    }

    private var actions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: ConnSpacing.xs))
            : AnyLayout(HStackLayout(spacing: ConnSpacing.xs))
        return layout {
            Button(role: .cancel) {
                onCancel()
            } label: {
                Text(L("取消"))
                    .font(.connSubheadline.weight(.medium))
                    .foregroundStyle(.connInk)
                    .padding(.vertical, ConnSpacing.xxs)
                    .frame(maxWidth: .infinity, minHeight: ConnSize.minTouchTarget)
                    .background {
                        RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                            .strokeBorder(Color.connLine, lineWidth: 1)
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(ConnPressStyle())
            .accessibilityIdentifier("terminal.connection.cancel")

            if isFailed, let onRetry {
                Button {
                    onRetry()
                } label: {
                    Text(L("重试"))
                        .font(.connSubheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, ConnSpacing.xxs)
                        .frame(maxWidth: .infinity, minHeight: ConnSize.minTouchTarget)
                        .background(Color.connAccentDeep, in: .rect(cornerRadius: ConnRadius.control))
                        .contentShape(.rect)
                }
                .buttonStyle(ConnPressStyle())
                .accessibilityIdentifier("terminal.connection.retry")
            }
        }
        // 连接成功后卡片会短暂停留再淡出，这段时间不再允许取消/重试，
        // 但保留占位避免卡片高度跳变。
        .opacity(activity?.state == .connected ? 0 : 1)
        .allowsHitTesting(activity?.state != .connected)
        .accessibilityHidden(activity?.state == .connected)
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
        case .connecting: return .connAccent
        case .connected: return .connGood
        case .failed: return .connCrit
        case .cancelled: return .connMuted
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
        case .authentication: "SSH"
        case .shell: "PTY"
        case .ready: L("就绪")
        }
    }
}
