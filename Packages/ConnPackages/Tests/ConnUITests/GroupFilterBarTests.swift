import Foundation
import Testing
@testable import ConnUI

@Suite("GroupFilterBar — 选择行为")
struct GroupFilterBarTests {
    @Test("点未选中的 chip 即选中它")
    func selectsTapped() {
        #expect(GroupFilterBar.nextSelection(tapped: "g1", current: nil) == "g1")
        #expect(GroupFilterBar.nextSelection(tapped: "g2", current: "g1") == "g2")
    }

    @Test("再点一次当前选中的 chip 回到「全部」")
    func retapReturnsToAll() {
        #expect(GroupFilterBar.nextSelection(tapped: "g1", current: "g1") == nil)
    }
}
