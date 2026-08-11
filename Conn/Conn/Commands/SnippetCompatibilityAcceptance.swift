/// Pure host-keyed transition for accepting asynchronous host-preparation results.
nonisolated enum SnippetCompatibilityAcceptance {
    struct Accepted<Value: Sendable>: Sendable {
        let hostID: String
        let value: Value
    }

    static func accept<Value: Sendable>(
        hostID: String,
        value: Value,
        selectedHostIDs: Set<String>,
        capturedGeneration: UInt64,
        currentGeneration: UInt64?
    ) -> Accepted<Value>? {
        guard selectedHostIDs.contains(hostID),
              currentGeneration == capturedGeneration else {
            return nil
        }
        return Accepted(hostID: hostID, value: value)
    }
}
