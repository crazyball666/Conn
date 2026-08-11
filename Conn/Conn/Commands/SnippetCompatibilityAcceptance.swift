/// Pure gate for accepting asynchronous host-preparation results.
enum SnippetCompatibilityAcceptance {
    static func shouldAccept(
        hostID: String,
        selectedHostIDs: Set<String>,
        capturedGeneration: UInt64,
        currentGeneration: UInt64?
    ) -> Bool {
        selectedHostIDs.contains(hostID)
            && currentGeneration == capturedGeneration
    }
}
