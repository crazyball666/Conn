import ConnSSH
import Foundation

package enum TmuxSnapshotIdentifierField: Sendable, Equatable {
    case sessionID
    case windowID
    case paneID
}

package enum TmuxSnapshotNumberField: Sendable, Equatable {
    case serverProcessID
    case serverStartTime
    case windowIndex
    case paneIndex
    case paneWidth
    case paneHeight
    case paneHistorySize
    case paneHistoryLimit
    case clientProcessID
    case clientCreationTime
}

package enum TmuxSnapshotBooleanField: Sendable, Equatable {
    case windowActive
    case windowZoomed
    case paneDead
    case paneActive
    case paneAlternateOn
    case paneInMode
    case paneMouseAnyFlag
    case clientControlMode
}

package enum TmuxSnapshotAssemblerError: Error, Sendable, Equatable {
    case serverIdentityMismatch
    case serverTokenMismatch
    case invalidIdentifier(TmuxSnapshotIdentifierField)
    case invalidNumber(TmuxSnapshotNumberField)
    case invalidBoolean(TmuxSnapshotBooleanField)
    case duplicateSession(TmuxSessionID)
    case duplicateWindowLink(TmuxSessionID, TmuxWindowID, Int)
    case duplicateWindowIndex(TmuxSessionID, Int)
    case duplicateCurrentWindow(TmuxSessionID)
    case conflictingWindow(TmuxWindowID)
    case duplicatePane(TmuxPaneID)
    case duplicateActivePane(TmuxWindowID)
    case missingActivePane(TmuxWindowID)
    case duplicateClient(TmuxClientID)
    case missingCurrentWindow(TmuxSessionID)
    case invalidClientTarget
    case invalidClientFlags
    case conflictingClientOwnership(TmuxClientID)
    case interactiveClientMissing(TmuxClientID)
    case interactiveClientSessionMismatch(TmuxClientID)
    case interactiveClientKindMismatch(TmuxClientID)
    case controlClientMissing(TmuxClientID)
    case controlClientKindMismatch(TmuxClientID)
}

package enum TmuxDecodedSnapshotText: Sendable, Equatable {
    case value(String)
    case unavailable
}

package struct TmuxDecodedServerIdentityRecord: Sendable, Equatable {
    package let resolvedSocketPath: String
    package let serverPID: String
    package let serverStartTime: String
    package let version: TmuxDecodedSnapshotText

    package init(
        resolvedSocketPath: String,
        serverPID: String,
        serverStartTime: String,
        version: TmuxDecodedSnapshotText
    ) {
        self.resolvedSocketPath = resolvedSocketPath
        self.serverPID = serverPID
        self.serverStartTime = serverStartTime
        self.version = version
    }
}

package struct TmuxDecodedSessionRecord: Sendable, Equatable {
    package let id: String
    package let name: String
    package let groupName: String

    package init(id: String, name: String, groupName: String) {
        self.id = id
        self.name = name
        self.groupName = groupName
    }
}

package struct TmuxDecodedWindowLinkRecord: Sendable, Equatable {
    package let sessionID: String
    package let windowID: String
    package let index: String
    package let isCurrent: String

    package init(sessionID: String, windowID: String, index: String, isCurrent: String) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.index = index
        self.isCurrent = isCurrent
    }
}

package struct TmuxDecodedWindowRecord: Sendable, Equatable {
    package let id: String
    package let name: String
    package let layout: TmuxDecodedSnapshotText
    package let isZoomed: String

    package init(
        id: String,
        name: String,
        layout: TmuxDecodedSnapshotText,
        isZoomed: String
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.isZoomed = isZoomed
    }
}

