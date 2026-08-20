import ConnKit
import ConnUI
import SwiftUI

/// 片段表单请求：新增（snippet == nil）或编辑既有片段。
private struct SnippetFormRequest: Identifiable {
    let id = UUID()
    let snippet: Snippet?
}

private enum SnippetRowMetrics {
    static let iconSize: CGFloat = 30
    static let iconGlyphSize: CGFloat = 15
}

/// Shell 脚本库（脚本 Tab，Phase 9）。
struct SnippetsView: View {
    @State private var viewModel: SnippetsViewModel
    @State private var selectedFilter: SnippetListFilter = .favorites
    @State private var runTarget: Snippet?
    @State private var formRequest: SnippetFormRequest?
    @State private var isHistoryPresented = false
    @State private var isGroupsPresented = false
    @State private var groupSearchText = ""
    @State private var isGroupPromptPresented = false
    @State private var newGroupName = ""
    @State private var groupDeleteRequest: GroupEditRequest?
    @State private var renameTarget: GroupEditRequest?
    @State private var isGroupsNewGroupPresented = false
    @State private var groupsNameInput = ""
    @State private var groupsDeleteRequest: GroupEditRequest?
    @State private var groupsRenameTarget: GroupEditRequest?
    @Environment(\.connToastCenter) private var toastCenter
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _viewModel = State(initialValue: SnippetsViewModel(
            store: dependencies.snippetRepository,
            groupStore: dependencies.snippetGroupRepository
        ))
    }

    var body: some View {
        mainContent
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("脚本"))
            .searchable(text: $viewModel.searchText, prompt: L("搜索脚本"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isHistoryPresented = true
                        } label: {
                            Label(L("执行历史"), systemImage: "clock.arrow.circlepath")
                        }
                        Button {
                            groupSearchText = ""
                            isGroupsPresented = true
                        } label: {
                            Label(L("管理分组"), systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(L("更多操作"))
                    Menu {
                        Button {
                            formRequest = SnippetFormRequest(snippet: nil)
                        } label: {
                            Label(L("新增脚本"), systemImage: "terminal")
                        }
                        Button {
                            newGroupName = ""
                            isGroupPromptPresented = true
                        } label: {
                            Label(L("新增分组"), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L("新增"))
                }
            }
            .task { viewModel.load() }
            .navigationDestination(isPresented: $isGroupsPresented) {
                groupsPage
            }
            .sheet(item: $runTarget) { snippet in
                SnippetRunView(snippet: snippet, dependencies: dependencies)
            }
            .sheet(item: $formRequest) { request in
                SnippetFormView(snippet: request.snippet, groups: viewModel.groups) { snippet in
                    viewModel.save(snippet)
                }
            }
            .sheet(isPresented: $isHistoryPresented) {
                NavigationStack {
                    RunHistoryView(dependencies: dependencies)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L("完成")) { isHistoryPresented = false }
                            }
                        }
                }
                .presentationDragIndicator(.visible)
            }
            .groupManagementAlerts(
                isNewGroupPresented: $isGroupPromptPresented,
                renameTarget: $renameTarget,
                deleteRequest: $groupDeleteRequest,
                nameInput: $newGroupName,
                actions: GroupAlertActions(
                    deleteMessage: L("删除分组不会删除其中的脚本，脚本会保留在其他分组或未分组。"),
                    onAdd: { viewModel.addGroup($0) },
                    onRename: { viewModel.renameGroup(id: $0, to: $1) },
                    onDelete: { id in
                        if selectedFilter == .group(id) { selectedFilter = .all }
                        viewModel.deleteGroup(id: id)
                    }
                )
            )
            .onChange(of: viewModel.errorMessage) { _, message in
                toastCenter.show(message, style: .error)
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { geometry in
            ScrollView {
                if viewModel.snippets(for: selectedFilter).isEmpty {
                    // 空列表时把空态放到筛选条下方的剩余视口中央，避免内容挤在列表顶部。
                    VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                        commandFilters
                        Spacer(minLength: 0)
                        commandEmpty
                            .frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: geometry.size.height)
                    .padding(.bottom, ConnSpacing.lg)
                } else {
                    VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                        commandFilters
                        commandList
                    }
                    .padding(.bottom, ConnSpacing.lg)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var commandFilters: some View {
        GroupFilterBar(
            allTitle: L("全部"),
            leading: [GroupFilterBar.Item(id: Self.favoritesChipID, title: L("常用"))],
            groups: viewModel.groups.map { GroupFilterBar.Item(id: $0.id, title: $0.name) },
            selection: Binding(
                get: {
                    switch selectedFilter {
                    case .favorites: Self.favoritesChipID
                    case .all: nil
                    case let .group(id): id
                    }
                },
                set: { newValue in
                    switch newValue {
                    case nil: selectedFilter = .all
                    case Self.favoritesChipID: selectedFilter = .favorites
                    case let .some(id): selectedFilter = .group(id)
                    }
                }
            ),
            onRename: { item in
                renameTarget = GroupEditRequest(id: item.id, name: item.title)
                newGroupName = item.title
            },
            onDelete: { item in
                groupDeleteRequest = GroupEditRequest(id: item.id, name: item.title)
            }
        )
    }

    /// 「常用」不是分组，用一个不可能与 uuid 冲突的哨兵 id 走 GroupFilterBar 的前置 chip。
    private static let favoritesChipID = "__favorites__"

    @ViewBuilder
    private var commandList: some View {
        let snippets = viewModel.snippets(for: selectedFilter)
        if snippets.isEmpty {
            commandEmpty
        } else {
            LazyVStack(spacing: ConnSpacing.stackGap) {
                ForEach(snippets) { snippet in
                    commandRow(snippet)
                        .padding(.horizontal, ConnSpacing.page)
                }
            }
        }
    }

    private func commandRow(_ snippet: Snippet) -> some View {
        Button { runTarget = snippet } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "command")
                    .font(.system(size: SnippetRowMetrics.iconGlyphSize, weight: .semibold))
                    .foregroundStyle(.connAccent)
                    .frame(width: SnippetRowMetrics.iconSize, height: SnippetRowMetrics.iconSize)
                    .background(Color.connAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: ConnSpacing.xxs) {
                    HStack(spacing: ConnSpacing.xs) {
                        Text(snippet.title)
                            .font(.connSubheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.connInk)
                            .lineLimit(1)
                        if snippet.danger {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.connCrit)
                        }
                        if !snippet.variables.isEmpty {
                            Text(String(format: L("%d 变量"), snippet.variables.count))
                                .font(.connData(.caption2))
                                .foregroundStyle(.connAccent)
                        }
                        Text(snippet.interpreter.displayName)
                            .font(.connData(.caption2))
                            .foregroundStyle(.connMuted)
                    }
                    Text(snippet.script)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, ConnSpacing.xs)
            .padding(.horizontal, ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("snippet.row.\(snippet.id)")
        .buttonStyle(ConnPressStyle())
        .contextMenu {
            Button { formRequest = SnippetFormRequest(snippet: snippet) } label: {
                Label(L("编辑"), systemImage: "pencil")
            }
            Button { runTarget = snippet } label: {
                Label(L("执行"), systemImage: "play")
            }
            Divider()
            Button(role: .destructive) { viewModel.delete(snippet) } label: {
                Label(L("删除"), systemImage: "trash")
            }
        }
        .connSurface(cornerRadius: ConnRadius.listCard)
    }

    @ViewBuilder
    private var groupList: some View {
        if viewModel.groups.isEmpty {
            EmptyState(
                systemName: "folder",
                title: L("暂无分组"),
                message: L("使用右上角“+”创建分组"),
                primary: .init(L("新增分组")) {
                    groupsNameInput = ""
                    isGroupsNewGroupPresented = true
                }
            )
        } else if filteredGroups.isEmpty {
            EmptyState(
                systemName: "magnifyingglass",
                title: L("未找到匹配的分组"),
                message: L("换个关键词试试")
            )
        } else {
            LazyVStack(spacing: ConnSpacing.stackGap) {
                ForEach(filteredGroups) { group in
                    groupRow(group)
                        .padding(.horizontal, ConnSpacing.page)
                }
            }
        }
    }

    private func groupRow(_ group: SnippetGroup) -> some View {
        Button {
            selectedFilter = .group(group.id)
            isGroupsPresented = false
        } label: {
            HStack(spacing: ConnSpacing.md) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.connAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.connAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    Text(group.name)
                        .font(.connBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(.connInk)
                        .lineLimit(1)
                    Text(String(format: L("%d 个脚本"), viewModel.scriptCount(in: group.id)))
                        .font(.connData(.caption))
                        .foregroundStyle(.connMuted)
                }
                Spacer(minLength: ConnSpacing.xxs)
                ConnChevron()
            }
            .padding(.vertical, ConnSpacing.md)
            .padding(.horizontal, ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ConnPressStyle())
        .contextMenu {
            Button {
                groupsRenameTarget = GroupEditRequest(id: group.id, name: group.name)
                groupsNameInput = group.name
            } label: {
                Label(L("重命名分组"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                groupsDeleteRequest = GroupEditRequest(id: group.id, name: group.name)
            } label: {
                Label(L("删除分组"), systemImage: "trash")
            }
        }
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private var commandEmpty: some View {
        EmptyState(
            systemName: "command",
            title: viewModel.searchText.isEmpty ? L("暂无脚本") : L("未找到匹配的脚本"),
            message: viewModel.searchText.isEmpty ? L("新增一条，或切换其他筛选") : L("换个关键词试试"),
            primary: viewModel.searchText.isEmpty ? .init(L("新增脚本")) {
                formRequest = SnippetFormRequest(snippet: nil)
            } : nil
        )
    }

    private var groupsPage: some View {
        GeometryReader { geometry in
            ScrollView {
                if viewModel.groups.isEmpty || filteredGroups.isEmpty {
                    groupList
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                } else {
                    groupList
                        .padding(.vertical, ConnSpacing.sm)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("分组"))
        .searchable(text: $groupSearchText, prompt: L("搜索分组"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    groupsNameInput = ""
                    isGroupsNewGroupPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("新增分组"))
            }
        }
        .groupManagementAlerts(
            isNewGroupPresented: $isGroupsNewGroupPresented,
            renameTarget: $groupsRenameTarget,
            deleteRequest: $groupsDeleteRequest,
            nameInput: $groupsNameInput,
            actions: GroupAlertActions(
                deleteMessage: L("删除分组不会删除其中的脚本，脚本会保留在其他分组或未分组。"),
                onAdd: { viewModel.addGroup($0) },
                onRename: { viewModel.renameGroup(id: $0, to: $1) },
                onDelete: { id in
                    if selectedFilter == .group(id) { selectedFilter = .all }
                    viewModel.deleteGroup(id: id)
                }
            )
        )
    }

    private var filteredGroups: [SnippetGroup] {
        let query = groupSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.groups }
        return viewModel.groups.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

}
