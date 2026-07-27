import Foundation
import Testing
@testable import Conn

@MainActor
struct GroupListEditorTests {
    @Test("空名与纯空白被拒")
    func rejectsEmptyName() {
        #expect(throws: GroupListEditor.Failure.emptyName) {
            try GroupListEditor.validate(name: "   ", against: [])
        }
    }

    @Test("重名被拒，且不分大小写、忽略首尾空格")
    func rejectsDuplicateName() {
        #expect(throws: GroupListEditor.Failure.duplicateName) {
            try GroupListEditor.validate(name: " docker ", against: ["Docker"])
        }
    }

    @Test("重命名时排除自身则不算重名")
    func allowsRenameToSelf() throws {
        let result = try GroupListEditor.validate(name: "Docker", against: ["日志"])
        #expect(result == "Docker")
    }

    @Test("合法名称返回 trim 后的结果")
    func trimsValidName() throws {
        #expect(try GroupListEditor.validate(name: "  生产  ", against: []) == "生产")
    }

    @Test("新分组排序权重取现有最大值 +1")
    func nextSortOrderIncrements() {
        #expect(GroupListEditor.nextSortOrder(after: []) == 0)
        #expect(GroupListEditor.nextSortOrder(after: [0, 3, 1]) == 4)
    }
}