package struct TmuxDecodedPaneRecord: Sendable, Equatable {
    package let id: String
    package let windowID: String
    package let index: String
    package let title: TmuxDecodedSnapshotText
    package let currentCommand: TmuxDecodedSnapshotText
    package let currentPath: TmuxDecodedSnapshotText
    package let alternateOn: TmuxDecodedSnapshotText
    package let paneInMode: TmuxDecodedSnapshotText
    package let paneMode: TmuxDecodedSnapshotText
    package let mouseAnyFlag: TmuxDecodedSnapshotText
    package let historySize: TmuxDecodedSnapshotText
    package let historyLimit: TmuxDecodedSnapshotText
    package let width: String
    package let height: String
    package let isDead: String
    package let isActive: String

    package init(
        id: String,
        windowID: String,
        index: String,
        title: TmuxDecodedSnapshotText,
        currentCommand: TmuxDecodedSnapshotText,
        currentPath: TmuxDecodedSnapshotText,
        alternateOn: TmuxDecodedSnapshotText = .unavailable,
        paneInMode: TmuxDecodedSnapshotText = .unavailable,
        paneMode: TmuxDecodedSnapshotText = .unavailable,
        mouseAnyFlag: TmuxDecodedSnapshotText = .unavailable,
        historySize: TmuxDecodedSnapshotText = .unavailable,
        historyLimit: TmuxDecodedSnapshotText = .unavailable,
        width: String,
        height: String,
        isDead: String,
        isActive: String
    ) {
        self.id = id
        self.windowID = windowID
        self.index = index
        self.title = title
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.alternateOn = alternateOn
        self.paneInMode = paneInMode
        self.paneMode = paneMode
        self.mouseAnyFlag = mouseAnyFlag
        self.historySize = historySize
        self.historyLimit = historyLimit
        self.width = width
        self.height = height
        self.isDead = isDead
        self.isActive = isActive
    }
}

package struct TmuxDecodedClientRecord: Sendable, Equatable {
    package let targetName: String
    package let tty: TmuxDecodedSnapshotText
    package let processID: String
    package let createdAt: String
    package let sessionID: String
    package let currentWindowID: String
    package let activePaneID: String
    package let flags: TmuxDecodedSnapshotText
    package let controlMode: String

    package init(
        targetName: String,
        tty: TmuxDecodedSnapshotText,
        processID: String,
        createdAt: String,
        sessionID: String,
        currentWindowID: String,
        activePaneID: String,
        flags: TmuxDecodedSnapshotText,
        controlMode: String
    ) {
        self.targetName = targetName
        self.tty = tty
        self.processID = processID
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.currentWindowID = currentWindowID
        self.activePaneID = activePaneID
        self.flags = flags
        self.controlMode = controlMode
    }
}

package struct TmuxDecodedSnapshotRecords: Sendable, Equatable {
    package let identityBefore: TmuxDecodedServerIdentityRecord
    package let identityAfter: TmuxDecodedServerIdentityRecord
    package let sessions: [TmuxDecodedSessionRecord]
    package let windowLinks: [TmuxDecodedWindowLinkRecord]
    package let windows: [TmuxDecodedWindowRecord]
    package let panes: [TmuxDecodedPaneRecord]
    package let clients: [TmuxDecodedClientRecord]

    package init(
        identityBefore: TmuxDecodedServerIdentityRecord,
        identityAfter: TmuxDecodedServerIdentityRecord,
        sessions: [TmuxDecodedSessionRecord],
        windowLinks: [TmuxDecodedWindowLinkRecord],
        windows: [TmuxDecodedWindowRecord],
        panes: [TmuxDecodedPaneRecord],
        clients: [TmuxDecodedClientRecord]
    ) {
        self.identityBefore = identityBefore
        self.identityAfter = identityAfter
        self.sessions = sessions
        self.windowLinks = windowLinks
        self.windows = windows
        self.panes = panes
        self.clients = clients
    }
}

