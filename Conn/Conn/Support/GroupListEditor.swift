import Foundation

/// 分组增删改的共用规则。
///
/// 只做校验与排序权重计算，不持有仓库——持久化留在各自 ViewModel。
/// 服务器页与命令页共用同一套判定，避免两处规则漂移。
///
/// 之所以不做成「持有仓库的泛型类型」：`HostGroupRepository` 与
/// `SnippetGroupRepository` 是元素类型不同的两个协议，泛型化后
/// `AppDependencies` 里的 `any XxxRepository` 存在类型无法满足泛型约束，
/// 还得再套一层类型擦除——代码量与理解成本都超过它消除的重复。
enum GroupListEditor {
    enum Failure: Error, Equatable {
        case emptyName
        case duplicateName

        var message: String {
            switch self {
            case .emptyName: L("分组名称不能为空")
            case .duplicateName: L("已存在同名分组")
            }
        }
    }

    /// 校验新建 / 重命名用的分组名。
    ///
    /// - Parameters:
    ///   - name: 用户输入的原始名称。
    ///   - existingNames: 现有分组名。**重命名时必须排除被改的那个自身**，
    ///     否则原名会把自己判成重名。
    /// - Returns: trim 后的合法名称。
    static func validate(name: String, against existingNames: [String]) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        let clash = existingNames.contains { existing in
            existing.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        guard !clash else { throw Failure.duplicateName }
        return trimmed
    }

    /// 新分组的排序权重：现有最大值 +1。
    static func nextSortOrder(after existing: [Int]) -> Int {
        (existing.max() ?? -1) + 1
    }
}
