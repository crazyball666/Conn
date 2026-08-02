import Foundation
import Testing
@testable import ConnUI

@Suite("ConnToast — 自动消失时序")
struct ConnToastTests {
    @Test("默认自动消失时长为 3.5 秒")
    func defaultDuration() {
        #expect(ConnToastTimer.autoDismissDuration == .seconds(3.5))
    }

    @Test("等待结束返回 true，表示应清空消息")
    func waitCompletes() async {
        let shouldDismiss = await ConnToastTimer.waitForAutoDismiss(.milliseconds(10))
        #expect(shouldDismiss)
    }

    @Test("被取消时返回 false，不清空消息")
    func cancelledWaitDoesNotDismiss() async {
        let task = Task { await ConnToastTimer.waitForAutoDismiss(.seconds(10)) }
        task.cancel()
        #expect(await task.value == false)
    }

    @Test("全局 Toast 中心可覆盖和清除当前消息")
    func centerPublishesLatestMessage() {
        let center = ConnToastCenter()
        center.show("读取失败")
        #expect(center.message == "读取失败")
        center.show("保存失败")
        #expect(center.message == "保存失败")
        center.dismiss()
        #expect(center.message == nil)
    }
}
