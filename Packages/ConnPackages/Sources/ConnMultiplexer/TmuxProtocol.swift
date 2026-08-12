import Foundation

package enum TmuxProtocolMarker {
    package static let start = Data([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
    package static let end = Data([0x1B, 0x5C])
}

/// The command guard emitted by tmux changed in tmux 2.7. Keeping the shape in an
/// explicit dialect prevents a malformed stream from being silently interpreted as a
/// different protocol version.
package enum TmuxCommandGuardShape: Sendable, Equatable {
    case twoFields
    case threeFields
}

package enum TmuxSnapshotCodecKind: Sendable, Equatable {
    case legacyPerField
    case quoted
}

package struct TmuxProtocolDialect: Sendable, Equatable {
    package let commandGuardShape: TmuxCommandGuardShape
    package let snapshotCodec: TmuxSnapshotCodecKind

    package init(
        commandGuardShape: TmuxCommandGuardShape,
        snapshotCodec: TmuxSnapshotCodecKind
    ) {
        self.commandGuardShape = commandGuardShape
        self.snapshotCodec = snapshotCodec
    }
}

public enum TmuxClientFlag: String, Codable, Sendable, Hashable, CaseIterable {
    case noOutput = "no-output"
    case waitExit = "wait-exit"
    case ignoreSize = "ignore-size"
    case activePane = "active-pane"
    case pauseAfter = "pause-after"
}

package struct TmuxNegotiatedCapabilities: Sendable, Equatable {
    package let supportedClientFlags: Set<TmuxClientFlag>
    package let supportsFormatSubscriptions: Bool

    package init(
        supportedClientFlags: Set<TmuxClientFlag>,
        supportsFormatSubscriptions: Bool
    ) {
        self.supportedClientFlags = supportedClientFlags
        self.supportsFormatSubscriptions = supportsFormatSubscriptions
    }
}

package struct TmuxControlClientConfiguration: Sendable, Equatable {
    package let enabledClientFlags: Set<TmuxClientFlag>
    package let activeSubscriptionNames: Set<String>

    package init(
        enabledClientFlags: Set<TmuxClientFlag>,
        activeSubscriptionNames: Set<String>
    ) {
        self.enabledClientFlags = enabledClientFlags
        self.activeSubscriptionNames = activeSubscriptionNames
    }
}

package struct TmuxCommandGuard: Sendable, Equatable {
    package let time: Int64
    package let commandNumber: UInt64
    package let flags: UInt64?

    package init(time: Int64, commandNumber: UInt64, flags: UInt64?) {
        self.time = time
        self.commandNumber = commandNumber
        self.flags = flags
    }
}

/// Notifications with stable semantics that the state-reconciliation layer may consume.
/// Unknown notifications remain lossless protocol events so newer tmux releases stay
/// forward-compatible.
package enum TmuxKnownNotification: String, Sendable, Equatable {
    case paneModeChanged = "pane-mode-changed"
    case windowPaneChanged = "window-pane-changed"
    case windowClose = "window-close"
    case unlinkedWindowClose = "unlinked-window-close"
    case windowAdd = "window-add"
    case unlinkedWindowAdd = "unlinked-window-add"
    case windowRenamed = "window-renamed"
    case unlinkedWindowRenamed = "unlinked-window-renamed"
    case sessionChanged = "session-changed"
    case clientSessionChanged = "client-session-changed"
    case sessionRenamed = "session-renamed"
    case sessionsChanged = "sessions-changed"
    case sessionWindowChanged = "session-window-changed"
    case layoutChange = "layout-change"
    case subscriptionChanged = "subscription-changed"
    case pause
    case `continue`
    case clientDetached = "client-detached"
}

package enum TmuxNotification: Sendable, Equatable {
    case known(TmuxKnownNotification, payload: Data)
    case unknown(name: String, payload: Data)
    case paneOutput(TmuxPaneID, Data)
    case extendedPaneOutput(TmuxPaneID, ageMilliseconds: Int, data: Data)
    case exit(reason: Data)
}

package enum TmuxProtocolEvent: Sendable, Equatable {
    case protocolStarted
    case commandBegin(TmuxCommandGuard)
    case commandOutput(Data)
    case commandEnd(TmuxCommandGuard)
    case commandError(TmuxCommandGuard)
    case notification(TmuxNotification)
    case protocolEnded
}

package struct TmuxProtocolParserLimits: Sendable, Equatable {
    package static let `default` = Self(
        maxPreambleBytes: 4 * 1_024,
        maxLineBytes: 1_024 * 1_024
    )

    package let maxPreambleBytes: Int
    package let maxLineBytes: Int

    package init(maxPreambleBytes: Int, maxLineBytes: Int) {
        precondition(maxPreambleBytes >= 0)
        precondition(maxLineBytes > 0)
        self.maxPreambleBytes = maxPreambleBytes
        self.maxLineBytes = maxLineBytes
    }
}

package enum TmuxProtocolParserError: Error, Sendable, Equatable {
    case invalidCommandGuard
    case nestedCommandBlock
    case unmatchedCommandTerminator
    case commandGuardMismatch(expected: TmuxCommandGuard, actual: TmuxCommandGuard)
    case invalidPaneOutput
    case preambleTooLong(limit: Int)
    case lineTooLong(limit: Int)
    case missingProtocolStart
    case incompleteLine
    case incompleteCommandBlock
    case missingProtocolEnd
    case unexpectedProtocolData
    case unexpectedDataAfterEnd
    case parserFailed
}
