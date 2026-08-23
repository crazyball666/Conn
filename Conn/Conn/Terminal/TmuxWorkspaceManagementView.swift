import ConnMultiplexer
import ConnSSH
import ConnUI
import SwiftUI

/// Provider-specific tmux management surface. It consumes the normalized topology and
/// submits typed operations; no tmux command syntax is constructed in the App target.
struct TmuxWorkspaceManagementView: View {
    private struct PendingSharedOperation {
        let operation: TmuxOperation
        let impact: TmuxOperationImpact
    }

    private enum RenameTarget: Identifiable {
        case session(TmuxSessionID)
        case window(TmuxWindowID)

        var id: String {
            switch self {
            case let .session(id): "session:\(id.rawValue)"
            case let .window(id): "window:\(id.rawValue)"
            }
        }
    }

    private enum ClientSelection: Identifiable {
        case window(TmuxWindowID, sessionID: TmuxSessionID)
        case pane(TmuxPaneID, sessionID: TmuxSessionID)

        var id: String {
            switch self {
            case let .window(id, sessionID): "window:\(sessionID.rawValue):\(id.rawValue)"
            case let .pane(id, sessionID): "pane:\(sessionID.rawValue):\(id.rawValue)"
            }
        }

        var sessionID: TmuxSessionID {
            switch self {
            case let .window(_, sessionID), let .pane(_, sessionID): sessionID
            }
        }
    }

    let hostName: String
    let catalog: any TmuxWorkspaceCatalogManaging