/// Converts section-specific decoded records into one normalized and fully validated graph.
/// This type neither executes commands nor understands transport or platform selection.
package struct TmuxSnapshotAssembler: Sendable {
    package init() {}

    package func assemble(
        _ records: TmuxDecodedSnapshotRecords,
        scope: TmuxOperationScope,
        identities: Set<TmuxControlInteractiveIdentity>,
        controlClientID: TmuxClientID?,
        observedAt: Date
    ) throws -> TmuxServerSnapshot {
        let before = try serverIdentity(records.identityBefore)
        let after = try serverIdentity(records.identityAfter)
        guard before == after else {
            throw TmuxSnapshotAssemblerError.serverIdentityMismatch
        }
        guard before.token == scope.instanceToken else {
            throw TmuxSnapshotAssemblerError.serverTokenMismatch
        }

        let sessions = try assembleSessions(records.sessions)
        let links = try assembleWindowLinks(records.windowLinks)
        let windows = try assembleWindows(records.windows)
        let panes = try assemblePanes(records.panes, observedAt: observedAt)

        let currentWindows = try currentWindowMap(records.windowLinks)
        let activePanes = try activePaneMap(records.panes)
        var adjustedSessions = sessions
        for (sessionID, currentWindowID) in currentWindows {
            guard let session = sessions[sessionID] else { continue }
            adjustedSessions[sessionID] = TmuxSessionSnapshot(
                id: session.id,
                name: session.name,
                groupName: session.groupName,
                currentWindowID: currentWindowID
            )
        }
        for sessionID in sessions.keys where currentWindows[sessionID] == nil {
            throw TmuxSnapshotAssemblerError.missingCurrentWindow(sessionID)
        }

        var adjustedWindows = windows
        for (windowID, activePaneID) in activePanes {
            guard let window = windows[windowID] else { continue }
            adjustedWindows[windowID] = TmuxWindowSnapshot(
                id: window.id,
                name: window.name,
                layout: window.layout,
                isZoomed: window.isZoomed,
                activePaneID: activePaneID
            )
        }
        for windowID in windows.keys where activePanes[windowID] == nil {
            throw TmuxSnapshotAssemblerError.missingActivePane(windowID)
        }

        let clients = try assembleClients(
            records.clients,
            identities: identities,
            controlClientID: controlClientID,
            observedAt: observedAt
        )

        var groups: [String: Set<TmuxSessionID>] = [:]
        for session in adjustedSessions.values {
            if let groupName = session.groupName {
                groups[groupName, default: []].insert(session.id)
            }
        }

        return try TmuxServerSnapshot(
            instance: before,
            sessions: adjustedSessions,
            sessionGroups: groups,
            windows: adjustedWindows,
            panes: panes,
            windowLinks: links,
            clients: clients,
            observedAt: observedAt,
            revision: 0,
            impactRevision: 0
        )
    }

    private func serverIdentity(
        _ record: TmuxDecodedServerIdentityRecord
    ) throws -> TmuxServerInstance {
        let processID: Int32 = try positiveInteger(
            record.serverPID,
            field: .serverProcessID
        )
        let startTime: Int64 = try positiveInteger(
            record.serverStartTime,
            field: .serverStartTime
        )
        let token: TmuxServerInstanceToken
        do {
            token = try TmuxServerInstanceToken(
                resolvedSocketPath: record.resolvedSocketPath,
                serverPID: processID,
                serverStartTime: startTime
            )
        } catch {
            throw TmuxSnapshotAssemblerError.serverTokenMismatch
        }
        let version: String?
        switch record.version {
        case let .value(value): version = value.isEmpty ? nil : value
        case .unavailable: version = nil
        }
        return TmuxServerInstance(token: token, version: version)
    }

    private func assembleSessions(
        _ records: [TmuxDecodedSessionRecord]
    ) throws -> [TmuxSessionID: TmuxSessionSnapshot] {
        var result: [TmuxSessionID: TmuxSessionSnapshot] = [:]
        for record in records {
            let id = try sessionID(record.id)
            guard result[id] == nil else {
                throw TmuxSnapshotAssemblerError.duplicateSession(id)
            }
            result[id] = TmuxSessionSnapshot(
                id: id,
                name: record.name,
                groupName: record.groupName.isEmpty ? nil : record.groupName,
                currentWindowID: nil
            )
        }
        return result
    }

    private func assembleWindowLinks(
        _ records: [TmuxDecodedWindowLinkRecord]
    ) throws -> [TmuxWindowLink] {
        var result: [TmuxWindowLink] = []
        var links: Set<TmuxWindowLink> = []
        var indexes: Set<SessionWindowIndex> = []
        for record in records {
            let sessionID = try sessionID(record.sessionID)
            let windowID = try windowID(record.windowID)
            let index: Int = try nonnegativeInteger(record.index, field: .windowIndex)
            _ = try boolean(record.isCurrent, field: .windowActive)
            let link = TmuxWindowLink(
                sessionID: sessionID,
                windowID: windowID,
                index: index
            )
            guard links.insert(link).inserted else {
                throw TmuxSnapshotAssemblerError.duplicateWindowLink(
                    sessionID,
                    windowID,
                    index
                )
            }
            guard indexes.insert(.init(sessionID: sessionID, index: index)).inserted else {
                throw TmuxSnapshotAssemblerError.duplicateWindowIndex(sessionID, index)
            }
            result.append(link)
        }
        return result
    }

    private func currentWindowMap(
        _ records: [TmuxDecodedWindowLinkRecord]
    ) throws -> [TmuxSessionID: TmuxWindowID] {
        var result: [TmuxSessionID: TmuxWindowID] = [:]
        for record in records {
            let sessionID = try sessionID(record.sessionID)
            guard try boolean(record.isCurrent, field: .windowActive) else { continue }
            let windowID = try windowID(record.windowID)
            guard result.updateValue(windowID, forKey: sessionID) == nil else {
                throw TmuxSnapshotAssemblerError.duplicateCurrentWindow(sessionID)
            }
        }
        return result
    }

    private func assembleWindows(
        _ records: [TmuxDecodedWindowRecord]
    ) throws -> [TmuxWindowID: TmuxWindowSnapshot] {
        var result: [TmuxWindowID: TmuxWindowSnapshot] = [:]
        for record in records {
            let id = try windowID(record.id)
            let window = TmuxWindowSnapshot(
                id: id,
                name: record.name,
                layout: optionalText(record.layout),
                isZoomed: try boolean(record.isZoomed, field: .windowZoomed),
                activePaneID: nil
            )
            if let existing = result[id] {
                guard existing == window else {
                    throw TmuxSnapshotAssemblerError.conflictingWindow(id)
                }
            } else {
                result[id] = window
            }
        }
        return result
    }

    private func assemblePanes(
        _ records: [TmuxDecodedPaneRecord],
        observedAt: Date
    ) throws -> [TmuxPaneID: TmuxPaneSnapshot] {
        var result: [TmuxPaneID: TmuxPaneSnapshot] = [:]
        for record in records {
            let id = try paneID(record.id)
            guard result[id] == nil else {
                throw TmuxSnapshotAssemblerError.duplicatePane(id)
            }
            result[id] = TmuxPaneSnapshot(
                id: id,
                windowID: try windowID(record.windowID),
                index: try nonnegativeInteger(record.index, field: .paneIndex),
                title: observedValue(record.title, observedAt: observedAt),
                currentCommand: observedValue(record.currentCommand, observedAt: observedAt),
                currentPath: observedValue(record.currentPath, observedAt: observedAt),
                interaction: .init(
                    alternateOn: try observedBoolean(
                        record.alternateOn,
                        field: .paneAlternateOn,
                        observedAt: observedAt
                    ),
                    paneInMode: try observedBoolean(
                        record.paneInMode,
                        field: .paneInMode,
                        observedAt: observedAt
                    ),
                    mode: observedOptionalText(record.paneMode, observedAt: observedAt),
                    mouseAnyFlag: try observedBoolean(
                        record.mouseAnyFlag,
                        field: .paneMouseAnyFlag,
                        observedAt: observedAt
                    ),
                    historySize: try observedNonnegativeInteger(
                        record.historySize,
                        field: .paneHistorySize,
                        observedAt: observedAt
                    ),
                    historyLimit: try observedNonnegativeInteger(
                        record.historyLimit,
                        field: .paneHistoryLimit,
                        observedAt: observedAt
                    )
                ),
                size: .init(
                    cols: try positiveInteger(record.width, field: .paneWidth),
                    rows: try positiveInteger(record.height, field: .paneHeight)
                ),
                isDead: try boolean(record.isDead, field: .paneDead)
            )
        }
        return result
    }

    private func activePaneMap(
        _ records: [TmuxDecodedPaneRecord]
    ) throws -> [TmuxWindowID: TmuxPaneID] {
        var result: [TmuxWindowID: TmuxPaneID] = [:]
        for record in records {
            let windowID = try windowID(record.windowID)
            guard try boolean(record.isActive, field: .paneActive) else { continue }
            let paneID = try paneID(record.id)
            guard result.updateValue(paneID, forKey: windowID) == nil else {
                throw TmuxSnapshotAssemblerError.duplicateActivePane(windowID)
            }
        }
        return result
    }

    private func assembleClients(
        _ records: [TmuxDecodedClientRecord],
        identities: Set<TmuxControlInteractiveIdentity>,
        controlClientID: TmuxClientID?,
        observedAt: Date
    ) throws -> [TmuxClientID: TmuxClientSnapshot] {
        var identityByClient: [TmuxClientID: TmuxControlInteractiveIdentity] = [:]
        for identity in identities {
            guard identityByClient.updateValue(identity, forKey: identity.clientID) == nil else {
                throw TmuxSnapshotAssemblerError.conflictingClientOwnership(identity.clientID)
            }
        }
        if let controlClientID, identityByClient[controlClientID] != nil {
            throw TmuxSnapshotAssemblerError.conflictingClientOwnership(controlClientID)
        }

        var result: [TmuxClientID: TmuxClientSnapshot] = [:]
        for record in records {
            let id = try clientID(record)
            guard result[id] == nil else {
                throw TmuxSnapshotAssemblerError.duplicateClient(id)
            }
            let sessionID = try sessionID(record.sessionID)
            let controlMode = try optionalBoolean(
                record.controlMode,
                field: .clientControlMode
            )
            let observedKind: TmuxClientKind
            switch controlMode {
            case true: observedKind = .controlMode
            case false: observedKind = .interactiveTerminal
            case nil: observedKind = .unknown
            }
            let flags = try clientFlags(record.flags)
            let role: TmuxClientRole
            let sizeParticipation: TmuxClientSizeParticipation
            let kind: TmuxClientKind
            if let identity = identityByClient[id] {
                guard identity.requestedSessionID == sessionID else {
                    throw TmuxSnapshotAssemblerError.interactiveClientSessionMismatch(id)
                }
                guard observedKind != .controlMode else {
                    throw TmuxSnapshotAssemblerError.interactiveClientKindMismatch(id)
                }
                role = .connInteractive(attachmentID: identity.attachmentID)
                kind = observedKind
                sizeParticipation = participation(flags: flags, kind: kind)
            } else if id == controlClientID {
                guard observedKind != .interactiveTerminal else {
                    throw TmuxSnapshotAssemblerError.controlClientKindMismatch(id)
                }
                role = .connControl(sessionID: sessionID)
                kind = .controlMode
                sizeParticipation = .notParticipating
            } else {
                role = .external
                kind = observedKind
                sizeParticipation = participation(flags: flags, kind: kind)
            }

            result[id] = TmuxClientSnapshot(
                id: id,
                sessionID: sessionID,
                currentWindowID: try optionalWindowID(record.currentWindowID),
                activePaneID: try optionalPaneID(record.activePaneID),
                flags: flags,
                role: role,
                kind: kind,
                sizeParticipation: sizeParticipation,
                observedAt: observedAt,
                tty: optionalText(record.tty)
            )
        }

        for id in identityByClient.keys where result[id] == nil {
            throw TmuxSnapshotAssemblerError.interactiveClientMissing(id)
        }
        if let controlClientID, result[controlClientID] == nil {
            throw TmuxSnapshotAssemblerError.controlClientMissing(controlClientID)
        }
        return result
    }

    private func clientID(_ record: TmuxDecodedClientRecord) throws -> TmuxClientID {
        guard !record.targetName.isEmpty,
              record.targetName.utf8.count <= TmuxClientTarget.maximumUTF8Length,
              !containsControlCharacter(record.targetName)
        else {
            throw TmuxSnapshotAssemblerError.invalidClientTarget
        }
        let processID: Int32? = record.processID.isEmpty
            ? nil
            : try positiveInteger(record.processID, field: .clientProcessID)
        let createdAt: Int64? = record.createdAt.isEmpty
            ? nil
            : try positiveInteger(record.createdAt, field: .clientCreationTime)
        return TmuxClientID(
            targetName: record.targetName,
            processID: processID,
            createdAt: createdAt
        )
    }

    private func clientFlags(
        _ value: TmuxDecodedSnapshotText
    ) throws -> Set<TmuxClientFlag>? {
        guard case let .value(rawValue) = value else { return nil }
        guard !containsControlCharacter(rawValue) else {
            throw TmuxSnapshotAssemblerError.invalidClientFlags
        }
        if rawValue.isEmpty { return [] }
        let components = rawValue.split(separator: ",", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }) else {
            throw TmuxSnapshotAssemblerError.invalidClientFlags
        }

        var flags: Set<TmuxClientFlag> = []
        for component in components {
            let value = String(component)
            guard isWellFramedClientFlag(value) else {
                throw TmuxSnapshotAssemblerError.invalidClientFlags
            }
            switch value {
            case "no-output": flags.insert(.noOutput)
            case "wait-exit": flags.insert(.waitExit)
            case "ignore-size": flags.insert(.ignoreSize)
            case "active-pane": flags.insert(.activePane)
            case "pause-after": flags.insert(.pauseAfter)
            default:
                if value.hasPrefix("pause-after=") {
                    let suffix = value.dropFirst("pause-after=".count)
                    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else {
                        throw TmuxSnapshotAssemblerError.invalidClientFlags
                    }
                    flags.insert(.pauseAfter)
                }
                // tmux exposes descriptive and future flags in the same comma-separated field.
                // Unknown well-framed values are intentionally ignored for forward compatibility.
            }
        }
        return flags
    }

    private func isWellFramedClientFlag(_ value: String) -> Bool {
        let parts = value.split(separator: "=", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count),
              !parts[0].isEmpty,
              parts.allSatisfy({ !$0.isEmpty })
        else {
            return false
        }
        return parts.allSatisfy { part in
            part.utf8.allSatisfy { byte in
                (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
                    || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                    || byte == UInt8(ascii: "-")
                    || byte == UInt8(ascii: "_")
                    || byte == UInt8(ascii: ".")
            }
        }
    }

    private func participation(
        flags: Set<TmuxClientFlag>?,
        kind: TmuxClientKind
    ) -> TmuxClientSizeParticipation {
        guard let flags else { return .unknown }
        if flags.contains(.ignoreSize) { return .ignored }
        return kind == .interactiveTerminal ? .participating : .unknown
    }

    private func sessionID(_ value: String) throws -> TmuxSessionID {
        guard let id = TmuxSessionID(rawValue: value) else {
            throw TmuxSnapshotAssemblerError.invalidIdentifier(.sessionID)
        }
        return id
    }

    private func windowID(_ value: String) throws -> TmuxWindowID {
        guard let id = TmuxWindowID(rawValue: value) else {
            throw TmuxSnapshotAssemblerError.invalidIdentifier(.windowID)
        }
        return id
    }

    private func paneID(_ value: String) throws -> TmuxPaneID {
        guard let id = TmuxPaneID(rawValue: value) else {
            throw TmuxSnapshotAssemblerError.invalidIdentifier(.paneID)
        }
        return id
    }

    private func optionalWindowID(_ value: String) throws -> TmuxWindowID? {
        value.isEmpty ? nil : try windowID(value)
    }

    private func optionalPaneID(_ value: String) throws -> TmuxPaneID? {
        value.isEmpty ? nil : try paneID(value)
    }

    private func positiveInteger<T: FixedWidthInteger>(
        _ value: String,
        field: TmuxSnapshotNumberField
    ) throws -> T {
        guard let parsed = T(value), parsed > 0 else {
            throw TmuxSnapshotAssemblerError.invalidNumber(field)
        }
        return parsed
    }

    private func nonnegativeInteger<T: FixedWidthInteger>(
        _ value: String,
        field: TmuxSnapshotNumberField
    ) throws -> T {
        guard let parsed = T(value), parsed >= 0 else {
            throw TmuxSnapshotAssemblerError.invalidNumber(field)
        }
        return parsed
    }

    private func boolean(
        _ value: String,
        field: TmuxSnapshotBooleanField
    ) throws -> Bool {
        guard let value = try optionalBoolean(value, field: field) else {
            throw TmuxSnapshotAssemblerError.invalidBoolean(field)
        }
        return value
    }

    private func optionalBoolean(
        _ value: String,
        field: TmuxSnapshotBooleanField
    ) throws -> Bool? {
        switch value {
        case "0": false
        case "1": true
        case "": nil
        default: throw TmuxSnapshotAssemblerError.invalidBoolean(field)
        }
    }

    private func optionalText(_ text: TmuxDecodedSnapshotText) -> String? {
        switch text {
        case let .value(value): value.isEmpty ? nil : value
        case .unavailable: nil
        }
    }

    private func observedValue(
        _ text: TmuxDecodedSnapshotText,
        observedAt: Date
    ) -> TmuxObservedValue<String> {
        switch text {
        case let .value(value):
            TmuxObservedValue(
                value: value,
                freshness: .snapshot(observedAt: observedAt)
            )
        case .unavailable:
            .unavailable
        }
    }

    private func observedOptionalText(
        _ text: TmuxDecodedSnapshotText,
        observedAt: Date
    ) -> TmuxObservedValue<String> {
        guard case let .value(value) = text, !value.isEmpty else { return .unavailable }
        return .init(value: value, freshness: .snapshot(observedAt: observedAt))
    }

    private func observedBoolean(
        _ text: TmuxDecodedSnapshotText,
        field: TmuxSnapshotBooleanField,
        observedAt: Date
    ) throws -> TmuxObservedValue<Bool> {
        guard case let .value(value) = text, !value.isEmpty else { return .unavailable }
        return .init(
            value: try boolean(value, field: field),
            freshness: .snapshot(observedAt: observedAt)
        )
    }

    private func observedNonnegativeInteger(
        _ text: TmuxDecodedSnapshotText,
        field: TmuxSnapshotNumberField,
        observedAt: Date
    ) throws -> TmuxObservedValue<Int> {
        guard case let .value(value) = text, !value.isEmpty else { return .unavailable }
        return .init(
            value: try nonnegativeInteger(value, field: field),
            freshness: .snapshot(observedAt: observedAt)
        )
    }

    private func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
        }
    }
}

private struct SessionWindowIndex: Hashable {
    let sessionID: TmuxSessionID
    let index: Int
}
