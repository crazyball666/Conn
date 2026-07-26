import ConnKit
import ConnUI
import SwiftUI

/// 片段新增 / 编辑（Phase 9）。
struct SnippetFormView: View {
    let snippet: Snippet?
    let groups: [String]
    let onSave: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var command: String
    @State private var selectedGroups: Set<String>
    @State private var pinned: Bool
    @State private var danger: Bool

    init(snippet: Snippet?, groups: [String], onSave: @escaping (Snippet) -> Void) {
        self.snippet = snippet
        self.groups = groups
        self.onSave = onSave
        _title = State(initialValue: snippet?.title ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _selectedGroups = State(initialValue: Set(snippet?.folders ?? []))
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
                Section {
                    ForEach(availableGroups, id: \.self) { group in
                        Button {
                            if selectedGroups.contains(group) {
                                selectedGroups.remove(group)
                            } else {
                                selectedGroups.insert(group)
                            }
                        } label: {
                            HStack {
                                Text(group)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selectedGroups.contains(group)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(selectedGroups.contains(group) ? Color.connAccent : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L("分组"))
                } footer: {
                    Text(L("可多选，也可以不选；不选时命令归为未分组。"))
                }
                Section {
                    Toggle(L("置顶到「常用」"), isOn: $pinned)
                    Toggle(L("标记为危险（执行前强确认）"), isOn: $danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(snippet == nil ? L("新增命令") : L("编辑命令"))
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

    private var availableGroups: [String] {
        var result = groups
        for group in snippet?.folders ?? [] where !result.contains(group) {
            result.append(group)
        }
        return result
    }

    private func save() {
        let result: Snippet
        if let existing = snippet {
            var updated = existing
            updated.title = title
            updated.command = command
            updated.folders = availableGroups.filter(selectedGroups.contains)
            updated.pinned = pinned
            updated.danger = danger
            result = updated
        } else {
            result = Snippet(
                title: title,
                command: command,
                folders: availableGroups.filter(selectedGroups.contains),
                pinned: pinned,
                danger: danger
            )
        }
        onSave(result)
        dismiss()
    }
}
