import ConnKit
import ConnUI
import SwiftUI

/// 从 App 的本地脚本库选择一条脚本并填入当前终端。
///
/// 这里只负责选取与变量替换，不执行脚本、不追加换行；危险脚本也必须回到终端由用户
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
                                Text(snippet.interpreter.displayName)
                                    .font(.connData(.caption2))
                                    .foregroundStyle(.connMuted)
                            }
                            Text(snippet.script)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.connMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.connMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .navigationTitle(L("选择本地脚本"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L("搜索脚本")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("取消")) { dismiss() }
                }
            }
            .task { viewModel.load() }
            .sheet(item: $variableSnippet) { snippet in
                TerminalCommandVariablesView(snippet: snippet) { script in
                    variableSnippet = nil
                    finish(script)
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
                title: viewModel.searchText.isEmpty ? L("暂无脚本") : L("未找到匹配的脚本"),
                message: viewModel.searchText.isEmpty
                    ? L("请先在“脚本”页面添加常用脚本")
                    : L("换个关键词试试")
            )
            .padding(.horizontal, ConnSpacing.lg)
        }
    }

    private func choose(_ snippet: Snippet) {
        if snippet.variables.isEmpty {
            finish(snippet.script)
        } else {
            variableSnippet = snippet
        }
    }

    private func finish(_ script: String) {
        onSelect(script)
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
                    Text(L("脚本仅填入终端，不会自动执行。"))
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
