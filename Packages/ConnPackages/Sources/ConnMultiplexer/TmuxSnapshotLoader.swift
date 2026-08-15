import ConnSSH
import Foundation

package enum TmuxSnapshotLoaderError: Error, Sendable, Equatable {
    case invalidLimits
    case invalidTimeout
    case nonReadOnlyRequest
    case scopeMismatch(expected: TmuxOperationScope, actual: TmuxOperationScope)
    case staleGeneration
    case outputLimitExceeded(maximumBytes: Int, maximumLines: Int)
    case invalidFraming
    case missingSection(TmuxSnapshotSection)
    case recordCountMismatch(section: TmuxSnapshotSection, expected: Int, actual: Int)
    case duplicateLegacyRecord(TmuxSnapshotSection)
    case missingLegacyField(TmuxLegacySnapshotField)
    case tooManySteps(maximum: Int)
}

package struct TmuxSnapshotLoaderLimits: Sendable, Equatable {
    package static let `default` = Self(
        uncheckedMaximumOutputBytesPerStep: 4 * 1_024 * 1_024,
        maximumOutputLinesPerStep: 65_536,
        maximumSteps: 16_384
    )

    package let maximumOutputBytesPerStep: Int
    package let maximumOutputLinesPerStep: Int
    package let maximumSteps: Int

    package init(
        maximumOutputBytesPerStep: Int,
        maximumOutputLinesPerStep: Int,
        maximumSteps: Int
    ) throws {
        guard maximumOutputBytesPerStep > 0,
              maximumOutputLinesPerStep > 0,
              maximumSteps > 0
        else {
            throw TmuxSnapshotLoaderError.invalidLimits
        }
        self.maximumOutputBytesPerStep = maximumOutputBytesPerStep
        self.maximumOutputLinesPerStep = maximumOutputLinesPerStep
        self.maximumSteps = maximumSteps
    }

    private init(
        uncheckedMaximumOutputBytesPerStep maximumOutputBytesPerStep: Int,
        maximumOutputLinesPerStep: Int,
        maximumSteps: Int
    ) {
        self.maximumOutputBytesPerStep = maximumOutputBytesPerStep
        self.maximumOutputLinesPerStep = maximumOutputLinesPerStep
        self.maximumSteps = maximumSteps
    }
}

/// Result of one read-only command against the exact runtime generation supplied by the caller.
/// Executors must return the scope they actually used; the loader never assumes it remained current.
package struct TmuxReadOnlyCommandExecution: Sendable, Equatable {
    package let scope: TmuxOperationScope
    package let output: [Data]

    package init(scope: TmuxOperationScope, output: [Data]) {
        self.scope = scope
        self.output = output
    }
}

/// Transport-neutral execution boundary shared by Control Mode and guarded one-shot adapters.
package protocol TmuxReadOnlyCommandExecuting: Sendable {
    func execute(
        _ request: TmuxControlRequest,
        scope: TmuxOperationScope,
        timeout: Duration
    ) async throws -> TmuxReadOnlyCommandExecution
}

/// Adapts one already-opened Control Mode generation to the snapshot loader boundary.
package struct TmuxControlClientReadOnlyExecutor: TmuxReadOnlyCommandExecuting {
    private let client: TmuxControlClient
    private let scope: TmuxOperationScope

    package init(client: TmuxControlClient, scope: TmuxOperationScope) {
        self.client = client
        self.scope = scope
    }

    package func execute(
        _ request: TmuxControlRequest,
        scope requestedScope: TmuxOperationScope,
        timeout: Duration
    ) async throws -> TmuxReadOnlyCommandExecution {
        guard request.semantics == .readOnly else {
            throw TmuxSnapshotLoaderError.nonReadOnlyRequest
        }
        guard requestedScope == scope else {
            throw TmuxSnapshotLoaderError.scopeMismatch(
                expected: scope,
                actual: requestedScope
            )
        }
        guard await client.generation == scope.generation else {
            throw TmuxSnapshotLoaderError.staleGeneration
        }

        let result = try await client.execute(request, timeout: timeout)
        guard result.generation == scope.generation,
              await client.generation == scope.generation
        else {
            throw TmuxSnapshotLoaderError.staleGeneration
        }
        return TmuxReadOnlyCommandExecution(scope: scope, output: result.output)
    }
}

