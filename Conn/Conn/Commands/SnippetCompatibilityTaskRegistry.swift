import Foundation

@MainActor
final class SnippetCompatibilityTaskRegistry {
    private struct Entry {
        let token: UUID
        var task: Task<Void, Never>?
    }

    private var entries: [String: Entry] = [:]

    func replace(
        hostID: String,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        entries.removeValue(forKey: hostID)?.task?.cancel()

        let token = UUID()
        entries[hostID] = Entry(token: token, task: nil)
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.complete(hostID: hostID, token: token)
        }
        guard entries[hostID]?.token == token else {
            task.cancel()
            return
        }
        entries[hostID]?.task = task
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

    private func complete(hostID: String, token: UUID) {
        guard entries[hostID]?.token == token else { return }
        entries[hostID] = nil
    }
}
