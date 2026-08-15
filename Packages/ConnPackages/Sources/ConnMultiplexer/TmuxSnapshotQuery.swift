import Foundation

package enum TmuxSnapshotQueryError: Error, Sendable, Equatable {
    case invalidLimits
    case tooManySteps(maximum: Int)
    case tooManySections(maximum: Int)
    case tooManyFields(maximum: Int)
    case markerTooLong(maximumBytes: Int)
    case invalidClientProcessID
    case invalidClientCreationTime
}

package struct TmuxSnapshotQueryLimits: Sendable, Equatable {
    package static let `default` = TmuxSnapshotQueryLimits(
        uncheckedMaximumSteps: 64,
        maximumSectionsPerStep: 16,
        maximumFieldsPerSection: 32,
        maximumMarkerBytes: 512
    )

    package let maximumSteps: Int
    package let maximumSectionsPerStep: Int
    package let maximumFieldsPerSection: Int
    package let maximumMarkerBytes: Int

    package init(
        maximumSteps: Int,
        maximumSectionsPerStep: Int,
        maximumFieldsPerSection: Int,
        maximumMarkerBytes: Int
    ) throws {
        guard maximumSteps > 0,
              maximumSectionsPerStep > 0,
              maximumFieldsPerSection > 0,
              maximumMarkerBytes > 0
        else {
            throw TmuxSnapshotQueryError.invalidLimits
        }
        self.maximumSteps = maximumSteps
        self.maximumSectionsPerStep = maximumSectionsPerStep
        self.maximumFieldsPerSection = maximumFieldsPerSection
        self.maximumMarkerBytes = maximumMarkerBytes
    }

    private init(
        uncheckedMaximumSteps maximumSteps: Int,
        maximumSectionsPerStep: Int,
        maximumFieldsPerSection: Int,
        maximumMarkerBytes: Int
    ) {
        self.maximumSteps = maximumSteps
        self.maximumSectionsPerStep = maximumSectionsPerStep
        self.maximumFieldsPerSection = maximumFieldsPerSection
        self.maximumMarkerBytes = maximumMarkerBytes
    }
}

package enum TmuxSnapshotSection: String, Sendable, Equatable, Hashable, CaseIterable {
    case serverIdentityBefore = "server-identity-before"
    case sessions
    case windowLinks = "window-links"
    case windows
    case panes
    case clients
    case serverIdentityAfter = "server-identity-after"
}

package struct TmuxSnapshotSectionFrame: Sendable, Equatable {
    package let section: TmuxSnapshotSection
    package let expectedFieldCount: Int
    package let beginMarker: String
    package let endMarker: String
}

package enum TmuxSnapshotIdentityBoundary: Sendable, Equatable {
    case before
    case after
}

/// Closed set of legacy text reads. Associated IDs are validated domain types, and clients
/// are addressed through numeric format filters, so no remote string becomes command syntax.
package enum TmuxLegacySnapshotField: Sendable, Equatable, Hashable {
    case serverSocketPath(TmuxSnapshotIdentityBoundary)
    case serverVersion
    case sessionName(TmuxSessionID)
    case sessionGroup(TmuxSessionID)
    case windowName(TmuxWindowID)
    case windowLayout(TmuxWindowID)
    case paneTitle(TmuxPaneID)
    case paneCurrentCommand(TmuxPaneID)
    case paneCurrentPath(TmuxPaneID)
    case paneAlternateOn(TmuxPaneID)
    case paneInMode(TmuxPaneID)
    case paneMode(TmuxPaneID)
    case paneMouseAnyFlag(TmuxPaneID)
    case paneHistorySize(TmuxPaneID)
    case paneHistoryLimit(TmuxPaneID)
    case clientName(processID: Int32, createdAt: Int64?)
    case clientTTY(processID: Int32, createdAt: Int64?)
    case clientFlags(processID: Int32, createdAt: Int64?)
}