/// Executes and assembles an all-or-nothing snapshot. The actor serializes equal scopes while
/// allowing independent servers and newer generations to make progress concurrently.
package actor TmuxSnapshotLoader {
    package typealias NonceFactory = @Sendable () throws -> TmuxInvocationNonce
    package typealias Clock = @Sendable () -> Date

    private struct RuntimeKey: Sendable, Hashable {
        let connectionIdentity: SSHConnectionIdentity
        let profileID: String
        let instanceToken: TmuxServerInstanceToken

        init(_ scope: TmuxOperationScope) {
            connectionIdentity = scope.connectionIdentity
            profileID = scope.profileID
            instanceToken = scope.instanceToken
        }
    }

    private struct ScopeWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct FramedSection {
        let frame: TmuxSnapshotSectionFrame
        let lines: [Data]
    }

    private struct LegacySessionBase {
        let id: TmuxSessionID
    }

    private struct LegacyWindowBase {
        let id: TmuxWindowID
        let isZoomed: String
    }

    private struct LegacyPaneBase {
        let windowID: String
        let id: TmuxPaneID
        let index: String
        let width: String
        let height: String
        let isDead: String
        let isActive: String
    }

    private struct LegacyClientKey: Sendable, Equatable, Hashable {
        let processID: Int32
        let createdAt: Int64?
    }

    private struct LegacyClientBase {
        let key: LegacyClientKey
        let processID: String
        let createdAt: String
        let sessionID: String
        let currentWindowID: String
        let activePaneID: String
        let controlMode: String
    }

    private struct LegacyBaseRecords {
        var identityBeforeNumbers: [String]?
        var socketBefore: String?
        var version: String?
        var sessions: [LegacySessionBase] = []
        var windowLinks: [TmuxDecodedWindowLinkRecord] = []
        var windows: [LegacyWindowBase] = []
        var panes: [LegacyPaneBase] = []
        var clients: [LegacyClientBase] = []
    }

    private struct LegacyTextRecords {
        var sessionNames: [TmuxSessionID: String] = [:]
        var sessionGroups: [TmuxSessionID: String] = [:]
        var windowNames: [TmuxWindowID: String] = [:]
        var windowLayouts: [TmuxWindowID: String] = [:]
        var paneTitles: [TmuxPaneID: String] = [:]
        var paneCommands: [TmuxPaneID: String] = [:]
        var panePaths: [TmuxPaneID: String] = [:]
        var paneAlternateOn: [TmuxPaneID: String] = [:]
        var paneInMode: [TmuxPaneID: String] = [:]
        var paneModes: [TmuxPaneID: String] = [:]
        var paneMouseAnyFlag: [TmuxPaneID: String] = [:]
        var paneHistorySize: [TmuxPaneID: String] = [:]
        var paneHistoryLimit: [TmuxPaneID: String] = [:]
        var clientNames: [LegacyClientKey: String] = [:]
        var clientTTYs: [LegacyClientKey: String] = [:]
        var clientFlags: [LegacyClientKey: String] = [:]
    }

    private let executor: any TmuxReadOnlyCommandExecuting
    private let renderer: TmuxSnapshotQueryRenderer
    private let assembler: TmuxSnapshotAssembler
    private let quotedCodec: TmuxQuotedSnapshotCodec
    private let legacyCodec: TmuxLegacySnapshotCodec
    private let limits: TmuxSnapshotLoaderLimits
    private let nonceFactory: NonceFactory
    private let clock: Clock

    private var activeScopes: Set<TmuxOperationScope> = []
    private var scopeWaiters: [TmuxOperationScope: [ScopeWaiter]] = [:]
    private var latestGenerations: [RuntimeKey: UInt64] = [:]

    package init(
        executor: any TmuxReadOnlyCommandExecuting,
        renderer: TmuxSnapshotQueryRenderer = .init(),
        assembler: TmuxSnapshotAssembler = .init(),
        quotedCodec: TmuxQuotedSnapshotCodec = .init(),
        legacyCodec: TmuxLegacySnapshotCodec = .init(),
        limits: TmuxSnapshotLoaderLimits = .default,
        nonceFactory: @escaping NonceFactory,
        clock: @escaping Clock = { Date() }
    ) {
        self.executor = executor
        self.renderer = renderer
        self.assembler = assembler
        self.quotedCodec = quotedCodec
        self.legacyCodec = legacyCodec
        self.limits = limits
        self.nonceFactory = nonceFactory
        self.clock = clock
    }

    package func load(
        scope: TmuxOperationScope,
        dialect: TmuxProtocolDialect,
        identities: Set<TmuxControlInteractiveIdentity>,
        controlClientID: TmuxClientID?,
        timeout: Duration
    ) async throws -> TmuxServerSnapshot {
        guard timeout > .zero else {
            throw TmuxSnapshotLoaderError.invalidTimeout
        }
        try register(scope)
        try await acquire(scope)
        defer { release(scope) }

        try Task.checkCancellation()
        try ensureCurrent(scope)
        let nonce = try nonceFactory()
        let records: TmuxDecodedSnapshotRecords
        switch dialect.snapshotCodec {
        case .quoted:
            records = try await loadQuoted(scope: scope, nonce: nonce, timeout: timeout)
        case .legacyPerField:
            records = try await loadLegacy(scope: scope, nonce: nonce, timeout: timeout)
        }
        try ensureCurrent(scope)
        return try assembler.assemble(
            records,
            scope: scope,
            identities: identities,
            controlClientID: controlClientID,
            observedAt: clock()
        )
    }

    private func register(_ scope: TmuxOperationScope) throws {
        let key = RuntimeKey(scope)
        if let latest = latestGenerations[key], scope.generation < latest {
            throw TmuxSnapshotLoaderError.staleGeneration
        }
        latestGenerations[key] = scope.generation
    }

    private func ensureCurrent(_ scope: TmuxOperationScope) throws {
        guard latestGenerations[RuntimeKey(scope)] == scope.generation else {
            throw TmuxSnapshotLoaderError.staleGeneration
        }
    }

    private func acquire(_ scope: TmuxOperationScope) async throws {
        if activeScopes.insert(scope).inserted { return }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    scopeWaiters[scope, default: []].append(.init(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, scope: scope) }
        }
    }

    private func cancelWaiter(id: UUID, scope: TmuxOperationScope) {
        guard var waiters = scopeWaiters[scope],
              let index = waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = waiters.remove(at: index)
        scopeWaiters[scope] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ scope: TmuxOperationScope) {
        guard var waiters = scopeWaiters[scope], !waiters.isEmpty else {
            activeScopes.remove(scope)
            scopeWaiters[scope] = nil
            return
        }
        let waiter = waiters.removeFirst()
        scopeWaiters[scope] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume()
    }

    private func loadQuoted(
        scope: TmuxOperationScope,
        nonce: TmuxInvocationNonce,
        timeout: Duration
    ) async throws -> TmuxDecodedSnapshotRecords {
        let plan = try renderer.renderPlan(codec: .quoted, nonce: nonce)
        guard plan.steps.count == 1, let step = plan.steps.first else {
            throw TmuxSnapshotLoaderError.invalidFraming
        }
        let sections = try await execute(step, scope: scope, timeout: timeout)

        let before = try exactlyOne(
            decodeQuoted(.serverIdentityBefore, from: sections),
            section: .serverIdentityBefore
        )
        let after = try exactlyOne(
            decodeQuoted(.serverIdentityAfter, from: sections),
            section: .serverIdentityAfter
        )
        return TmuxDecodedSnapshotRecords(
            identityBefore: identity(before),
            identityAfter: identity(after),
            sessions: try decodeQuoted(.sessions, from: sections).map {
                TmuxDecodedSessionRecord(id: $0[0], name: $0[1], groupName: $0[2])
            },
            windowLinks: try decodeQuoted(.windowLinks, from: sections).map {
                TmuxDecodedWindowLinkRecord(
                    sessionID: $0[0], windowID: $0[1], index: $0[2], isCurrent: $0[3]
                )
            },
            windows: try decodeQuoted(.windows, from: sections).map {
                TmuxDecodedWindowRecord(
                    id: $0[0], name: $0[1], layout: .value($0[2]), isZoomed: $0[3]
                )
            },
            panes: try decodeQuoted(.panes, from: sections).map {
                TmuxDecodedPaneRecord(
                    id: $0[1], windowID: $0[0], index: $0[2], title: .value($0[3]),
                    currentCommand: .value($0[4]), currentPath: .value($0[5]),
                    alternateOn: decodedOptional($0[10]),
                    paneInMode: decodedOptional($0[11]),
                    paneMode: decodedOptional($0[12]),
                    mouseAnyFlag: decodedOptional($0[13]),
                    historySize: decodedOptional($0[14]),
                    historyLimit: decodedOptional($0[15]),
                    width: $0[6], height: $0[7], isDead: $0[8], isActive: $0[9]
                )
            },
            clients: try decodeQuoted(.clients, from: sections).map {
                TmuxDecodedClientRecord(
                    targetName: $0[0], tty: .value($0[1]), processID: $0[2],
                    createdAt: $0[3], sessionID: $0[4], currentWindowID: $0[5],
                    activePaneID: $0[6], flags: .value($0[7]), controlMode: $0[8]
                )
            }
        )
    }

    private func loadLegacy(
        scope: TmuxOperationScope,
        nonce: TmuxInvocationNonce,
        timeout: Duration
    ) async throws -> TmuxDecodedSnapshotRecords {
        let plan = try renderer.renderPlan(codec: .legacyPerField, nonce: nonce)
        let prefixCount = plan.steps.firstIndex { step in
            step.frames.first?.section == .serverIdentityAfter
        } ?? plan.steps.count
        let prefix = Array(plan.steps.prefix(prefixCount))
        let suffix = Array(plan.steps.dropFirst(prefixCount))
        guard !prefix.isEmpty, suffix.count == 2 else {
            throw TmuxSnapshotLoaderError.invalidFraming
        }

        var base = LegacyBaseRecords()
        for step in prefix {
            let sections = try await execute(step, scope: scope, timeout: timeout)
            try decodeLegacyBase(step, sections: sections, into: &base)
        }
        try validateLegacyBase(&base)

        let fields = legacyFields(base)
        guard prefix.count + fields.count + suffix.count <= limits.maximumSteps else {
            throw TmuxSnapshotLoaderError.tooManySteps(maximum: limits.maximumSteps)
        }
        var text = LegacyTextRecords()
        for field in fields {
            let step = try renderer.renderLegacyField(field, nonce: nonce)
            let sections = try await execute(step, scope: scope, timeout: timeout)
            let value = try decodeLegacyField(field, step: step, sections: sections)
            store(value, for: field, in: &text)
        }

        var afterNumbers: [String]?
        var socketAfter: String?
        for step in suffix {
            let sections = try await execute(step, scope: scope, timeout: timeout)
            switch step.decoding {
            case .legacyRecords:
                let rows = try decodeLegacyRecords(step, sections: sections)
                afterNumbers = try exactlyOne(rows, section: .serverIdentityAfter)
            case let .legacyField(field):
                socketAfter = try decodeLegacyField(field, step: step, sections: sections)
            case .quotedSections:
                throw TmuxSnapshotLoaderError.invalidFraming
            }
        }

        guard let beforeNumbers = base.identityBeforeNumbers,
              let socketBefore = base.socketBefore,
              let version = base.version,
              let afterNumbers,
              let socketAfter
        else {
            throw TmuxSnapshotLoaderError.invalidFraming
        }

        return try makeLegacyRecords(
            base: base,
            text: text,
            identityBefore: .init(
                resolvedSocketPath: socketBefore,
                serverPID: beforeNumbers[0],
                serverStartTime: beforeNumbers[1],
                version: .value(version)
            ),
            identityAfter: .init(
                resolvedSocketPath: socketAfter,
                serverPID: afterNumbers[0],
                serverStartTime: afterNumbers[1],
                version: .value(version)
            )
        )
    }

    private func execute(
        _ step: TmuxSnapshotQueryStep,
        scope: TmuxOperationScope,
        timeout: Duration
    ) async throws -> [TmuxSnapshotSection: FramedSection] {
        guard step.request.semantics == .readOnly else {
            throw TmuxSnapshotLoaderError.nonReadOnlyRequest
        }
        try ensureCurrent(scope)
        let execution = try await executor.execute(step.request, scope: scope, timeout: timeout)
        guard execution.scope == scope else {
            throw TmuxSnapshotLoaderError.scopeMismatch(
                expected: scope,
                actual: execution.scope
            )
        }
        try ensureCurrent(scope)
        try validateOutput(execution.output)
        return try split(execution.output, using: step.frames)
    }

    private func validateOutput(_ lines: [Data]) throws {
        var bytes = 0
        for line in lines {
            let (sum, overflow) = bytes.addingReportingOverflow(line.count)
            guard !overflow else {
                throw TmuxSnapshotLoaderError.outputLimitExceeded(
                    maximumBytes: limits.maximumOutputBytesPerStep,
                    maximumLines: limits.maximumOutputLinesPerStep
                )
            }
            bytes = sum
        }
        guard lines.count <= limits.maximumOutputLinesPerStep,
              bytes <= limits.maximumOutputBytesPerStep
        else {
            throw TmuxSnapshotLoaderError.outputLimitExceeded(
                maximumBytes: limits.maximumOutputBytesPerStep,
                maximumLines: limits.maximumOutputLinesPerStep
            )
        }
    }

    private func split(
        _ output: [Data],
        using frames: [TmuxSnapshotSectionFrame]
    ) throws -> [TmuxSnapshotSection: FramedSection] {
        guard !frames.isEmpty else { throw TmuxSnapshotLoaderError.invalidFraming }
        let allMarkers = Set(frames.flatMap {
            [Data($0.beginMarker.utf8), Data($0.endMarker.utf8)]
        })
        var result: [TmuxSnapshotSection: FramedSection] = [:]
        var index = 0
        for frame in frames {
            let begin = Data(frame.beginMarker.utf8)
            let end = Data(frame.endMarker.utf8)
            guard index < output.count, output[index] == begin else {
                throw TmuxSnapshotLoaderError.invalidFraming
            }
            index += 1
            var lines: [Data] = []
            while index < output.count, output[index] != end {
                guard !allMarkers.contains(output[index]) else {
                    throw TmuxSnapshotLoaderError.invalidFraming
                }
                lines.append(output[index])
                index += 1
            }
            guard index < output.count, output[index] == end,
                  result[frame.section] == nil
            else {
                throw TmuxSnapshotLoaderError.invalidFraming
            }
            index += 1
            result[frame.section] = .init(frame: frame, lines: lines)
        }
        guard index == output.count else {
            throw TmuxSnapshotLoaderError.invalidFraming
        }
        return result
    }

    private func decodeQuoted(
        _ section: TmuxSnapshotSection,
        from sections: [TmuxSnapshotSection: FramedSection]
    ) throws -> [[String]] {
        guard let framed = sections[section] else {
            throw TmuxSnapshotLoaderError.missingSection(section)
        }
        return try quotedCodec.decode(
            commandOutputLines: framed.lines,
            expectedFieldCount: framed.frame.expectedFieldCount
        )
    }

    private func exactlyOne(
        _ rows: [[String]],
        section: TmuxSnapshotSection
    ) throws -> [String] {
        guard rows.count == 1 else {
            throw TmuxSnapshotLoaderError.recordCountMismatch(
                section: section,
                expected: 1,
                actual: rows.count
            )
        }
        return rows[0]
    }

    private func identity(_ row: [String]) -> TmuxDecodedServerIdentityRecord {
        TmuxDecodedServerIdentityRecord(
            resolvedSocketPath: row[0],
            serverPID: row[1],
            serverStartTime: row[2],
            version: .value(row[3])
        )
    }

    private func decodeLegacyBase(
        _ step: TmuxSnapshotQueryStep,
        sections: [TmuxSnapshotSection: FramedSection],
        into base: inout LegacyBaseRecords
    ) throws {
        switch step.decoding {
        case .quotedSections:
            throw TmuxSnapshotLoaderError.invalidFraming
        case .legacyRecords:
            let rows = try decodeLegacyRecords(step, sections: sections)
            guard let section = step.frames.first?.section else {
                throw TmuxSnapshotLoaderError.invalidFraming
            }
            switch section {
            case .serverIdentityBefore:
                base.identityBeforeNumbers = try exactlyOne(rows, section: section)
            case .sessions:
                base.sessions = rows.compactMap { row in
                    TmuxSessionID(rawValue: row[0]).map(LegacySessionBase.init(id:))
                }
                guard base.sessions.count == rows.count else {
                    throw TmuxSnapshotAssemblerError.invalidIdentifier(.sessionID)
                }
            case .windowLinks:
                base.windowLinks = rows.map {
                    .init(sessionID: $0[0], windowID: $0[1], index: $0[2], isCurrent: $0[3])
                }
            case .windows:
                base.windows = rows.compactMap { row in
                    TmuxWindowID(rawValue: row[0]).map {
                        LegacyWindowBase(id: $0, isZoomed: row[1])
                    }
                }
                guard base.windows.count == rows.count else {
                    throw TmuxSnapshotAssemblerError.invalidIdentifier(.windowID)
                }
            case .panes:
                base.panes = rows.compactMap { row in
                    TmuxPaneID(rawValue: row[1]).map {
                        LegacyPaneBase(
                            windowID: row[0], id: $0, index: row[2], width: row[3],
                            height: row[4], isDead: row[5], isActive: row[6]
                        )
                    }
                }
                guard base.panes.count == rows.count else {
                    throw TmuxSnapshotAssemblerError.invalidIdentifier(.paneID)
                }
            case .clients:
                base.clients = try rows.map { row in
                    guard let processID = Int32(row[0]), processID > 0 else {
                        throw TmuxSnapshotAssemblerError.invalidNumber(.clientProcessID)
                    }
                    let createdAt: Int64?
                    if row[1].isEmpty {
                        createdAt = nil
                    } else if let value = Int64(row[1]), value > 0 {
                        createdAt = value
                    } else {
                        throw TmuxSnapshotAssemblerError.invalidNumber(.clientCreationTime)
                    }
                    return LegacyClientBase(
                        key: .init(processID: processID, createdAt: createdAt),
                        processID: row[0], createdAt: row[1], sessionID: row[2],
                        currentWindowID: row[3], activePaneID: row[4], controlMode: row[5]
                    )
                }
            case .serverIdentityAfter:
                throw TmuxSnapshotLoaderError.invalidFraming
            }
        case let .legacyField(field):
            let value = try decodeLegacyField(field, step: step, sections: sections)
            switch field {
            case .serverSocketPath(.before): base.socketBefore = value
            case .serverVersion: base.version = value
            default: throw TmuxSnapshotLoaderError.invalidFraming
            }
        }
    }

    private func decodeLegacyRecords(
        _ step: TmuxSnapshotQueryStep,
        sections: [TmuxSnapshotSection: FramedSection]
    ) throws -> [[String]] {
        guard step.frames.count == 1, let frame = step.frames.first,
              let section = sections[frame.section]
        else {
            throw TmuxSnapshotLoaderError.invalidFraming
        }
        return try quotedCodec.decode(
            commandOutputLines: section.lines,
            expectedFieldCount: frame.expectedFieldCount
        )
    }

    private func decodeLegacyField(
        _ field: TmuxLegacySnapshotField,
        step: TmuxSnapshotQueryStep,
        sections: [TmuxSnapshotSection: FramedSection]
    ) throws -> String {
        guard step.frames.count == 1, let frame = step.frames.first,
              let section = sections[frame.section]
        else {
            throw TmuxSnapshotLoaderError.invalidFraming
        }
        do {
            return try legacyCodec.decodeSingleField(commandOutputLines: section.lines)
        } catch TmuxSnapshotCodecError.missingLegacyField {
            throw TmuxSnapshotLoaderError.missingLegacyField(field)
        }
    }

    private func validateLegacyBase(_ base: inout LegacyBaseRecords) throws {
        guard base.identityBeforeNumbers != nil,
              base.socketBefore != nil,
              base.version != nil
        else {
            throw TmuxSnapshotLoaderError.invalidFraming
        }
        guard Set(base.sessions.map(\.id)).count == base.sessions.count else {
            throw TmuxSnapshotLoaderError.duplicateLegacyRecord(.sessions)
        }
        guard Set(base.windows.map(\.id)).count == base.windows.count else {
            throw TmuxSnapshotLoaderError.duplicateLegacyRecord(.windows)
        }
        guard Set(base.panes.map(\.id)).count == base.panes.count else {
            throw TmuxSnapshotLoaderError.duplicateLegacyRecord(.panes)
        }
        guard Set(base.clients.map(\.key)).count == base.clients.count else {
            throw TmuxSnapshotLoaderError.duplicateLegacyRecord(.clients)
        }
    }

    private func legacyFields(_ base: LegacyBaseRecords) -> [TmuxLegacySnapshotField] {
        var fields: [TmuxLegacySnapshotField] = []
        for session in base.sessions.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            fields += [.sessionName(session.id), .sessionGroup(session.id)]
        }
        for window in base.windows.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            fields += [.windowName(window.id), .windowLayout(window.id)]
        }
        for pane in base.panes.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            fields += [
                .paneTitle(pane.id),
                .paneCurrentCommand(pane.id),
                .paneCurrentPath(pane.id),
                .paneAlternateOn(pane.id),
                .paneInMode(pane.id),
                .paneMode(pane.id),
                .paneMouseAnyFlag(pane.id),
                .paneHistorySize(pane.id),
                .paneHistoryLimit(pane.id),
            ]
        }
        for client in base.clients.sorted(by: clientOrder) {
            fields += [
                .clientName(processID: client.key.processID, createdAt: client.key.createdAt),
                .clientTTY(processID: client.key.processID, createdAt: client.key.createdAt),
                .clientFlags(processID: client.key.processID, createdAt: client.key.createdAt),
            ]
        }
        return fields
    }

    private func clientOrder(_ lhs: LegacyClientBase, _ rhs: LegacyClientBase) -> Bool {
        if lhs.key.processID != rhs.key.processID {
            return lhs.key.processID < rhs.key.processID
        }
        return (lhs.key.createdAt ?? 0) < (rhs.key.createdAt ?? 0)
    }

    private func store(
        _ value: String,
        for field: TmuxLegacySnapshotField,
        in text: inout LegacyTextRecords
    ) {
        switch field {
        case let .sessionName(id): text.sessionNames[id] = value
        case let .sessionGroup(id): text.sessionGroups[id] = value
        case let .windowName(id): text.windowNames[id] = value
        case let .windowLayout(id): text.windowLayouts[id] = value
        case let .paneTitle(id): text.paneTitles[id] = value
        case let .paneCurrentCommand(id): text.paneCommands[id] = value
        case let .paneCurrentPath(id): text.panePaths[id] = value
        case let .paneAlternateOn(id): text.paneAlternateOn[id] = value
        case let .paneInMode(id): text.paneInMode[id] = value
        case let .paneMode(id): text.paneModes[id] = value
        case let .paneMouseAnyFlag(id): text.paneMouseAnyFlag[id] = value
        case let .paneHistorySize(id): text.paneHistorySize[id] = value
        case let .paneHistoryLimit(id): text.paneHistoryLimit[id] = value
        case let .clientName(processID, createdAt):
            text.clientNames[.init(processID: processID, createdAt: createdAt)] = value
        case let .clientTTY(processID, createdAt):
            text.clientTTYs[.init(processID: processID, createdAt: createdAt)] = value
        case let .clientFlags(processID, createdAt):
            text.clientFlags[.init(processID: processID, createdAt: createdAt)] = value
        case .serverSocketPath, .serverVersion:
            break
        }
    }

    private func makeLegacyRecords(
        base: LegacyBaseRecords,
        text: LegacyTextRecords,
        identityBefore: TmuxDecodedServerIdentityRecord,
        identityAfter: TmuxDecodedServerIdentityRecord
    ) throws -> TmuxDecodedSnapshotRecords {
        TmuxDecodedSnapshotRecords(
            identityBefore: identityBefore,
            identityAfter: identityAfter,
            sessions: try base.sessions.map { session in
                .init(
                    id: session.id.rawValue,
                    name: try required(text.sessionNames[session.id], field: .sessionName(session.id)),
                    groupName: try required(
                        text.sessionGroups[session.id], field: .sessionGroup(session.id)
                    )
                )
            },
            windowLinks: base.windowLinks,
            windows: try base.windows.map { window in
                .init(
                    id: window.id.rawValue,
                    name: try required(text.windowNames[window.id], field: .windowName(window.id)),
                    layout: .value(try required(
                        text.windowLayouts[window.id], field: .windowLayout(window.id)
                    )),
                    isZoomed: window.isZoomed
                )
            },
            panes: try base.panes.map { pane in
                .init(
                    id: pane.id.rawValue,
                    windowID: pane.windowID,
                    index: pane.index,
                    title: .value(try required(text.paneTitles[pane.id], field: .paneTitle(pane.id))),
                    currentCommand: .value(try required(
                        text.paneCommands[pane.id], field: .paneCurrentCommand(pane.id)
                    )),
                    currentPath: .value(try required(
                        text.panePaths[pane.id], field: .paneCurrentPath(pane.id)
                    )),
                    alternateOn: decodedOptional(try required(
                        text.paneAlternateOn[pane.id], field: .paneAlternateOn(pane.id)
                    )),
                    paneInMode: decodedOptional(try required(
                        text.paneInMode[pane.id], field: .paneInMode(pane.id)
                    )),
                    paneMode: decodedOptional(try required(
                        text.paneModes[pane.id], field: .paneMode(pane.id)
                    )),
                    mouseAnyFlag: decodedOptional(try required(
                        text.paneMouseAnyFlag[pane.id], field: .paneMouseAnyFlag(pane.id)
                    )),
                    historySize: decodedOptional(try required(
                        text.paneHistorySize[pane.id], field: .paneHistorySize(pane.id)
                    )),
                    historyLimit: decodedOptional(try required(
                        text.paneHistoryLimit[pane.id], field: .paneHistoryLimit(pane.id)
                    )),
                    width: pane.width,
                    height: pane.height,
                    isDead: pane.isDead,
                    isActive: pane.isActive
                )
            },
            clients: try base.clients.map { client in
                .init(
                    targetName: try required(
                        text.clientNames[client.key],
                        field: .clientName(
                            processID: client.key.processID,
                            createdAt: client.key.createdAt
                        )
                    ),
                    tty: .value(try required(
                        text.clientTTYs[client.key],
                        field: .clientTTY(
                            processID: client.key.processID,
                            createdAt: client.key.createdAt
                        )
                    )),
                    processID: client.processID,
                    createdAt: client.createdAt,
                    sessionID: client.sessionID,
                    currentWindowID: client.currentWindowID,
                    activePaneID: client.activePaneID,
                    flags: .value(try required(
                        text.clientFlags[client.key],
                        field: .clientFlags(
                            processID: client.key.processID,
                            createdAt: client.key.createdAt
                        )
                    )),
                    controlMode: client.controlMode
                )
            }
        )
    }

    private func required(
        _ value: String?,
        field: TmuxLegacySnapshotField
    ) throws -> String {
        guard let value else {
            throw TmuxSnapshotLoaderError.missingLegacyField(field)
        }
        return value
    }

    private func decodedOptional(_ value: String) -> TmuxDecodedSnapshotText {
        value.isEmpty ? .unavailable : .value(value)
    }
}
