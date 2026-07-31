import ConnUI
import SwiftUI
import Testing
import UIKit
@testable import Conn

@Suite("Docker 列表顶部控件布局")
@MainActor
struct DockerListChromeLayoutTests {
    @Test("资源数量列表头不再被更多菜单撑高")
    func resourceHeaderUsesTextHeight() {
        let header = DockerDetail.listHeader(count: "共 7 个镜像")
        let host = UIHostingController(rootView: header)

        let size = host.sizeThatFits(in: CGSize(width: 320, height: 200))

        #expect(size.height < 24)
    }

    @Test("通用搜索框高度统一为 44pt")
    func sharedSearchFieldUsesComfortableHeight() {
        let field = ConnSearchField("搜索镜像", text: .constant(""))
        let host = UIHostingController(rootView: field)

        let size = host.sizeThatFits(in: CGSize(width: 320, height: 200))

        #expect(size.height == 44)
    }
}
