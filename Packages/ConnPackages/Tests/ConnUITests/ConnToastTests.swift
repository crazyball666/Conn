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

    @Test("全局 Toast 中心保留语义且相同文案也产生新的事件")
    func centerPublishesLatestSemanticEvent() {
        let center = ConnToastCenter()
        center.show("已切换 Window", style: .success)
        let first = center.item
        #expect(first?.message == "已切换 Window")
        #expect(first?.style == .success)

        center.show("已切换 Window", style: .success)
        #expect(center.item?.id != first?.id)
        #expect(center.item?.style.systemImageName == "checkmark.circle.fill")

        center.show("连接失败", style: .error)
        #expect(center.item?.style.systemImageName == "xmark.octagon.fill")
        center.dismiss()
        #expect(center.item == nil)
    }

    @Test("不同语义使用匹配的图标和停留时长")
    func semanticPresentation() {
        #expect(ConnToastStyle.success.autoDismissDuration == .seconds(1.5))
        #expect(ConnToastStyle.info.systemImageName == "info.circle.fill")
        #expect(ConnToastStyle.warning.systemImageName == "exclamationmark.triangle.fill")
        #expect(ConnToastStyle.error.autoDismissDuration == .seconds(3.5))
    }

    @Test("App 统一触感使用最高强度")
    func highImpactHapticPolicy() {
        #expect(ConnHapticFeedback.intensity == 1.0)
    }
}
