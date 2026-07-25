import ConnKit
import ConnUI
import SwiftUI

/// 片段表单请求：新增（snippet == nil）或编辑既有片段。
private struct SnippetFormRequest: Identifiable {
    let id = UUID()
    let snippet: Snippet?
}

/// 片段库（命令 Tab，Phase 9）。
struct SnippetsView: View {
    @State private var viewModel: SnippetsViewModel
    @State private var runTarget: Snippet?
    @State private var formRequest: SnippetFormRequest?
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _viewModel = State(initialValue: SnippetsViewModel(store: dependencies.snippetRepository))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.sections.isEmpty {
                    empty
                } else {
                    sectionsView
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("命令"))
        .searchable(text: $viewModel.searchText, prompt: L("搜索片段"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    RunHistoryView(dependencies: dependencies)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel(L("执行历史"))
                Button {
                    formRequest = SnippetFormRequest(snippet: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("新增片段"))
            }
        }
        .task { viewModel.load() }
        .sheet(item: $runTarget) { snippet in
            SnippetRunView(snippet: snippet, dependencies: dependencies)
        }
        .sheet(item: $formRequest) { request in
            SnippetFormView(snippet: request.snippet) { snippet in
                viewModel.save(snippet)
            }
        }
    }

    // MARK: - 区块

    private var sectionsView: some View {
        LazyVStack(alignment: .leading, spacing: ConnSpacing.md) {
            ForEach(viewModel.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    Text(section.title)
                        .font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
                        .padding(.horizontal, ConnSpacing.page)
                    ForEach(section.items) { snippet in
                        row(snippet).padding(.horizontal, ConnSpacing.page)
                    }
                }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Button { runTarget = snippet } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: ConnSpacing.xs) {
                        Text(snippet.title).font(.connHeadline).foregroundStyle(.connInk)
                        if snippet.danger {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.connCrit)
                        }
                        if !snippet.variables.isEmpty {
                            Text(String(format: L("%d 变量"), snippet.variables.count))
                                .font(.connData(.caption2)).foregroundStyle(.connAccent)
                        }
                    }
                    Text(snippet.command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.connMuted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ConnPressStyle())
            Menu {
                Button { runTarget = snippet } label: { Label(L("执行"), systemImage: "play") }
                Button { formRequest = SnippetFormRequest(snippet: snippet) } label: { Label(L("编辑"), systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { viewModel.delete(snippet) } label: { Label(L("删除"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18)).foregroundStyle(.connMuted).frame(width: 32, height: 32)
            }
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private var empty: some View {
        EmptyState(
            systemName: "command",
            title: viewModel.searchText.isEmpty ? L("还没有片段") : L("没有匹配的片段"),
            message: viewModel.searchText.isEmpty ? L("新增一条，或使用内置模板库") : L("换个关键词试试"),
            primary: viewModel.searchText.isEmpty ? .init(L("新增片段")) { formRequest = SnippetFormRequest(snippet: nil) } : nil
        )
        .padding(.top, ConnSpacing.xxl)
    }
}
