import ConnKit
import ConnUI
import SwiftUI

/// 主机列表（原型 S2）：连接管理入口。
/// 主机表单的呈现请求：新增（editingHostID == nil）或编辑一台已有主机。
struct HostFormRequest: Identifiable {
    let id = UUID()
    let draft: HostDraft
    let editingHostID: String?
}

struct HostListView: View {
    @State private var viewModel: HostListViewModel
    @State private var formRequest: HostFormRequest?
    @State private var pendingDelete: Host?
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _viewModel = State(initialValue: HostListViewModel(
            hostStore: dependencies.hostRepository,
            groupStore: dependencies.groupRepository
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if viewModel.hosts.isEmpty {
                    emptyState
                } else {
                    searchBar
                    if !viewModel.allTags.isEmpty {
                        tagFilter
                    }
                    if viewModel.isAtFreeLimit {
                        limitBanner
                    }
                    hostSections
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.connBg.ignoresSafeArea())
        .task { viewModel.load() }
        .sheet(item: $formRequest) { request in
            HostFormView(
                dependencies: dependencies,
                initialDraft: request.draft,
                editingHostID: request.editingHostID
            ) {
                viewModel.load()
            }
        }
        .confirmationDialog(
            L("删除主机"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { host in
            Button(L("删除"), role: .destructive) {
                viewModel.delete(host)
                pendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { host in
            Text(String(format: L("「%@」将从列表中移除，可随时重新添加（不影响服务器本身）。"), host.name))
        }
        .navigationDestination(for: Host.self) { host in
            HostDetailView(host: host, dependencies: dependencies)
        }
    }

    // MARK: - 区块

    private var header: some View {
        HStack(alignment: .center) {
            Text(L("主机"))
                .font(.connTitle)
                .foregroundStyle(.connInk)
            Spacer()
            IconChipButton("plus", tint: .accent, accessibilityLabel: L("添加主机")) {
                startAdding()
            }
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.top, ConnSpacing.xs)
        .padding(.bottom, ConnSpacing.sm)
    }

    private var searchBar: some View {
        HStack(spacing: ConnSpacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.connMuted)
            TextField(L("搜索主机名或地址"), text: $viewModel.searchText)
                .font(.connSubheadline)
                .foregroundStyle(.connInk)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, ConnSpacing.sm)
        .padding(.vertical, 10)
        .background(Color.connSurface, in: .rect(cornerRadius: ConnRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 1)
        )
        .padding(.horizontal, ConnSpacing.page)
        .padding(.bottom, ConnSpacing.sm)
    }

    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ConnSpacing.xs) {
                filterChip(title: L("全部"), isSelected: viewModel.selectedTag == nil) {
                    viewModel.selectedTag = nil
                }
                ForEach(viewModel.allTags, id: \.self) { tag in
                    filterChip(title: tag, isSelected: viewModel.selectedTag == tag) {
                        viewModel.selectedTag = viewModel.selectedTag == tag ? nil : tag
                    }
                }
            }
            .padding(.horizontal, ConnSpacing.page)
        }
        .padding(.bottom, ConnSpacing.sm)
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.connFootnote)
                .foregroundStyle(isSelected ? .connAccent : .connMuted)
                .padding(.horizontal, ConnSpacing.sm)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.connAccentFill : Color.connSurface,
                    in: .capsule
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.connAccent.opacity(0.5) : Color.connLine,
                        lineWidth: 1
                    )
                )
                .connHitTarget()
        }
        .buttonStyle(ConnPressStyle())
    }

    private var limitBanner: some View {
        ConnBanner(
            String(format: L("免费版已用 %d/%d 台主机，升级专业版解锁无限主机"),
                   viewModel.hosts.count, viewModel.freeHostLimit),
            systemImage: "info.circle"
        )
        .padding(.horizontal, ConnSpacing.page)
        .padding(.bottom, ConnSpacing.sm)
    }

    private var hostSections: some View {
        LazyVStack(alignment: .leading, spacing: ConnSpacing.md) {
            ForEach(viewModel.groupedHosts, id: \.group) { section in
                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    Text(section.group)
                        .font(.connCaption)
                        .foregroundStyle(.connMuted)
                        .connEyebrowTracking()
                        .padding(.horizontal, ConnSpacing.page)
                    ForEach(section.hosts) { host in
                        hostRow(host)
                    }
                }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
    }

    private func hostRow(_ host: Host) -> some View {
        NavigationLink(value: host) {
            ConnListRow(
                title: host.name,
                subtitle: host.displayAddress,
                tags: host.tags.map { ConnRowTag($0, kind: $0.lowercased() == "prod" ? .danger : .neutral) },
                leading: { ConnStatusDot(viewModel.presentationStatus(host)) },
                trailing: { ConnChevron() }
            )
        }
        .buttonStyle(ConnPressStyle())
        .padding(.horizontal, ConnSpacing.page)
        // 长按呼出编辑/删除。注意：`.swipeActions` 只在 List 内生效,此处是
        // ScrollView + LazyVStack,故用 contextMenu（删除走强确认对话框）。
        .contextMenu {
            Button { startEditing(host) } label: {
                Label(L("编辑"), systemImage: "pencil")
            }
            Button(role: .destructive) { pendingDelete = host } label: {
                Label(L("删除"), systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        EmptyState(
            systemName: "server.rack",
            title: L("还没有主机"),
            message: L("添加你的第一台服务器，开始监控与管理"),
            primary: .init(L("添加我的服务器")) { startAdding() }
        )
        .padding(.top, ConnSpacing.xxl)
    }

    // MARK: - 动作

    private func startAdding() {
        formRequest = HostFormRequest(draft: HostDraft(), editingHostID: nil)
    }

    private func startEditing(_ host: Host) {
        formRequest = HostFormRequest(draft: HostDraft(from: host), editingHostID: host.id)
    }
}
