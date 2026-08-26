import ConnMultiplexer
import Testing
@testable import ConnTerminal

@Suite("Terminal provider action queue")
struct TerminalProviderActionQueueTests {
    @Test("连续同向滑动合并为受限批次且不丢次数")
    func coalescesConsecutiveBindings() {
        let next = intent(actionID: "provider.next")
        var queue = TerminalProviderActionQueue()

        for _ in 0 ..< 40 { queue.enqueue(next, coalescesRepeatCount: true) }

        #expect(queue.dequeue()?.repeatCount == 32)
        #expect(queue.dequeue()?.repeatCount == 8)
        #expect(queue.dequeue() == nil)
    }

    @Test("反向滑动保持用户输入顺序")
    func preservesDirectionOrder() {
        let next = intent(actionID: "provider.next")
        let previous = intent(actionID: "provider.previous")
        var queue = TerminalProviderActionQueue()

        queue.enqueue(next, coalescesRepeatCount: true)
        queue.enqueue(next, coalescesRepeatCount: true)
        queue.enqueue(previous, coalescesRepeatCount: true)
        queue.enqueue(next, coalescesRepeatCount: true)

        let batches = [queue.dequeue(), queue.dequeue(), queue.dequeue()].compactMap { $0 }
        #expect(batches.map(\.actionID) == [
            "provider.next", "provider.previous", "provider.next",
        ])
        #expect(batches.map(\.repeatCount) == [2, 1, 1])
    }

    @Test("快速点击新建 Window 和 Pane 保持每次操作及全局顺序")
    func preservesEveryOrdinaryButtonIntent() {
        var queue = TerminalProviderActionQueue()

        queue.enqueue(intent(actionID: "tmux.window.new"))
        queue.enqueue(intent(actionID: "tmux.window.new"))
        queue.enqueue(intent(actionID: "tmux.pane.split-horizontal"))
        queue.enqueue(intent(actionID: "tmux.pane.split-vertical"))

        var actionIDs: [String] = []
        while let next = queue.dequeue() {
            actionIDs.append(next.actionID)
            #expect(next.repeatCount == 1)
        }
        #expect(actionIDs == [
            "tmux.window.new",
            "tmux.window.new",
            "tmux.pane.split-horizontal",
            "tmux.pane.split-vertical",
        ])
    }

    @Test("破坏性操作不与相邻意图合并")
    func destructiveActionsRemainIndividual() {
        var queue = TerminalProviderActionQueue()
        let close = intent(actionID: "tmux.pane.close", confirmsDestructiveAction: true)

        queue.enqueue(close, coalescesRepeatCount: true)
        queue.enqueue(close, coalescesRepeatCount: true)

        #expect(queue.count == 2)
        #expect(queue.dequeue()?.repeatCount == 1)
        #expect(queue.dequeue()?.repeatCount == 1)
    }

    private func intent(
        actionID: String,
        confirmsDestructiveAction: Bool = false
    ) -> TerminalProviderActionIntent {
        .init(
            actionID: actionID,
            argument: nil,
            confirmsDestructiveAction: confirmsDestructiveAction,
            successNoticeKey: nil,
            unavailableNoticeKey: nil,
            completionEffect: nil,
            repeatCount: 1
        )
    }
}