    @State private var snapshot: TmuxServerSnapshot?
    @State private var issue: String?
    @State private var renameTarget: RenameTarget?
    @State private var pendingClientSelection: ClientSelection?
    @State private var renameText = ""
    @State private var pendingDestructive: TmuxPreparedDestructiveOperation?
    @State private var pendingSharedOperation: PendingSharedOperation?
    @State private var isConfirmingDestructive = false
    @State private var isConfirmingSharedOperation = false
    @State private var isRenaming = false

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot {
                    topologyList(snapshot)
                } else {
                    ProgressView(L("正在加载 tmux 拓扑…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(String(format: L("%@ · tmux"), hostName))
            .navigationBarTitleDisplayMode(.inline)
            .task { await observeTopology() }
            .alert(L("tmux 管理失败"), isPresented: Binding(
                get: { issue != nil },
                set: { if !$0 { issue = nil } }
            )) {
                Button(L("确定"), role: .cancel) { issue = nil }
            } message: {
                Text(issue ?? L("未知错误"))
            }
            .sheet(item: $renameTarget) { target in
                renameSheet(target)
            }
            .confirmationDialog(
                L("选择要控制的 Conn 终端"),
                isPresented: Binding(
                    get: { pendingClientSelection != nil },
                    set: { if !$0 { pendingClientSelection = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let selection = pendingClientSelection, let snapshot {
                    ForEach(interactiveClients(
                        for: selection.sessionID,
                        snapshot: snapshot
                    )) { client in
                        Button(clientLabel(client)) {
                            execute(selection, for: client)
                            pendingClientSelection = nil
                        }
                    }
                }
                Button(L("取消"), role: .cancel) {
                    pendingClientSelection = nil
                }
            } message: {
                Text(L("同一 Session 关联多个 Conn 终端，请选择需要操作的终端。"))
            }
            .alert(
                destructiveTitle,
                isPresented: $isConfirmingDestructive,
            ) {
                Button(L("确认执行"), role: .destructive) {
                    guard let pendingDestructive else { return }
                    Task { await executeDestructive(pendingDestructive) }
                }
                Button(L("取消"), role: .cancel) {
                    pendingDestructive = nil
                }
            } message: {
                Text(destructiveMessage)
            }
            .confirmationDialog(
                L("确认共享 tmux 操作"),
                isPresented: $isConfirmingSharedOperation,
                titleVisibility: .visible
            ) {
                Button(L("继续执行")) {
                    guard let pendingSharedOperation else { return }
                    Task { await executeSharedOperation(pendingSharedOperation) }
                }
                Button(L("取消"), role: .cancel) {
                    pendingSharedOperation = nil
                }
            } message: {
                Text(sharedOperationMessage)
            }
        }
    }

    @ViewBuilder
    private func topologyList(_ snapshot: TmuxServerSnapshot) -> some View {
        List {
            if let warnings = managementWarnings(snapshot), !warnings.isEmpty {
                Section(L("兼容性与隔离状态")) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.connCaption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if snapshot.sessions.isEmpty {
                ContentUnavailableView(
                    L("暂无 tmux Session"),
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text(L("可返回终端创建流程并新建 Session。"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(sortedSessions(snapshot)) { session in
                    sessionSection(session, snapshot: snapshot)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func sessionSection(
        _ session: TmuxSessionSnapshot,
        snapshot: TmuxServerSnapshot
    ) -> some View {
        Section {
            ForEach(snapshot.windows(in: session.id), id: \.self) { windowID in
                if let window = snapshot.windows[windowID] {
                    windowRow(window, session: session, snapshot: snapshot)
                }
            }
            Button {
                submit(.createWindow(in: session.id, name: nil))
            } label: {
                Label(L("新建 Window"), systemImage: "plus.rectangle")
            }
        } header: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.connSubheadline)
                        .foregroundStyle(.connInk)
                    Text(session.id.rawValue)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                }
                Spacer()
                Menu {
                    Button {
                        beginRename(.session(session.id), currentName: session.name)
                    } label: {
                        Label(L("重命名"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        requestDestructive(.killSession(session.id))
                    } label: {
                        Label(L("终止 Session"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.connMuted)
                }
            }
        }
    }

    @ViewBuilder
    private func windowRow(
        _ window: TmuxWindowSnapshot,
        session: TmuxSessionSnapshot,
        snapshot: TmuxServerSnapshot
    ) -> some View {
        DisclosureGroup {
            ForEach(snapshot.panes(in: window.id), id: \.self) { paneID in
                if let pane = snapshot.panes[paneID] {
                    paneRow(pane, window: window, session: session, snapshot: snapshot)
                }
            }
            HStack {
                Button {
                    submit(.createWindow(in: session.id, name: nil))
                } label: {
                    Label(L("新建 Window"), systemImage: "plus")
                }
                Spacer()
                Button {
                    requestClientSelection(
                        .window(window.id, sessionID: session.id),
                        snapshot: snapshot
                    )
                } label: {
                    Label(L("切换"), systemImage: "arrow.right")
                }
                .disabled(interactiveClients(for: session.id, snapshot: snapshot).isEmpty)
            }
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: window.isZoomed ? "arrow.down.right.and.arrow.up.left" : "rectangle.split.2x1")
                    .foregroundStyle(.connAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.name).foregroundStyle(.connInk)
                    Text(window.id.rawValue)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                }
                Spacer()
                Menu {
                    Button {
                        beginRename(.window(window.id), currentName: window.name)
                    } label: {
                        Label(L("重命名"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        requestDestructive(.killWindow(window.id))
                    } label: {
                        Label(L("关闭 Window"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.connMuted)
                }
            }
        }
    }

    @ViewBuilder
    private func paneRow(
        _ pane: TmuxPaneSnapshot,
        window: TmuxWindowSnapshot,
        session: TmuxSessionSnapshot,
        snapshot: TmuxServerSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: pane.id == window.activePaneID ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(pane.id == window.activePaneID ? .connAccent : .connMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title.value ?? String(format: L("Pane %d"), pane.index))
                        .foregroundStyle(.connInk)
                    Text(pane.currentCommand.value ?? pane.id.rawValue)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    Button {
                        requestClientSelection(
                            .pane(pane.id, sessionID: session.id),
                            snapshot: snapshot
                        )
                    } label: {
                        Label(L("切换到 Pane"), systemImage: "arrow.right")
                    }
                    .disabled(interactiveClients(for: session.id, snapshot: snapshot).isEmpty)
                    Button {
                        submit(.splitPane(pane.id, orientation: .horizontal))
                    } label: {
                        Label(L("左右分屏"), systemImage: "rectangle.split.2x1")
                    }
                    Button {
                        submit(.splitPane(pane.id, orientation: .vertical))
                    } label: {
                        Label(L("上下分屏"), systemImage: "rectangle.split.1x2")
                    }
                    Button {
                        submit(.setPaneZoom(pane.id, zoomed: !window.isZoomed))
                    } label: {
                        Label(window.isZoomed ? L("取消 Zoom") : L("Zoom Pane"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button(role: .destructive) {
                        requestDestructive(.killPane(pane.id))
                    } label: {
                        Label(L("关闭 Pane"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.connMuted)
                }
            }
            Text(String(format: L("%d×%d · %@"), pane.size.cols, pane.size.rows, pane.currentPath.value ?? L("路径未知")))
                .font(.connData(.caption2))
                .foregroundStyle(.connMuted)
                .padding(.leading, 24)
        }
        .padding(.vertical, ConnSpacing.xs)
    }

    private func renameSheet(_ target: RenameTarget) -> some View {
        NavigationStack {
            Form {
                TextField(L("名称"), text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L("保存")) {
                    saveRename(target)
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRenaming)
            }
            .navigationTitle(L("重命名"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { renameTarget = nil }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var destructiveTitle: String {
        guard let pendingDestructive else { return L("确认远程操作") }
        switch pendingDestructive.impact.target {
        case .session: return L("确认终止 Session")
        case .window: return L("确认关闭 Window")
        case .pane: return L("确认关闭 Pane")
        default: return L("确认远程操作")
        }
    }

    private var destructiveMessage: String {
        guard let impact = pendingDestructive?.impact else { return "" }
        return String(
            format: L("将影响 %d 个 Session、%d 个 Window、%d 个 Pane，可能影响 %d 个其他连接。"),
            impact.affectedSessionIDs.count,
            impact.affectedWindowIDs.count,
            impact.affectedPaneIDs.count,
            impact.otherAffectedClientIDs.count
        )
    }

    private var sharedOperationMessage: String {
        guard let impact = pendingSharedOperation?.impact else { return "" }
        let sessionIDs = impact.affectedSessionIDs.map(\.rawValue).joined(separator: ", ")
        let windowIDs = impact.affectedWindowIDs.map(\.rawValue).joined(separator: ", ")
        let clientIDs = impact.otherAffectedClientIDs.map(\.targetName).joined(separator: ", ")
        var parts = [String(format: L("该操作会修改 tmux 共享状态，影响 %d 个 Session。"), impact.affectedSessionIDs.count)]
        if !sessionIDs.isEmpty { parts.append(String(format: L("Session：%@。"), sessionIDs)) }
        if !windowIDs.isEmpty { parts.append(String(format: L("Window：%@。"), windowIDs)) }
        if !clientIDs.isEmpty { parts.append(String(format: L("其他连接：%@。"), clientIDs)) }
        return parts.joined(separator: " ")
    }

    private func observeTopology() async {
        for await next in catalog.topology {
            guard !Task.isCancelled else { return }
            snapshot = next
        }
    }

    private func sortedSessions(_ snapshot: TmuxServerSnapshot) -> [TmuxSessionSnapshot] {
        snapshot.sessions.values.sorted {
            $0.name == $1.name ? $0.id.rawValue < $1.id.rawValue : $0.name < $1.name
        }
    }

    private func managementWarnings(_ snapshot: TmuxServerSnapshot) -> [String]? {
        let capabilities = catalog.controlCapabilities
        let configuration = catalog.controlConfiguration
        var warnings: [String] = []

        if !capabilities.supportedClientFlags.contains(.activePane) {
            warnings.append(L("当前 tmux 不支持 active-pane，切换 Pane 可能改变其他客户端看到的活动 Pane。"))
        } else if snapshot.clients.values.contains(where: { client in
            guard case .connInteractive = client.role else { return false }
            return client.flags?.contains(.activePane) != true
        }) {
            warnings.append(L("部分 Conn 终端尚未启用 Pane 焦点隔离，系统会在下一次拓扑同步时重试。"))
        }

        if !capabilities.supportedClientFlags.contains(.ignoreSize) {
            warnings.append(L("当前 tmux 不支持 ignore-size，多客户端同时连接时窗口尺寸可能互相影响。"))
        } else if snapshot.clients.values.contains(where: { client in
            guard case .connInteractive = client.role else { return false }
            let hasOtherVoter = snapshot.clients.values.contains { other in
                guard other.id != client.id else { return false }
                if case .connControl = other.role { return false }
                return other.sizeParticipation == .participating
                    || other.sizeParticipation == .unknown
            }
            return hasOtherVoter && client.flags?.contains(.ignoreSize) != true
        }) {
            warnings.append(L("检测到多个尺寸参与者，但部分 Conn 终端尚未隔离窗口尺寸，系统会自动重试。"))
        }

        for flag in [TmuxClientFlag.noOutput, .waitExit]
            where capabilities.supportedClientFlags.contains(flag)
                && !configuration.enabledClientFlags.contains(flag)
        {
            warnings.append(String(format: L("Control Mode 支持 %@，但本次连接未成功启用。"), flag.rawValue))
        }

        let requiredSubscriptions: Set<String> = [
            "__conn_session_attached__",
            "__conn_pane_title__",
            "__conn_pane_current_command__",
            "__conn_pane_current_path__",
        ]
        if !capabilities.supportsFormatSubscriptions {
            warnings.append(L("当前 tmux 不支持格式订阅，Pane 元数据使用按需快照，可能不是实时值。"))
        } else if !requiredSubscriptions.isSubset(of: configuration.activeSubscriptionNames) {
            warnings.append(L("部分 tmux 格式订阅未启用，Pane 元数据可能降级为快照。"))
        }
        if let metadataWarning = metadataFreshnessWarning(snapshot) {
            warnings.append(metadataWarning)
        }
        return warnings.isEmpty ? nil : warnings
    }

    private func metadataFreshnessWarning(_ snapshot: TmuxServerSnapshot) -> String? {
        let freshness = snapshot.panes.values.flatMap { pane in
            [pane.title.freshness, pane.currentCommand.freshness, pane.currentPath.freshness]
        }
        guard !freshness.isEmpty else { return nil }
        if freshness.allSatisfy({
            if case .liveSubscription = $0 { return true }
            return false
        }) { return nil }
        if freshness.contains(where: {
            if case .stale = $0 { return true }
            if case .unavailable = $0 { return true }
            return false
        }) {
            return L("部分 Pane 标题、命令或路径不可用或已过期，请刷新拓扑后再使用这些信息。")
        }
        return L("Pane 标题、命令或路径来自最近快照；订阅首次更新后会切换为实时状态。")
    }

    private func interactiveClients(
        for sessionID: TmuxSessionID,
        snapshot: TmuxServerSnapshot
    ) -> [TmuxClientSnapshot] {
        snapshot.clients.values.filter { client in
            guard client.sessionID == sessionID,
                  client.kind == .interactiveTerminal
            else { return false }
            if case .connInteractive = client.role { return true }
            return false
        }.sorted { lhs, rhs in
            lhs.id.targetName == rhs.id.targetName
                ? (lhs.id.processID ?? 0) < (rhs.id.processID ?? 0)
                : lhs.id.targetName < rhs.id.targetName
        }
    }

    private func requestClientSelection(
        _ selection: ClientSelection,
        snapshot: TmuxServerSnapshot
    ) {
        let clients = interactiveClients(for: selection.sessionID, snapshot: snapshot)
        guard let client = clients.first else { return }
        if clients.count == 1 {
            execute(selection, for: client)
        } else {
            pendingClientSelection = selection
        }
    }

    private func execute(_ selection: ClientSelection, for client: TmuxClientSnapshot) {
        guard let target = try? TmuxClientTarget(client.id.targetName) else { return }
        switch selection {
        case let .window(windowID, _): submit(.selectWindow(windowID, for: target))
        case let .pane(paneID, _): submit(.selectPane(paneID, for: target))
        }
    }

    private func clientLabel(_ client: TmuxClientSnapshot) -> String {
        guard let processID = client.id.processID else { return client.id.targetName }
        return "\(client.id.targetName) · PID \(processID)"
    }

    private func beginRename(_ target: RenameTarget, currentName: String) {
        renameText = currentName
        renameTarget = target
    }

    private func saveRename(_ target: RenameTarget) {
        guard let name = try? TmuxName(renameText) else {
            issue = L("名称不能为空或包含控制字符")
            return
        }
        renameTarget = nil
        isRenaming = true
        switch target {
        case let .session(id): submit(.renameSession(id, to: name))
        case let .window(id): submit(.renameWindow(id, to: name))
        }
        isRenaming = false
    }

    private func submit(_ operation: TmuxOperation) {
        Task {
            do {
                let impact = try await catalog.previewImpact(operation)
                if requiresSharedConfirmation(impact) {
                    pendingSharedOperation = PendingSharedOperation(
                        operation: operation,
                        impact: impact
                    )
                    isConfirmingSharedOperation = true
                } else {
                    try await catalog.execute(operation)
                }
            } catch {
                issue = error.friendlyDiagnosis
            }
        }
    }

    private func requiresSharedConfirmation(_ impact: TmuxOperationImpact) -> Bool {
        impact.isVisibleAcrossSessions || !impact.otherAffectedClientIDs.isEmpty
    }

    private func executeSharedOperation(_ pending: PendingSharedOperation) async {
        do {
            let latestImpact = try await catalog.previewImpact(pending.operation)
            guard latestImpact == pending.impact else {
                pendingSharedOperation = PendingSharedOperation(
                    operation: pending.operation,
                    impact: latestImpact
                )
                isConfirmingSharedOperation = requiresSharedConfirmation(latestImpact)
                if !isConfirmingSharedOperation {
                    try await catalog.execute(pending.operation)
                    pendingSharedOperation = nil
                }
                return
            }
            try await catalog.execute(pending.operation)
            pendingSharedOperation = nil
        } catch {
            pendingSharedOperation = nil
            issue = error.friendlyDiagnosis
        }
    }

    private func requestDestructive(_ operation: TmuxOperation) {
        Task {
            do {
                pendingDestructive = try await catalog.prepareDestructive(operation)
                isConfirmingDestructive = true
            } catch {
                issue = error.friendlyDiagnosis
            }
        }
    }

    private func executeDestructive(_ prepared: TmuxPreparedDestructiveOperation) async {
        do {
            try await catalog.executeDestructive(prepared)
            pendingDestructive = nil
        } catch {
            pendingDestructive = nil
            issue = error.friendlyDiagnosis
        }
    }
}
