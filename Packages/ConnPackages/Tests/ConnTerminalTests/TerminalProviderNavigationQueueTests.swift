import ConnMultiplexer
import Testing
@testable import ConnTerminal

@Suite("Terminal provider navigation queue")
struct TerminalProviderNavigationQueueTests {
    @Test("连续同向滑动合并为受限批次且不丢次数")
    func coalescesConsecutiveBindings() {
        let next = binding(direction: .left, actionID: "provider.next")
        var queue = TerminalProviderNavigationQueue()

        for _ in 0 ..< 40 { queue.enqueue(next) }

        #expect(queue.dequeue()?.repeatCount == 32)
        #expect(queue.dequeue()?.repeatCount == 8)
        #expect(queue.dequeue() == nil)
    }

    @Test("反向滑动保持用户输入顺序")
    func preservesDirectionOrder() {
        let next = binding(direction: .left, actionID: "provider.next")
        let previous = binding(direction: .right, actionID: "provider.previous")
        var queue = TerminalProviderNavigationQueue()

        queue.enqueue(next)
        queue.enqueue(next)
        queue.enqueue(previous)
        queue.enqueue(next)

        let batches = [queue.dequeue(), queue.dequeue(), queue.dequeue()].compactMap { $0 }
        #expect(batches.map(\.binding.actionID) == [
            "provider.next", "provider.previous", "provider.next",
        ])
        #expect(batches.map(\.repeatCount) == [2, 1, 1])
    }

    private func binding(
        direction: PersistentTerminalHorizontalSwipeDirection,
        actionID: String
    ) -> PersistentTerminalSwipeActionDescriptor {
        .init(
            direction: direction,
            actionID: actionID,
            successNoticeKey: "Switched"
        )
    }
}
