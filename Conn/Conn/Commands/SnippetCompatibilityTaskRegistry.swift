import Foundation

@MainActor
final class SnippetCompatibilityTaskRegistry {
    struct Claim: Sendable {
        fileprivate let hostID: String
        fileprivate let token: UUID
    }

    struct Accepted<Value: Sendable>: Sendable {
        let hostID: String
        let value: Value
    }

    private struct Entry {
        let token: UUID
        var task: Task<Void, Never>?
    }

    private var entries: [String: Entry] = [:]

    func replace(
        hostID: String,
        operation: @escaping @MainActor @Sendable (Claim) async -> Void
    ) {
        entries.removeValue(forKey: hostID)?.task?.cancel()

        let claim = Claim(hostID: hostID, token: UUID())
        entries[hostID] = Entry(token: claim.token, task: nil)
        let task = Task { @MainActor [weak self] in
            await operation(claim)
            self?.complete(claim)
        }
        guard entries[hostID]?.token == claim.token else {
            task.cancel()
            return
        }
        entries[hostID]?.task = task
    }

    func accept<Value: Sendable>(
        _ value: Value,
        for claim: Claim
    ) -> Accepted<Value>? {
        guard
            !Task.isCancelled,
            let entry = entries[claim.hostID],
            entry.token == claim.token,
            let task = entry.task,
            !task.isCancelled
        else {
            return nil
        }
        return Accepted(hostID: claim.hostID, value: value)
    }

    func cancel(hostID: String) {
        entries.removeValue(forKey: hostID)?.task?.cancel()
    }

    func cancelAll() {
        let tasks = entries.values.compactMap(\.task)
        entries.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func complete(_ claim: Claim) {
        guard entries[claim.hostID]?.token == claim.token else { return }
        entries[claim.hostID] = nil
    }
}
