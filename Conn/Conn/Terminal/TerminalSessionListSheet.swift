import ConnKit
import ConnTerminal
import ConnUI
import SwiftUI

/// 当前主机的会话切换器。会话与本地展示元数据仅在内存中保留；
/// 持久终端的非空重命名由 provider 同步到远端 workspace。
struct TerminalSessionListSheet: View {
    let host: Host
    let store: TerminalSessionStore
    let selectedTabID: String?
    let onSelect: (String) -> Void
    let onCreate: () -> Void
    let onRename: (String, String) -> Void
    let onClose: (String) -> Void

    @State private var renameTarget: TerminalTab?
    @State private var alias = ""
    @Environment(\.dismiss) private var dismiss

    private var tabs: [TerminalTab] { store.tabs(forHost: host.id) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tabs) { tab in
                        Button { onSelect(tab.id) } label: {
                            sessionRow(tab)
                        }
                        .buttonStyle(.plain)
                        .contentShape(.rect)
                        .contextMenu {
                            Button {
                                renameTarget = tab
                                alias = tab.alias ?? tab.automaticAlias
                            } label: {
                                Label(L("设置别名"), systemImage: "pencil")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { onClose(tab.id) } label: {
                                Label(L("删除"), systemImage: "trash")
                            }
                        }
                        .accessibilityAction(named: Text(L("设置别名"))) {
                            renameTarget = tab
                            alias = tab.alias ?? tab.automaticAlias
                        }
                        .accessibilityAction(named: Text(L("删除"))) {
                            onClose(tab.id)
                        }
                    }
                } header: {
                    Text(host.displayAddress)
                } footer: {
                    Text(L("返回不会关闭会话；仅“退出终端”或在这里关闭才会结束该 PTY。"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("终端会话"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("完成")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onCreate) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L("新建终端"))
                }
            }
            .alert(L("设置终端别名"), isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField(L("别名"), text: $alias)
                Button(L("取消"), role: .cancel) { renameTarget = nil }
                Button(L("保存")) {
                    if let target = renameTarget {
                        onRename(target.id, alias)
                    }
                    renameTarget = nil
                }
            } message: {
                Text(renameMessage)
            }
        }
    }

    private var renameMessage: String {
        if let renameTarget, case .persistent = renameTarget.source {
            return L("修改持久终端别名会同时重命名远端会话；留空会恢复当前会话名称。")
        }
        return L("留空会恢复自动名称。")
    }

    private func sessionRow(_ tab: TerminalTab) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: sourceIcon(tab.source))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tab.id == selectedTabID ? Color.connAccent : .connMuted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.displayName)
                    .font(.connSubheadline)
                    .foregroundStyle(.connInk)
                Text(sourceDescription(tab.source))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            statusIcon(tab.status)
            if tab.id == selectedTabID {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.connAccent)
            }
        }
        .padding(.vertical, ConnSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
    private func statusIcon(_ status: TerminalTabStatus) -> some View {
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
