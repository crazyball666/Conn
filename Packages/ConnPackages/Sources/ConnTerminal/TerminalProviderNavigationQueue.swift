import ConnMultiplexer

struct TerminalProviderNavigationBatch: Equatable {
    let binding: PersistentTerminalSwipeActionDescriptor
    let repeatCount: Int
}

/// Preserves gesture order while compacting consecutive identical provider actions.
/// Batches are capped at the provider-neutral request limit so hostile or accidental input
/// cannot create an unbounded remote command line.
struct TerminalProviderNavigationQueue {
    private struct Pending: Equatable {
        let binding: PersistentTerminalSwipeActionDescriptor
        var repeatCount: Int
    }

    private var pending: [Pending] = []

    var isEmpty: Bool { pending.isEmpty }

    mutating func enqueue(_ binding: PersistentTerminalSwipeActionDescriptor) {
        if let lastIndex = pending.indices.last,
           pending[lastIndex].binding.actionID == binding.actionID,
           pending[lastIndex].binding.direction == binding.direction,
           pending[lastIndex].repeatCount
            < PersistentTerminalQuickActionRequest.maximumRepeatCount
        {
            pending[lastIndex].repeatCount += 1
        } else {
            pending.append(Pending(binding: binding, repeatCount: 1))
        }
    }

    mutating func dequeue() -> TerminalProviderNavigationBatch? {
        guard !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        return TerminalProviderNavigationBatch(
            binding: next.binding,
            repeatCount: next.repeatCount
        )
    }

    mutating func removeAll() {
        pending.removeAll(keepingCapacity: true)
    }
}
