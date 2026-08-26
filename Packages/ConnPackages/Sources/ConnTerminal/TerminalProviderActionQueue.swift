import ConnMultiplexer

/// One provider-neutral user intent waiting for the persistent-terminal command channel.
/// The request target is intentionally absent: it is resolved from the attachment's latest
/// state only when this intent reaches the head of the queue.
struct TerminalProviderActionIntent: Equatable {
    let actionID: String
    let argument: String?
    let confirmsDestructiveAction: Bool
    let successNoticeKey: String?
    let unavailableNoticeKey: String?
    let completionEffect: PersistentTerminalActionEffect?
    var repeatCount: Int
}

/// Preserves a single total order across provider buttons and terminal swipe gestures.
/// Consecutive relative navigation gestures are compacted because their provider contract
/// explicitly supports repeat counts; ordinary and destructive buttons always remain
/// individual intents.
struct TerminalProviderActionQueue {
    static let maximumPendingIntentCount = 64

    private var pending: [TerminalProviderActionIntent] = []

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    @discardableResult
    mutating func enqueue(
        _ intent: TerminalProviderActionIntent,
        coalescesRepeatCount: Bool = false
    ) -> Bool {
        if coalescesRepeatCount,
           let lastIndex = pending.indices.last,
           pending[lastIndex].actionID == intent.actionID,
           pending[lastIndex].argument == nil,
           intent.argument == nil,
           !pending[lastIndex].confirmsDestructiveAction,
           !intent.confirmsDestructiveAction,
           pending[lastIndex].repeatCount
            < PersistentTerminalQuickActionRequest.maximumRepeatCount
        {
            pending[lastIndex].repeatCount += intent.repeatCount
            if pending[lastIndex].repeatCount
                > PersistentTerminalQuickActionRequest.maximumRepeatCount
            {
                let overflow = pending[lastIndex].repeatCount
                    - PersistentTerminalQuickActionRequest.maximumRepeatCount
                pending[lastIndex].repeatCount =
                    PersistentTerminalQuickActionRequest.maximumRepeatCount
                guard pending.count < Self.maximumPendingIntentCount else { return false }
                var overflowIntent = intent
                overflowIntent.repeatCount = overflow
                pending.append(overflowIntent)
            }
            return true
        }

        guard pending.count < Self.maximumPendingIntentCount else { return false }
        pending.append(intent)
        return true
    }

    mutating func dequeue() -> TerminalProviderActionIntent? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    mutating func removeAll() {
        pending.removeAll(keepingCapacity: true)
    }
}
