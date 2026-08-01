import ConnKit
import ConnUI
import SwiftUI

/// 从 App 的本地命令库选择一条命令并填入当前终端。
///
/// 这里只负责选取与变量替换，不执行命令、不追加换行；危险命令也必须回到终端由用户
/// 手动确认执行，避免快捷面板上的一次误触直接改变服务器状态。
struct TerminalCommandPickerView: View {
    @State private var viewModel: SnippetsViewModel
    @State private var variableSnippet: Snippet?
    @Environment(\.dismiss) private var dismiss

    let onSelect: (String) -> Void

    init(
        repository: any SnippetRepository,
        groupRepository: any SnippetGroupRepository,
        onSelect: @escaping (String) -> Void
    ) {
        _viewModel = State(initialValue: SnippetsViewModel(store: repository, groupStore: groupRepository))
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List(snippets) { snippet in
                Button { choose(snippet) } label: {
                    HStack(spacing: ConnSpacing.sm) {
                        Image(systemName: snippet.pinned ? "star.fill" : "command")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(snippet.pinned ? Color.connWarn : .connAccent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: ConnSpacing.xs) {
                                Text(snippet.title)
                                    .font(.connSubheadline)
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
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.connMuted)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.connSurface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .overlay {
                pickerStateOverlay
            }
            .navigationTitle(L("选择本地命令"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L("搜索命令")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("取消")) { dismiss() }
                }
            }
            .task { viewModel.load() }
            .sheet(item: $variableSnippet) { snippet in
                TerminalCommandVariablesView(snippet: snippet) { command in
                    variableSnippet = nil
                    finish(command)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var snippets: [Snippet] {
        viewModel.snippets(for: .all)
    }

    @ViewBuilder
    private var pickerStateOverlay: some View {
        if let error = viewModel.errorMessage {
            ConnRetryState(error, retryTitle: L("重试")) { viewModel.load() }
                .padding(.horizontal, ConnSpacing.lg)
        } else if snippets.isEmpty {
            EmptyState(
                systemName: viewModel.searchText.isEmpty ? "command" : "magnifyingglass",
                title: viewModel.searchText.isEmpty ? L("还没有命令") : L("没有匹配的命令"),
                message: viewModel.searchText.isEmpty
                    ? L("先在「命令」页面添加常用命令")
                    : L("换个关键词试试")
            )
            .padding(.horizontal, ConnSpacing.lg)
        }
    }

    private func choose(_ snippet: Snippet) {
        if snippet.variables.isEmpty {
            finish(snippet.command)
        } else {
            variableSnippet = snippet
        }
    }

    private func finish(_ command: String) {
        onSelect(command)
        dismiss()
    }
}

private struct TerminalCommandVariablesView: View {
    let snippet: Snippet
    let onInsert: (String) -> Void

    @State private var values: [String: String]
    @Environment(\.dismiss) private var dismiss

    init(snippet: Snippet, onInsert: @escaping (String) -> Void) {
        self.snippet = snippet
        self.onInsert = onInsert
        _values = State(initialValue: Dictionary(
            uniqueKeysWithValues: snippet.variables.map { ($0.name, $0.defaultValue ?? "") }
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(snippet.variables, id: \.name) { variable in
                        TextField(variable.name, text: binding(for: variable))
                            .font(.connData(.footnote))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text(L("变量"))
                } footer: {
                    Text(L("命令只会填入终端，不会自动执行。"))
                }
            }
            .navigationTitle(snippet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("填入")) { onInsert(snippet.render(values: values)) }
                }
            }
        }
    }

    private func binding(for variable: Snippet.Variable) -> Binding<String> {
        Binding(
            get: { values[variable.name] ?? variable.defaultValue ?? "" },
            set: { values[variable.name] = $0 }
        )
    }
}
