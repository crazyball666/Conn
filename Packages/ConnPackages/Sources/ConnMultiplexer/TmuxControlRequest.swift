import Foundation

package enum TmuxControlRequestError: Error, Sendable, Equatable {
    case invalidCommand
    case invalidCompletionMarker
    case commandTooLong(maximumBytes: Int)
}

/// One already-rendered tmux command line accepted by the Control Mode correlator.
///
/// Construction is deliberately module-internal: sibling package targets may pass typed
/// requests returned by ConnMultiplexer APIs, but cannot turn an arbitrary string into one.
package struct TmuxControlRequest: Sendable, Equatable {
    package static let maximumCommandBytes = 64 * 1_024

    package let wireData: Data
    package let semantics: TmuxOperationSemantics
    /// A nonce-bound output line emitted by the final command in a command sequence.
    /// `nil` means the request consists of exactly one tmux response block.
    package let completionMarker: Data?

    internal init(
        renderedCommand: TmuxRenderedControlCommand,
        semantics: TmuxOperationSemantics,
        completionMarker: String? = nil
    ) throws {
        let containsControlCharacter = renderedCommand.value.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
        }
        let command = Data(renderedCommand.value.utf8)
        guard !command.isEmpty, !containsControlCharacter else {
            throw TmuxControlRequestError.invalidCommand
        }
        guard command.count <= Self.maximumCommandBytes else {
            throw TmuxControlRequestError.commandTooLong(
                maximumBytes: Self.maximumCommandBytes
            )
        }

        let markerData: Data?
        if let completionMarker {
            let containsControlCharacter = completionMarker.unicodeScalars.contains { scalar in
                scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
            }
            guard !completionMarker.isEmpty,
                  !containsControlCharacter,
                  renderedCommand.value.contains(completionMarker)
            else {
                throw TmuxControlRequestError.invalidCompletionMarker
            }
            markerData = Data(completionMarker.utf8)
        } else {
            markerData = nil
        }

        var wireData = command
        wireData.append(UInt8(ascii: "\n"))
        self.wireData = wireData
        self.semantics = semantics
        self.completionMarker = markerData
    }
}
