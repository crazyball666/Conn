import Foundation

enum SnippetDangerConfirmationPolicy {
    static let batchPhrase = "RUN"

    static func requiresTypedConfirmation(hostCount: Int) -> Bool {
        hostCount > 1
    }

    static func accepts(_ input: String, hostCount: Int) -> Bool {
        !requiresTypedConfirmation(hostCount: hostCount) || input == batchPhrase
    }
}
