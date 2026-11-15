import ConnTerminal
import Testing
@testable import Conn

struct TerminalConnectionPresentationTests {
    @Test("连接进度和终端状态先后更新时连续显示遮罩")
    func overlayStaysVisibleUntilBothConnectionUpdatesArrive() {
        for activityFinishesFirst in [false, true] {
            var presentation = TerminalConnectionPresentation()
            var activity = makeActivity("first")
            presentation.observePendingActivity(activity)

            if activityFinishesFirst { activity.state = .connected }
            let intermediateStatus: TerminalTabStatus = activityFinishesFirst ? .connecting : .connected
            #expect(presentation.showsOverlay(status: intermediateStatus, activity: activity))
            #expect(presentation.completionID(status: intermediateStatus, activity: activity) == nil)

            activity.state = .connected
            #expect(presentation.showsOverlay(status: .connected, activity: activity))
            #expect(presentation.completionID(status: .connected, activity: activity) == activity.id)
            presentation.endCompletionHold(for: activity.id)
            #expect(!presentation.showsOverlay(status: .connected, activity: activity))
        }
    }

    @Test("重新打开已连接的终端时不显示旧活动")
    func alreadyConnectedTabHasNoCompletionHold() {
        let presentation = TerminalConnectionPresentation()
        var activity = makeActivity("completed")
        activity.state = .connected

        #expect(!presentation.showsOverlay(status: .connected, activity: activity))
        #expect(presentation.completionID(status: .connected, activity: activity) == nil)
    }

    @Test("旧活动的定时结束不会关闭失败或重试卡片")
    func oldCompletionCannotDismissRetry() {
        var presentation = TerminalConnectionPresentation()
        var first = makeActivity("first")
        presentation.observePendingActivity(first)
        first.state = .failed
        #expect(presentation.showsOverlay(status: .disconnected(message: nil), activity: first))
        #expect(presentation.completionID(status: .disconnected(message: nil), activity: first) == nil)

        var retry = makeActivity("retry")
        presentation.observePendingActivity(retry)
        presentation.endCompletionHold(for: first.id)
        #expect(presentation.showsOverlay(status: .reconnecting, activity: retry))
        retry.state = .connected
        #expect(presentation.showsOverlay(status: .connected, activity: retry))
        #expect(presentation.completionID(status: .connected, activity: retry) == retry.id)
    }

    private func makeActivity(_ id: String) -> TerminalConnectionActivity {
        TerminalConnectionActivity(
            id: id, hostID: "test-host", hostName: "Test Host", hostAddress: "localhost", kind: .connect
        )
    }
}