package enum TmuxSnapshotQueryStepDecoding: Sendable, Equatable {
    case quotedSections
    case legacyRecords
    case legacyField(TmuxLegacySnapshotField)
}

package struct TmuxSnapshotQueryStep: Sendable, Equatable {
    package let request: TmuxControlRequest
    package let frames: [TmuxSnapshotSectionFrame]
    package let decoding: TmuxSnapshotQueryStepDecoding
}

package struct TmuxSnapshotQueryPlan: Sendable, Equatable {
    package let codec: TmuxSnapshotCodecKind
    package let nonce: TmuxInvocationNonce
    package let steps: [TmuxSnapshotQueryStep]
}

/// Renders only tmux command language for an already-open Control Mode generation.
/// It never includes an executable, server locator, shell command, or user-provided target.
package struct TmuxSnapshotQueryRenderer: Sendable {
    private struct SectionQuery {
        let section: TmuxSnapshotSection
        let expectedFieldCount: Int
        let command: String
    }

    private let limits: TmuxSnapshotQueryLimits

    package init(limits: TmuxSnapshotQueryLimits = .default) {
        self.limits = limits
    }

    package func renderPlan(
        codec: TmuxSnapshotCodecKind,
        nonce: TmuxInvocationNonce
    ) throws -> TmuxSnapshotQueryPlan {
        switch codec {
        case .quoted:
            return try renderQuotedPlan(nonce: nonce)
        case .legacyPerField:
            return try renderLegacyPlan(nonce: nonce)
        }
    }

    package func renderLegacyField(
        _ field: TmuxLegacySnapshotField,
        nonce: TmuxInvocationNonce
    ) throws -> TmuxSnapshotQueryStep {
        let section: TmuxSnapshotSection
        let query: String

        switch field {
        case let .serverSocketPath(boundary):
            section = identitySection(boundary)
            query = display(format: "#{socket_path}")

        case .serverVersion:
            section = .serverIdentityBefore
            query = display(format: "#{version}")

        case let .sessionName(sessionID):
            section = .sessions
            query = listOne(
                command: "list-sessions",
                filter: equality("session_id", sessionID.rawValue),
                format: "#{session_name}"
            )

        case let .sessionGroup(sessionID):
            section = .sessions
            query = listOne(
                command: "list-sessions",
                filter: equality("session_id", sessionID.rawValue),
                format: "#{session_group}"
            )

        case let .windowName(windowID):
            section = .windows
            query = listOne(
                command: "list-windows -a",
                filter: equality("window_id", windowID.rawValue),
                format: "#{window_name}"
            )

        case let .windowLayout(windowID):
            section = .windows
            query = listOne(
                command: "list-windows -a",
                filter: equality("window_id", windowID.rawValue),
                format: "#{window_layout}"
            )

        case let .paneTitle(paneID):
            section = .panes
            query = listOne(
                command: "list-panes -a",
                filter: equality("pane_id", paneID.rawValue),
                format: "#{pane_title}"
            )

        case let .paneCurrentCommand(paneID):
            section = .panes
            query = listOne(
                command: "list-panes -a",
                filter: equality("pane_id", paneID.rawValue),
                format: "#{pane_current_command}"
            )

        case let .paneCurrentPath(paneID):
            section = .panes
            query = listOne(
                command: "list-panes -a",
                filter: equality("pane_id", paneID.rawValue),
                format: "#{pane_current_path}"
            )

        case let .paneAlternateOn(paneID):
            section = .panes
            query = listOne(
                command: "list-panes -a",
                filter: equality("pane_id", paneID.rawValue),
                format: "#{alternate_on}"
            )

        case let .paneInMode(paneID):
            section = .panes
            query = listOne(
                command: "list-panes -a",
                filter: equality("pane_id", paneID.rawValue),
                format: "#{pane_in_mode}"
            )

        case let .paneMode(paneID):
            section = .panes
            query = listOne(
                command: "list-panes -a",
                filter: equality("pane_id", paneID.rawValue),
                format: "#{pane_mode}"
            )

        case let .paneMouseAnyFlag(paneID):
            section = .panes
            query = listOne(
                command: "list-panes -a",
                filter: equality("pane_id", paneID.rawValue),
                format: "#{mouse_any_flag}"
            )

        case let .paneHistorySize(paneID):
            section = .panes
            query = listOne(
                command: "list-panes -a",
                filter: equality("pane_id", paneID.rawValue),
                format: "#{history_size}"
            )

        case let .paneHistoryLimit(paneID):
            section = .panes
            query = listOne(
                command: "list-panes -a",
                filter: equality("pane_id", paneID.rawValue),
                format: "#{history_limit}"
            )

        case let .clientName(processID, createdAt):
            section = .clients
            query = try listClientField(
                processID: processID,
                createdAt: createdAt,
                format: "#{client_name}"
            )

        case let .clientTTY(processID, createdAt):
            section = .clients
            query = try listClientField(
                processID: processID,
                createdAt: createdAt,
                format: "#{client_tty}"
            )

        case let .clientFlags(processID, createdAt):
            section = .clients
            query = try listClientField(
                processID: processID,
                createdAt: createdAt,
                format: "#{client_flags}"
            )
        }

        return try framedStep(
            queries: [.init(section: section, expectedFieldCount: 1, command: query)],
            decoding: .legacyField(field),
            nonce: nonce
        )
    }

    private func renderQuotedPlan(
        nonce: TmuxInvocationNonce
    ) throws -> TmuxSnapshotQueryPlan {
        let queries: [SectionQuery] = [
            .init(
                section: .serverIdentityBefore,
                expectedFieldCount: 4,
                command: display(format: quotedFormat([
                    ("socket_path", true), ("pid", false),
                    ("start_time", false), ("version", true),
                ]))
            ),
            .init(
                section: .sessions,
                expectedFieldCount: 3,
                command: list(
                    command: "list-sessions",
                    format: quotedFormat([
                        ("session_id", false), ("session_name", true),
                        ("session_group", true),
                    ])
                )
            ),
            .init(
                section: .windowLinks,
                expectedFieldCount: 4,
                command: list(
                    command: "list-windows -a",
                    format: quotedFormat([
                        ("session_id", false), ("window_id", false),
                        ("window_index", false), ("window_active", false),
                    ])
                )
            ),
            .init(
                section: .windows,
                expectedFieldCount: 4,
                command: list(
                    command: "list-windows -a",
                    format: quotedFormat([
                        ("window_id", false), ("window_name", true),
                        ("window_layout", true), ("window_zoomed_flag", false),
                    ])
                )
            ),
            .init(
                section: .panes,
                expectedFieldCount: 16,
                command: list(
                    command: "list-panes -a",
                    format: quotedFormat([
                        ("window_id", false), ("pane_id", false),
                        ("pane_index", false), ("pane_title", true),
                        ("pane_current_command", true), ("pane_current_path", true),
                        ("pane_width", false), ("pane_height", false),
                        ("pane_dead", false), ("pane_active", false),
                        ("alternate_on", false), ("pane_in_mode", false),
                        ("pane_mode", true), ("mouse_any_flag", false),
                        ("history_size", false), ("history_limit", false),
                    ])
                )
            ),
            .init(
                section: .clients,
                expectedFieldCount: 9,
                command: list(
                    command: "list-clients",
                    format: quotedFormat([
                        ("client_name", true), ("client_tty", true),
                        ("client_pid", false), ("client_created", false),
                        ("session_id", false), ("window_id", false),
                        ("pane_id", false), ("client_flags", true),
                        ("client_control_mode", false),
                    ])
                )
            ),
            .init(
                section: .serverIdentityAfter,
                expectedFieldCount: 4,
                command: display(format: quotedFormat([
                    ("socket_path", true), ("pid", false),
                    ("start_time", false), ("version", true),
                ]))
            ),
        ]
        let step = try framedStep(
            queries: queries,
            decoding: .quotedSections,
            nonce: nonce
        )
        return try plan(codec: .quoted, nonce: nonce, steps: [step])
    }

    private func renderLegacyPlan(
        nonce: TmuxInvocationNonce
    ) throws -> TmuxSnapshotQueryPlan {
        var steps: [TmuxSnapshotQueryStep] = []
        steps.append(try legacyRecordStep(
            section: .serverIdentityBefore,
            expectedFieldCount: 2,
            command: display(format: safeFormat(["pid", "start_time"])),
            nonce: nonce
        ))
        steps.append(try renderLegacyField(.serverSocketPath(.before), nonce: nonce))
        steps.append(try renderLegacyField(.serverVersion, nonce: nonce))
        steps.append(try legacyRecordStep(
            section: .sessions,
            expectedFieldCount: 1,
            command: list(command: "list-sessions", format: safeFormat(["session_id"])),
            nonce: nonce
        ))
        steps.append(try legacyRecordStep(
            section: .windowLinks,
            expectedFieldCount: 4,
            command: list(
                command: "list-windows -a",
                format: safeFormat(["session_id", "window_id", "window_index", "window_active"])
            ),
            nonce: nonce
        ))
        steps.append(try legacyRecordStep(
            section: .windows,
            expectedFieldCount: 2,
            command: list(
                command: "list-windows -a",
                format: safeFormat(["window_id", "window_zoomed_flag"])
            ),
            nonce: nonce
        ))
        steps.append(try legacyRecordStep(
            section: .panes,
            expectedFieldCount: 7,
            command: list(
                command: "list-panes -a",
                format: safeFormat([
                    "window_id", "pane_id", "pane_index", "pane_width",
                    "pane_height", "pane_dead", "pane_active",
                ])
            ),
            nonce: nonce
        ))
        steps.append(try legacyRecordStep(
            section: .clients,
            expectedFieldCount: 6,
            command: list(
                command: "list-clients",
                format: safeFormat([
                    "client_pid", "client_created", "session_id",
                    "window_id", "pane_id", "client_control_mode",
                ])
            ),
            nonce: nonce
        ))
        steps.append(try legacyRecordStep(
            section: .serverIdentityAfter,
            expectedFieldCount: 2,
            command: display(format: safeFormat(["pid", "start_time"])),
            nonce: nonce
        ))
        steps.append(try renderLegacyField(.serverSocketPath(.after), nonce: nonce))
        return try plan(codec: .legacyPerField, nonce: nonce, steps: steps)
    }

    private func legacyRecordStep(
        section: TmuxSnapshotSection,
        expectedFieldCount: Int,
        command: String,
        nonce: TmuxInvocationNonce
    ) throws -> TmuxSnapshotQueryStep {
        try framedStep(
            queries: [.init(
                section: section,
                expectedFieldCount: expectedFieldCount,
                command: command
            )],
            decoding: .legacyRecords,
            nonce: nonce
        )
    }

    private func framedStep(
        queries: [SectionQuery],
        decoding: TmuxSnapshotQueryStepDecoding,
        nonce: TmuxInvocationNonce
    ) throws -> TmuxSnapshotQueryStep {
        guard queries.count <= limits.maximumSectionsPerStep else {
            throw TmuxSnapshotQueryError.tooManySections(
                maximum: limits.maximumSectionsPerStep
            )
        }

        var frames: [TmuxSnapshotSectionFrame] = []
        var commands: [String] = []
        frames.reserveCapacity(queries.count)
        commands.reserveCapacity(queries.count * 3)

        for query in queries {
            guard query.expectedFieldCount > 0,
                  query.expectedFieldCount <= limits.maximumFieldsPerSection
            else {
                throw TmuxSnapshotQueryError.tooManyFields(
                    maximum: limits.maximumFieldsPerSection
                )
            }
            let frame = try makeFrame(section: query.section, nonce: nonce)
            frames.append(.init(
                section: query.section,
                expectedFieldCount: query.expectedFieldCount,
                beginMarker: frame.begin,
                endMarker: frame.end
            ))
            commands.append(display(literal: frame.begin))
            commands.append(query.command)
            commands.append(display(literal: frame.end))
        }

        let rendered = TmuxRenderedControlCommand(
            value: commands.joined(separator: " ; ")
        )
        return TmuxSnapshotQueryStep(
            request: try TmuxControlRequest(
                renderedCommand: rendered,
                semantics: .readOnly
            ),
            frames: frames,
            decoding: decoding
        )
    }

    private func plan(
        codec: TmuxSnapshotCodecKind,
        nonce: TmuxInvocationNonce,
        steps: [TmuxSnapshotQueryStep]
    ) throws -> TmuxSnapshotQueryPlan {
        guard steps.count <= limits.maximumSteps else {
            throw TmuxSnapshotQueryError.tooManySteps(maximum: limits.maximumSteps)
        }
        return TmuxSnapshotQueryPlan(codec: codec, nonce: nonce, steps: steps)
    }

    private func makeFrame(
        section: TmuxSnapshotSection,
        nonce: TmuxInvocationNonce
    ) throws -> (begin: String, end: String) {
        let prefix = "__CONN_TMUX_SNAPSHOT_\(nonce.value)_\(section.rawValue)"
        let begin = prefix + "_BEGIN__"
        let end = prefix + "_END__"
        guard begin.utf8.count <= limits.maximumMarkerBytes,
              end.utf8.count <= limits.maximumMarkerBytes
        else {
            throw TmuxSnapshotQueryError.markerTooLong(
                maximumBytes: limits.maximumMarkerBytes
            )
        }
        return (begin, end)
    }

    private func list(command: String, format: String) -> String {
        "\(command) -F \(encode(format))"
    }

    private func listOne(command: String, filter: String, format: String) -> String {
        "\(command) -f \(encode(filter)) -F \(encode(format))"
    }

    private func listClientField(
        processID: Int32,
        createdAt: Int64?,
        format: String
    ) throws -> String {
        guard processID > 0 else {
            throw TmuxSnapshotQueryError.invalidClientProcessID
        }
        if let createdAt, createdAt <= 0 {
            throw TmuxSnapshotQueryError.invalidClientCreationTime
        }
        let pidFilter = equality("client_pid", String(processID))
        let filter: String
        if let createdAt {
            filter = "#{&&:\(pidFilter),\(equality("client_created", String(createdAt)))}"
        } else {
            filter = pidFilter
        }
        return listOne(command: "list-clients", filter: filter, format: format)
    }

    private func equality(_ field: String, _ value: String) -> String {
        "#{==:#{\(field)},\(value)}"
    }

    private func display(format: String) -> String {
        "display-message -p \(encode(format))"
    }

    private func display(literal: String) -> String {
        "display-message -p \(encode(literal))"
    }

    private func quotedFormat(_ fields: [(String, Bool)]) -> String {
        fields.map { field, quoted in
            quoted ? "\"#{q:\(field)}\"" : "\"#{\(field)}\""
        }.joined(separator: " ")
    }

    private func safeFormat(_ fields: [String]) -> String {
        fields.map { "\"#{\($0)}\"" }.joined(separator: " ")
    }

    private func identitySection(
        _ boundary: TmuxSnapshotIdentityBoundary
    ) -> TmuxSnapshotSection {
        switch boundary {
        case .before: .serverIdentityBefore
        case .after: .serverIdentityAfter
        }
    }

    /// tmux command-language argument encoding. There is no POSIX shell at this layer.
    private func encode(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
