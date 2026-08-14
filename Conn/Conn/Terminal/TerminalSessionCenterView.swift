import ConnKit
import ConnMultiplexer
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// 全局终端会话中心。只展示已成功建立的 PTY，会话仍由全局协调器持有。
struct TerminalSessionCenterView: View {
    private struct TerminalRoute: Identifiable {
        let host: Host
        let tabID: String?
        var id: String { tabID ?? "new:\(host.id)" }
        var launchPolicy: TerminalLaunchPolicy {
            tabID.map { .existing(tabID: $0) } ?? .createNew
        }
    }

    private struct PendingTerminalOpen {
        let host: Host
        let tabID: String?
    }

    private struct CatalogKey: Hashable, Identifiable {
        let hostID: String
        let providerID: String
        let profileID: String

        var id: String { "\(hostID):\(providerID):\(profileID)" }
    }

    private struct SessionCenterHostGroup: Identifiable {
        let hostID: String
        let hostName: String
        let hostAddress: String
        let tabs: [TerminalTab]

        var id: String { hostID }
    }

    private struct ManagementRoute: Identifiable {
        let group: SessionCenterHostGroup
        let catalogKey: CatalogKey

        var id: String { catalogKey.id }
    }

    @MainActor
    private final class CatalogHandle {
        let attachment: any PersistentTerminalCatalogAttachment
        let tmux: (any TmuxWorkspaceCatalogManaging)?

        init(attachment: any PersistentTerminalCatalogAttachment) {
            self.attachment = attachment
            tmux = attachment as? any TmuxWorkspaceCatalogManaging
        }
    }

    let dependencies: AppDependencies
    @State private var hosts: [Host] = []
    @State private var expandedHostIDs: Set<String> = []
    @State private var isHostPickerPresented = false
    @State private var pendingTerminalOpen: PendingTerminalOpen?
    @State private var route: TerminalRoute?
    @State private var remoteCatalogs: [CatalogKey: PersistentWorkspaceCatalogSnapshot] = [:]
    @State private var catalogCandidates: [CatalogKey: PersistentBackendCandidate] = [:]
    @State private var catalogLoadingKeys: Set<CatalogKey> = []
    @State private var catalogLoadingHostIDs: Set<String> = []
    @State private var catalogIssues: [CatalogKey: String] = [:]
    @State private var catalogTasks: [CatalogKey: Task<Void, Never>] = [:]
    @State private var catalogLoadGenerations: [CatalogKey: UUID] = [:]
    @State private var catalogHandles: [CatalogKey: CatalogHandle] = [:]
    @State private var managementRoute: ManagementRoute?
    @Environment(\.connToastCenter) private var toastCenter

    private var sessions: TerminalSessionStore { dependencies.terminalSessions.store }

    private var displayedHostGroups: [SessionCenterHostGroup] {
        var groups = hosts.map { host in
            SessionCenterHostGroup(
                hostID: host.id,
                hostName: host.name,
                hostAddress: host.displayAddress,
                tabs: sessions.tabs(forHost: host.id)
            )
        }
        let knownHostIDs = Set(groups.map(\.hostID))
        groups += sessions.hostGroups
            .filter { !knownHostIDs.contains($0.hostID) }
            .map {
                SessionCenterHostGroup(
                    hostID: $0.hostID,
                    hostName: $0.hostName,
                    hostAddress: $0.hostAddress,
                    tabs: $0.tabs
                )
            }
        return groups
    }

