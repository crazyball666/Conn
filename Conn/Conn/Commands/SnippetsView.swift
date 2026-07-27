import ConnKit
import ConnUI
import SwiftUI

/// 片段表单请求：新增（snippet == nil）或编辑既有片段。
private struct SnippetFormRequest: Identifiable {
    let id = UUID()
    let snippet: Snippet?
}

/// 分组重命名 / 删除的呈现请求。
private struct GroupEditRequest: Identifiable {
    let id: String
    let name: String
}

private enum SnippetsPage: String, CaseIterable, Identifiable {
    case commands = "命令"
    case groups = "分组"

    var id: String { rawValue }
}

/// 片段库（命令 Tab，Phase 9）。
struct SnippetsView: View {
    @State private var viewModel: SnippetsViewModel
    @State private var page: SnippetsPage = .commands
    @State private var selectedFilter: SnippetListFilter = .favorites
    @State private var runTarget: Snippet?
    @State private var formRequest: SnippetFormRequest?
    @State private var isHistoryPresented = false
    @State private var isGroupPromptPresented = false
    @State private var newGroupName = ""
    @State private var groupDeleteRequest: GroupEditRequest?
    @State private var renameTarget: GroupEditRequest?
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
            .navigationTitle(L("命令"))
            .searchable(text: $viewModel.searchText, prompt: L("搜索命令或分组"))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    pagePicker
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isHistoryPresented = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel(L("执行历史"))
                    Menu {
                        Button {
                            formRequest = SnippetFormRequest(snippet: nil)
                        } label: {
                            Label(L("新增命令"), systemImage: "command")
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
            .alert(L("新增分组"), isPresented: $isGroupPromptPresented) {
                TextField(L("分组名称"), text: $newGroupName)
                Button(L("取消"), role: .cancel) {}
                Button(L("保存")) {
                    viewModel.addGroup(newGroupName)
                }
                .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog(
                L("删除分组"),
                isPresented: isGroupDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(L("删除"), role: .destructive) {
                    guard let request = groupDeleteRequest else { return }
                    if selectedFilter == .group(request.id) {
                        selectedFilter = .all
                    }
                    viewModel.deleteGroup(id: request.id)
                    groupDeleteRequest = nil
                }
                Button(L("取消"), role: .cancel) {
                    groupDeleteRequest = nil
                }
            } message: {
                Text(L("删除分组不会删除其中的命令，命令会保留在其他分组或未分组。"))
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch page {
        case .commands:
            ScrollView {
                VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                    commandFilters
                    commandList
                }
                .padding(.bottom, ConnSpacing.lg)
            }
            .scrollBounceBehavior(.basedOnSize)
        case .groups:
            ScrollView {
                VStack(alignment: .leading, spacing: ConnSpacing.md) {
                    groupList
                }
                .padding(.bottom, ConnSpacing.lg)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var pagePicker: some View {
        Picker(L("类型"), selection: $page) {
            ForEach(SnippetsPage.allCases) { item in
                Text(L(item.rawValue)).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 150)
        .accessibilityLabel(L("命令与分组"))
    }

    private var commandFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ConnSpacing.xs) {
                filterChip(title: L("常用"), filter: .favorites)
                filterChip(title: L("全部"), filter: .all)
                ForEach(viewModel.groups) { group in
                    filterChip(title: group.name, filter: .group(group.id))
                }
            }
        }
        .padding(.horizontal, ConnSpacing.page)
    }

    private func filterChip(title: String, filter: SnippetListFilter) -> some View {
        let isSelected = selectedFilter == filter
        return Button {
            selectedFilter = filter
        } label: {
            Text(title)
                .font(.connFootnote)
                .foregroundStyle(isSelected ? .connAccent : .connMuted)
                .padding(.horizontal, ConnSpacing.sm)
                .padding(.vertical, 6)
                .background(isSelected ? Color.connAccentFill : Color.connSurface, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(
                        isSelected ? Color.connAccent.opacity(0.5) : Color.connLine,
                        lineWidth: 1
                    )
                }
                .connHitTarget()
        }
        .buttonStyle(ConnPressStyle())
    }

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
        HStack(spacing: ConnSpacing.sm) {
            Button { runTarget = snippet } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: ConnSpacing.xs) {
                        Text(snippet.title)
                            .font(.connSubheadline)
                            .fontWeight(.regular)
                            .foregroundStyle(.connInk)
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
                    }
                    Text(snippet.command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ConnPressStyle())
            Menu {
                Button { runTarget = snippet } label: {
                    Label(L("执行"), systemImage: "play")
                }
                Button { formRequest = SnippetFormRequest(snippet: snippet) } label: {
                    Label(L("编辑"), systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) { viewModel.delete(snippet) } label: {
                    Label(L("删除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18))
                    .foregroundStyle(.connMuted)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    @ViewBuilder
    private var groupList: some View {
        if viewModel.groups.isEmpty {
            EmptyState(
                systemName: "folder",
                title: L("还没有分组"),
                message: L("点击右上角 + 新增分组"),
                primary: .init(L("新增分组")) {
                    newGroupName = ""
                    isGroupPromptPresented = true
                }
            )
            .padding(.top, ConnSpacing.xxl)
        } else if viewModel.filteredGroups.isEmpty {
            EmptyState(
                systemName: "magnifyingglass",
                title: L("没有匹配的分组"),
                message: L("换个关键词试试")
            )
            .padding(.top, ConnSpacing.xxl)
        } else {
            LazyVStack(spacing: ConnSpacing.stackGap) {
                ForEach(viewModel.filteredGroups) { group in
                    groupRow(group)
                        .padding(.horizontal, ConnSpacing.page)
                }
            }
        }
    }

    private func groupRow(_ group: SnippetGroup) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Button {
                selectedFilter = .group(group.id)
                page = .commands
            } label: {
                HStack(spacing: ConnSpacing.sm) {
                    Image(systemName: "folder")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.connAccent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.connSubheadline)
                            .fontWeight(.regular)
                            .foregroundStyle(.connInk)
                        Text(String(format: L("%d 条命令"), viewModel.commandCount(in: group.id)))
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ConnPressStyle())
            Menu {
                Button {
                    renameTarget = GroupEditRequest(id: group.id, name: group.name)
                    newGroupName = group.name
                } label: {
                    Label(L("重命名分组"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    groupDeleteRequest = GroupEditRequest(id: group.id, name: group.name)
                } label: {
                    Label(L("删除分组"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18))
                    .foregroundStyle(.connMuted)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private var commandEmpty: some View {
        EmptyState(
            systemName: "command",
            title: viewModel.searchText.isEmpty ? L("还没有片段") : L("没有匹配的片段"),
            message: viewModel.searchText.isEmpty ? L("新增一条，或切换其他筛选") : L("换个关键词试试"),
            primary: viewModel.searchText.isEmpty ? .init(L("新增命令")) {
                formRequest = SnippetFormRequest(snippet: nil)
            } : nil
        )
        .padding(.top, ConnSpacing.xxl)
    }

    private var isGroupDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { groupDeleteRequest != nil },
            set: { isPresented in
                if !isPresented {
                    groupDeleteRequest = nil
                }
            }
        )
    }
}
