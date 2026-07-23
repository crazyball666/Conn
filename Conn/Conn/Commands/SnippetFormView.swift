import ConnKit
import ConnUI
import SwiftUI

/// 片段新增 / 编辑（Phase 9）。
struct SnippetFormView: View {
    let snippet: Snippet?
    let onSave: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var command: String
    @State private var folder: String
    @State private var pinned: Bool
    @State private var danger: Bool

    init(snippet: Snippet?, onSave: @escaping (Snippet) -> Void) {
        self.snippet = snippet
        self.onSave = onSave
        _title = State(initialValue: snippet?.title ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _folder = State(initialValue: snippet?.folder ?? "")
        _pinned = State(initialValue: snippet?.pinned ?? false)
        _danger = State(initialValue: snippet?.danger ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("标题")) {
                    TextField(L("如：查看磁盘使用"), text: $title)
                }
                Section {
                    TextEditor(text: $command)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 100)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text(L("命令"))
                } footer: {
                    Text(L("变量用 {{名称}} 或 {{名称:默认值}}，执行前会让你填参。"))
                }
                Section(L("分组")) {
                    TextField(L("如：磁盘 / 网络（可留空）"), text: $folder)
                }
                Section {
                    Toggle(L("置顶到「常用」"), isOn: $pinned)
                    Toggle(L("标记为危险（执行前强确认）"), isOn: $danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(snippet == nil ? L("新增片段") : L("编辑片段"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("保存")) { save() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                            || command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedFolder = folder.trimmingCharacters(in: .whitespaces)
        let result: Snippet
        if let existing = snippet {
            var updated = existing
            updated.title = title
            updated.command = command
            updated.folder = trimmedFolder.isEmpty ? nil : trimmedFolder
            updated.pinned = pinned
            updated.danger = danger
            result = updated
        } else {
            result = Snippet(
                title: title,
                command: command,
                folder: trimmedFolder.isEmpty ? nil : trimmedFolder,
                pinned: pinned,
                danger: danger
            )
        }
        onSave(result)
        dismiss()
    }
}