    var body: some View {
        ScrollView {
            if displayedHostGroups.isEmpty {
                EmptyState(
                    systemName: "terminal",
                    title: L("还没有终端会话"),
                    message: L("从主机详情打开终端，或在这里新建一个会话。"),
                    primary: .init(L("新建终端")) { isHostPickerPresented = true }
                )
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
            } else {
                LazyVStack(alignment: .leading, spacing: ConnSpacing.md) {
                    ForEach(displayedHostGroups) { group in
                        hostGroup(group)
                    }
                }
                .padding(ConnSpacing.page)
            }
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("终端"))
        .task { loadHosts() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isHostPickerPresented = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("新建终端"))
            }
        }
        .sheet(isPresented: $isHostPickerPresented, onDismiss: openPendingTerminal) {
            TerminalHostPickerSheet(
                hostRepository: dependencies.hostRepository,
                sessionStore: sessions,
                onOpen: { host, tabID in
                    pendingTerminalOpen = PendingTerminalOpen(host: host, tabID: tabID)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $route) { route in
            TerminalScreen(
                host: route.host,
                dependencies: dependencies,
                launchPolicy: route.launchPolicy
            )
        }
        .onDisappear {
            Task { await closeAllCatalogs() }
        }
        .sheet(item: $managementRoute) { route in
            if let catalog = catalogHandles[route.catalogKey]?.tmux {
                TmuxWorkspaceManagementView(hostName: route.group.hostName, catalog: catalog)
            }
        }
    }

    private func hostGroup(_ group: SessionCenterHostGroup) -> some View {
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedHostIDs.contains(group.hostID) },
            set: { expanded in
                if expanded {
                    expandedHostIDs.insert(group.hostID)
                    Task { await loadCatalogs(for: group.hostID) }
                } else {
                    expandedHostIDs.remove(group.hostID)
                    Task { await closeCatalogs(for: group.hostID) }
                }
            }
        )) {
            VStack(spacing: 0) {
                ForEach(group.tabs) { tab in
                    Button { openExisting(tab) } label: {
                        sessionRow(tab)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.rect)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await dependencies.terminalSessions.close(tab.id) }
                        } label: {
                            Label(L("关闭会话"), systemImage: "xmark.circle")
                        }
                    }
                    if tab.id != group.tabs.last?.id {
                        Divider().padding(.leading, 36)
                    }
                }
                remoteWorkspaceSection(for: group)
            }
            .padding(.top, ConnSpacing.xs)
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.connAccent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.hostName)
                        .font(.connSubheadline)
                        .foregroundStyle(.connInk)
                    Text(group.hostAddress)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                }
                Spacer(minLength: 0)
                Text(String(format: L("%d 个会话"), group.tabs.count))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
        }
        .tint(.connMuted)
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private func sessionRow(_ tab: TerminalTab) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: sourceIcon(tab.source))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.connAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayName)
                    .font(.connSubheadline)
                    .foregroundStyle(.connInk)
                Text(sourceDescription(tab.source))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            sessionStatus(tab.status)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.connMuted)
        }
        .padding(.vertical, ConnSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func open(_ host: Host, tabID: String?) {
        route = TerminalRoute(host: host, tabID: tabID)
    }

    private func openPendingTerminal() {
        guard let pendingTerminalOpen else { return }
        self.pendingTerminalOpen = nil
        open(pendingTerminalOpen.host, tabID: pendingTerminalOpen.tabID)
    }

    private func openExisting(_ tab: TerminalTab) {
        guard let host = try? dependencies.hostRepository.host(id: tab.hostID) else {
            toastCenter.show(L("主机已不存在"))
            return
        }
        route = TerminalRoute(host: host, tabID: tab.id)
    }

    @ViewBuilder
    private func remoteWorkspaceSection(for group: SessionCenterHostGroup) -> some View {
        let keys = catalogKeys(for: group.hostID)
        if !keys.isEmpty {
            Divider().padding(.leading, 36)
            VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                ForEach(keys) { key in
                    catalogProfileSection(for: key, group: group)
                    if key != keys.last {
                        Divider().padding(.vertical, ConnSpacing.xs)
                    }
                }
            }
            .padding(.leading, 36)
            .padding(.top, ConnSpacing.xs)
        } else if catalogLoadingHostIDs.contains(group.hostID) {
            HStack(spacing: ConnSpacing.sm) {
                ProgressView().controlSize(.small)
                Text(L("正在加载远端会话…"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
            .padding(.leading, 36)
            .padding(.top, ConnSpacing.xs)
        }
    }

    @ViewBuilder
    private func catalogProfileSection(
        for key: CatalogKey,
        group: SessionCenterHostGroup
    ) -> some View {
        let candidate = catalogCandidates[key]
        let snapshot = remoteCatalogs[key]
        HStack(spacing: ConnSpacing.xs) {
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate?.displayName ?? key.providerID)
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                if let snapshot {
                    Text(catalogFreshness(snapshot.freshness))
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                }
            }
            Spacer()
            if shouldOfferCatalogRetry(key: key, snapshot: snapshot) {
                Button { retryCatalog(key) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.connAccent)
                .accessibilityLabel(L("重试"))
            }
        }

        if let snapshot {
            if snapshot.workspaces.isEmpty {
                Text(L("当前没有 Session"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                if candidate?.availability == .available || candidate?.availability == .degraded {
                    Button {
                        createRemoteWorkspace(catalogKey: key, group: group)
                    } label: {
                        Label(L("新建 Session"), systemImage: "plus.rectangle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.connAccent)
                }
            } else {
                ForEach(snapshot.workspaces, id: \.workspace.workspaceID) { workspace in
                    Button {
                        Task { await openRemoteWorkspace(workspace, snapshot: snapshot, group: group) }
                    } label: {
                        HStack(spacing: ConnSpacing.sm) {
                            Image(systemName: "rectangle.connected.to.line.below")
                                .foregroundStyle(.connAccent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspace.name)
                                    .font(.connSubheadline)
                                    .foregroundStyle(.connInk)
                                Text(String(format: L("远端 Session · %d 个连接"), workspace.occupancy.affectedAttachmentCount ?? 0))
                                    .font(.connFootnote)
                                    .foregroundStyle(.connMuted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundStyle(.connMuted)
                        }
                        .padding(.vertical, ConnSpacing.xs)
                    }
                    .buttonStyle(.plain)
                }
            }
            if catalogHandles[key]?.tmux != nil {
                Button {
                    managementRoute = ManagementRoute(group: group, catalogKey: key)
                } label: {
                    Label(L("打开 Window / Pane 管理"), systemImage: "rectangle.split.3x1")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.connAccent)
                .padding(.top, ConnSpacing.xs)
            }
        }

        if catalogLoadingKeys.contains(key) {
            HStack(spacing: ConnSpacing.xs) {
                ProgressView().controlSize(.small)
                Text(L("正在加载远端会话…"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
        }
        if let issue = catalogIssues[key] {
            Text(issue)
                .font(.connFootnote)
                .foregroundStyle(.connWarn)
        }
    }

    private func catalogKeys(for hostID: String) -> [CatalogKey] {
        catalogCandidates.keys
            .filter { $0.hostID == hostID }
            .sorted { lhs, rhs in
                let lhsName = catalogCandidates[lhs]?.displayName ?? lhs.providerID
                let rhsName = catalogCandidates[rhs]?.displayName ?? rhs.providerID
                return lhsName == rhsName ? lhs.id < rhs.id : lhsName < rhsName
            }
    }

    private func loadCatalogs(for hostID: String) async {
        guard !catalogLoadingHostIDs.contains(hostID),
              let host = try? dependencies.hostRepository.host(id: hostID)
        else { return }
        catalogLoadingHostIDs.insert(hostID)
        let candidates = await dependencies.terminalSessions.persistentBackendCandidates(for: host)
        guard expandedHostIDs.contains(hostID) else {
            catalogLoadingHostIDs.remove(hostID)
            return
        }

        let newKeys = Set(candidates.map {
            CatalogKey(hostID: hostID, providerID: $0.providerID, profileID: $0.profileID)
        })
        let obsoleteKeys = Set(catalogKeys(for: hostID)).subtracting(newKeys)
        for key in obsoleteKeys {
            await closeCatalog(key, clearSnapshot: true)
            catalogCandidates[key] = nil
            catalogIssues[key] = nil
        }

        for candidate in candidates {
            let key = CatalogKey(
                hostID: hostID,
                providerID: candidate.providerID,
                profileID: candidate.profileID
            )
            catalogCandidates[key] = candidate
            switch candidate.availability {
            case .available, .degraded:
                startCatalog(candidate: candidate, host: host, key: key)
            case .unavailable, .unsupported:
                catalogIssues[key] = candidate.issue?.friendlyDiagnosis ?? L("此持久终端配置不可用")
            }
        }
        catalogLoadingHostIDs.remove(hostID)
    }

    private func startCatalog(
        candidate: PersistentBackendCandidate,
        host: Host,
        key: CatalogKey
    ) {
        guard catalogTasks[key] == nil, catalogHandles[key] == nil else { return }
        let generation = UUID()
        catalogLoadGenerations[key] = generation
        catalogLoadingKeys.insert(key)
        catalogIssues[key] = nil
        catalogTasks[key] = Task { @MainActor in
            do {
                let attachment = try await dependencies.terminalSessions.openPersistentCatalog(
                    for: candidate,
                    host: host
                )
                guard !Task.isCancelled, catalogLoadGenerations[key] == generation else {
                    await attachment.close()
                    return
                }
                let handle = CatalogHandle(attachment: attachment)
                catalogHandles[key] = handle
                for await snapshot in attachment.snapshots {
                    guard !Task.isCancelled else { break }
                    guard catalogLoadGenerations[key] == generation else { break }
                    remoteCatalogs[key] = snapshot
                }
                let endedUnexpectedly = !Task.isCancelled
                    && catalogLoadGenerations[key] == generation
                    && catalogHandles[key] === handle
                if endedUnexpectedly {
                    markCatalogStale(key)
                    catalogIssues[key] = L("远端会话连接已结束，请重试")
                }
                if catalogHandles[key] === handle {
                    catalogHandles[key] = nil
                }
                await attachment.close()
            } catch {
                guard !Task.isCancelled, catalogLoadGenerations[key] == generation else { return }
                markCatalogStale(key)
                catalogIssues[key] = error.friendlyDiagnosis
            }
            guard catalogLoadGenerations[key] == generation else { return }
            catalogLoadingKeys.remove(key)
            catalogLoadGenerations[key] = nil
            catalogTasks[key] = nil
        }
    }

    private func retryCatalog(_ key: CatalogKey) {
        guard let candidate = catalogCandidates[key],
              let host = try? dependencies.hostRepository.host(id: key.hostID)
        else { return }
        Task {
            await closeCatalog(key)
            guard expandedHostIDs.contains(key.hostID) else { return }
            startCatalog(candidate: candidate, host: host, key: key)
        }
    }

    private func closeCatalog(
        _ key: CatalogKey,
        clearSnapshot: Bool = false
    ) async {
        catalogLoadGenerations[key] = nil
        catalogTasks.removeValue(forKey: key)?.cancel()
        catalogLoadingKeys.remove(key)
        let handle = catalogHandles.removeValue(forKey: key)
        if clearSnapshot {
            remoteCatalogs[key] = nil
        }
        if let handle {
            await handle.attachment.close()
        }
    }

    private func closeCatalogs(for hostID: String) async {
        let keys = Set(catalogCandidates.keys.filter { $0.hostID == hostID })
            .union(catalogTasks.keys.filter { $0.hostID == hostID })
            .union(catalogHandles.keys.filter { $0.hostID == hostID })
        for key in keys {
            await closeCatalog(key)
        }
        catalogLoadingHostIDs.remove(hostID)
    }

    private func closeAllCatalogs() async {
        let keys = Set(catalogCandidates.keys)
            .union(catalogTasks.keys)
            .union(catalogHandles.keys)
        for key in keys {
            await closeCatalog(key)
        }
        catalogLoadingHostIDs.removeAll()
    }

    private func markCatalogStale(_ key: CatalogKey) {
        guard let snapshot = remoteCatalogs[key] else { return }
        remoteCatalogs[key] = PersistentWorkspaceCatalogSnapshot(
            providerID: snapshot.providerID,
            profileID: snapshot.profileID,
            instance: snapshot.instance,
            workspaces: snapshot.workspaces,
            freshness: .stale(lastObservedAt: snapshot.observedAt),
            observedAt: snapshot.observedAt
        )
    }

    private func shouldOfferCatalogRetry(
        key: CatalogKey,
        snapshot: PersistentWorkspaceCatalogSnapshot?
    ) -> Bool {
        if catalogIssues[key] != nil { return true }
        guard let snapshot else { return false }
        return switch snapshot.freshness {
        case .stale, .unavailable: true
        case .liveSubscription, .snapshot: false
        }
    }

    private func loadHosts() {
        hosts = (try? dependencies.hostRepository.allHosts()) ?? []
    }

    private func openRemoteWorkspace(
        _ workspace: RemoteWorkspaceSummary,
        snapshot: PersistentWorkspaceCatalogSnapshot,
        group: SessionCenterHostGroup
    ) async {
        guard let host = try? dependencies.hostRepository.host(id: group.hostID) else {
            toastCenter.show(L("主机已不存在"))
            return
        }
        do {
            let descriptor = try await dependencies.terminalSessions.makePersistentAttachmentDescriptor(
                for: workspace.workspace,
                providerID: snapshot.providerID,
                profileID: snapshot.profileID,
                host: host
            )
            let result = await dependencies.terminalSessions.launch(
                TerminalLaunchRequest(
                    host: host,
                    policy: .createNew,
                    source: .persistent(providerID: snapshot.providerID),
                    backend: .persistent(descriptor)
                )
            )
            switch result {
            case let .success(tab):
                route = TerminalRoute(host: host, tabID: tab.id)
            case let .failure(failure):
                if let message = dependencies.terminalSessions.consumeFailure(failure) {
                    toastCenter.show(message)
                }
            }
        } catch {
            toastCenter.show(error.friendlyDiagnosis)
        }
    }

    private func createRemoteWorkspace(
        catalogKey: CatalogKey,
        group: SessionCenterHostGroup
    ) {
        guard let host = try? dependencies.hostRepository.host(id: group.hostID),
              let candidate = catalogCandidates[catalogKey]
        else {
            toastCenter.show(L("主机已不存在"))
            return
        }
        Task {
            do {
                let backend = try await dependencies.terminalSessions.makePersistentBackend(
                    from: candidate,
                    create: PersistentWorkspaceCreateSelection(),
                    for: host
                )
                let result = await dependencies.terminalSessions.launch(
                    TerminalLaunchRequest(
                        host: host,
                        policy: .createNew,
                        source: .persistent(providerID: candidate.providerID),
                        backend: backend
                    )
                )
                switch result {
                case let .success(tab):
                    retryCatalog(catalogKey)
                    route = TerminalRoute(host: host, tabID: tab.id)
                case let .failure(failure):
                    if let message = dependencies.terminalSessions.consumeFailure(failure) {
                        toastCenter.show(message)
                    }
                }
            } catch {
                toastCenter.show(error.friendlyDiagnosis)
            }
        }
    }

    private func catalogFreshness(_ freshness: PersistentWorkspaceCatalogFreshness) -> String {
        switch freshness {
        case .liveSubscription: L("实时")
        case .snapshot: L("快照")
        case .stale: L("已过期")
        case .unavailable: L("不可用")
        }
    }

    private func sourceIcon(_ source: TerminalSessionSource) -> String {
        switch source {
        case .shell: "terminal"
        case .docker: "shippingbox"
        case .script: "command"
        case .persistent: "rectangle.connected.to.line.below"
        }
    }

    private func sourceDescription(_ source: TerminalSessionSource) -> String {
        switch source {
        case .shell: L("普通终端")
        case let .docker(containerName): String(format: L("容器：%@"), containerName)
        case let .script(title): String(format: L("脚本：%@"), title)
        case let .persistent(providerID): String(format: L("持久终端：%@"), providerID)
        }
    }

    @ViewBuilder
    private func sessionStatus(_ status: TerminalTabStatus) -> some View {
        switch status {
        case .connected:
            Image(systemName: "circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.connGood)
        case .reconnecting:
            ProgressView().controlSize(.small)
        case .disconnected:
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.connWarn)
        }
    }
}

/// 选择主机后再选择复用已有会话或新建，避免“普通终端”入口意外开出重复 PTY。
private struct TerminalHostPickerSheet: View {
    let hostRepository: any HostRepository
    let sessionStore: TerminalSessionStore
    let onOpen: (Host, String?) -> Void

    @State private var hosts: [Host] = []
    @State private var searchText = ""
    @State private var selectedHost: Host?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(filteredHosts) { host in
                Button { selectedHost = host } label: {
                    HStack(spacing: ConnSpacing.sm) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.connAccent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.name).font(.connSubheadline).foregroundStyle(.connInk)
                            Text(host.displayAddress).font(.connData(.caption2)).foregroundStyle(.connMuted)
                        }
                        Spacer(minLength: 0)
                        let count = sessionStore.tabs(forHost: host.id).count
                        if count > 0 {
                            Text(String(format: L("%d 个会话"), count))
                                .font(.connFootnote)
                                .foregroundStyle(.connMuted)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.connMuted)
                    }
                    .padding(.vertical, ConnSpacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Expand the control itself as well as its label. SwiftUI's List
                // otherwise may keep the hit target to the intrinsic text width.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("选择主机"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: L("搜索主机名或地址"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
            }
            .task { loadHosts() }
            .alert(L("读取主机失败"), isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L("重试")) { loadHosts() }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $selectedHost) { host in
                TerminalHostActionSheet(
                    host: host,
                    tabs: sessionStore.tabs(forHost: host.id),
                    onOpen: { tabID in choose(host, tabID: tabID) }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var filteredHosts: [Host] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return hosts }
        return hosts.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.displayAddress.localizedCaseInsensitiveContains(needle)
        }
    }

    private func loadHosts() {
        do {
            hosts = try hostRepository.allHosts()
            errorMessage = nil
        } catch {
            errorMessage = error.friendlyDiagnosis
        }
    }

    /// 先完整撤掉“已有会话”与“选择主机”两层 sheet；外层的 `onDismiss` 才会
    /// 设置全屏终端路由，避免同一帧的 dismiss/present 竞争。
    private func choose(_ host: Host, tabID: String?) {
        selectedHost = nil
        onOpen(host, tabID)
        dismiss()
    }
}

private struct TerminalHostActionSheet: View {
    let host: Host
    let tabs: [TerminalTab]
    let onOpen: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !tabs.isEmpty {
                    Section(L("已有会话")) {
                        ForEach(tabs) { tab in
                            Button { onOpen(tab.id) } label: {
                                HStack {
                                    Text(tab.displayName)
                                        .foregroundStyle(.connInk)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                }
                Section {
                    Button {
                        onOpen(nil)
                    } label: {
                        Label(L("新建终端会话"), systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(L("新建会话会复用已建立的 SSH 连接，但创建独立的 PTY。"))
                }
            }
            .navigationTitle(host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
            }
        }
    }
}
