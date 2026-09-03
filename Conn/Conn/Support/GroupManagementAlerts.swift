import SwiftUI

/// 分组重命名 / 删除的呈现请求。
struct GroupEditRequest: Identifiable {
    let id: String
    let name: String
}

/// 分组三件套弹窗的行为：删除说明文案 + 三个动作。
struct GroupAlertActions {
    /// 删除确认里的说明文案，两页不同（主机 vs 命令）。
    let deleteMessage: String
    let onAdd: (String) -> Void
    let onRename: (_ id: String, _ newName: String) -> Void
    let onDelete: (_ id: String) -> Void
}

/// 分组的「新建 / 重命名 / 删除」三件套弹窗。服务器页与命令页共用。
///
/// 抽出来的动因是两页曾各写一份逐字相同的实现——除了删除确认的文案不同
/// （主机 vs 命令），其余完全一致。
private struct GroupManagementAlerts: ViewModifier {
    @Binding var isNewGroupPresented: Bool
    @Binding var renameTarget: GroupEditRequest?
    @Binding var deleteRequest: GroupEditRequest?
    @Binding var nameInput: String
    let actions: GroupAlertActions

    private var isNameBlank: Bool {
        nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func body(content: Content) -> some View {
        content
            .alert(L("新增分组"), isPresented: $isNewGroupPresented) {
                TextField(L("分组名称"), text: $nameInput)
                Button(L("取消"), role: .cancel) {}
                Button(L("保存")) { actions.onAdd(nameInput) }
                    .disabled(isNameBlank)
            }
            .alert(
                L("重命名分组"),
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                TextField(L("分组名称"), text: $nameInput)
                Button(L("取消"), role: .cancel) { renameTarget = nil }
                Button(L("保存")) {
                    if let target = renameTarget { actions.onRename(target.id, nameInput) }
                    renameTarget = nil
                }
                .disabled(isNameBlank)
            }
            .alert(
                L("删除分组"),
                isPresented: Binding(
                    get: { deleteRequest != nil },
                    set: { if !$0 { deleteRequest = nil } }
                ),
                presenting: deleteRequest
            ) { request in
                Button(L("删除"), role: .destructive) {
                    actions.onDelete(request.id)
                    deleteRequest = nil
                }
                Button(L("取消"), role: .cancel) { deleteRequest = nil }
            } message: { _ in
                Text(actions.deleteMessage)
            }
    }
}

extension View {
    /// 挂上分组的新建 / 重命名 / 删除三件套弹窗。
    func groupManagementAlerts(
        isNewGroupPresented: Binding<Bool>,
        renameTarget: Binding<GroupEditRequest?>,
        deleteRequest: Binding<GroupEditRequest?>,
        nameInput: Binding<String>,
        actions: GroupAlertActions
    ) -> some View {
        modifier(GroupManagementAlerts(
            isNewGroupPresented: isNewGroupPresented,
            renameTarget: renameTarget,
            deleteRequest: deleteRequest,
            nameInput: nameInput,
            actions: actions
        ))
    }
}
