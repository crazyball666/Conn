@testable import ConnMultiplexer
import Foundation
import Testing

@Suite("tmux snapshot query rendering")
struct TmuxSnapshotQueryTests {
    @Test("quoted plan frames one coherent request containing the complete normalized graph")
    func rendersQuotedPlan() throws {
        let nonce = try TmuxInvocationNonce("snapshot-7")
        let plan = try TmuxSnapshotQueryRenderer().renderPlan(
            codec: .quoted,
            nonce: nonce
        )

        #expect(plan.codec == .quoted)
        #expect(plan.nonce == nonce)
        #expect(plan.steps.count == 1)
        let step = try #require(plan.steps.first)
        #expect(step.request.semantics == .readOnly)
        #expect(step.decoding == .quotedSections)
        #expect(step.frames.map(\.section) == TmuxSnapshotSection.allCases)
        #expect(step.frames.map(\.expectedFieldCount) == [4, 3, 4, 4, 16, 9, 4])

        let command = try commandString(step.request)
        #expect(!command.contains("\n"))
        #expect(command.contains("display-message -p '\"#{q:socket_path}\" \"#{pid}\" \"#{start_time}\" \"#{q:version}\"'"))
        #expect(command.contains("list-sessions -F '\"#{session_id}\" \"#{q:session_name}\" \"#{q:session_group}\"'"))
        #expect(command.contains("list-windows -a -F '\"#{session_id}\" \"#{window_id}\" \"#{window_index}\" \"#{window_active}\"'"))
        #expect(command.contains("list-windows -a -F '\"#{window_id}\" \"#{q:window_name}\" \"#{q:window_layout}\" \"#{window_zoomed_flag}\"'"))
        #expect(command.contains("list-panes -a -F '\"#{window_id}\" \"#{pane_id}\" \"#{pane_index}\" \"#{q:pane_title}\" \"#{q:pane_current_command}\" \"#{q:pane_current_path}\" \"#{pane_width}\" \"#{pane_height}\" \"#{pane_dead}\" \"#{pane_active}\" \"#{alternate_on}\" \"#{pane_in_mode}\" \"#{q:pane_mode}\" \"#{mouse_any_flag}\" \"#{history_size}\" \"#{history_limit}\"'"))
        #expect(command.contains("list-clients -F '\"#{q:client_name}\" \"#{q:client_tty}\" \"#{client_pid}\" \"#{client_created}\" \"#{session_id}\" \"#{window_id}\" \"#{pane_id}\" \"#{q:client_flags}\" \"#{client_control_mode}\"'"))

        let typedFields = [
            "session_id", "window_id", "window_index", "window_active",
            "window_zoomed_flag", "pane_id", "pane_index", "pane_width",
            "pane_height", "pane_dead", "pane_active", "alternate_on",
            "pane_in_mode", "mouse_any_flag", "history_size", "history_limit", "client_pid",
            "client_created", "client_control_mode", "pid", "start_time",
        ]
        for field in typedFields {
            #expect(!command.contains("#{q:\(field)}"))
        }

        for frame in step.frames {
            #expect(occurrences(of: frame.beginMarker, in: command) == 1)
            #expect(occurrences(of: frame.endMarker, in: command) == 1)
            #expect(frame.beginMarker.contains(nonce.value))
            #expect(frame.beginMarker.contains(frame.section.rawValue))
        }
    }

    @Test("legacy plan keeps bulk rows typed and reads every untrusted value independently")
    func rendersLegacyPlanAndFields() throws {
        let renderer = TmuxSnapshotQueryRenderer()
        let nonce = try TmuxInvocationNonce("legacy_4")
        let plan = try renderer.renderPlan(codec: .legacyPerField, nonce: nonce)

        #expect(plan.codec == .legacyPerField)
        #expect(plan.steps.count == 10)
        #expect(plan.steps.allSatisfy { $0.request.semantics == .readOnly })

        let recordCommands = try plan.steps.compactMap { step -> String? in
            guard step.decoding == .legacyRecords else { return nil }
            return try commandString(step.request)
        }
        #expect(recordCommands.count == 7)
        let combinedRecords = recordCommands.joined(separator: " ")
        for untrustedField in [
            "session_name", "session_group", "window_name", "window_layout",
            "pane_title", "pane_current_command", "pane_current_path",
            "pane_mode",
            "client_name", "client_tty", "client_flags", "socket_path", "version",
        ] {
            #expect(!combinedRecords.contains("#{\(untrustedField)}"))
            #expect(!combinedRecords.contains("#{q:\(untrustedField)}"))
        }
        #expect(!combinedRecords.contains("#{q:"))

        let session = try #require(TmuxSessionID(rawValue: "$1"))
        let window = try #require(TmuxWindowID(rawValue: "@2"))
        let pane = try #require(TmuxPaneID(rawValue: "%3"))
        let fields: [(TmuxLegacySnapshotField, String)] = [
            (.sessionName(session), "-F '#{session_name}'"),
            (.sessionGroup(session), "-F '#{session_group}'"),
            (.windowName(window), "-F '#{window_name}'"),
            (.windowLayout(window), "-F '#{window_layout}'"),
            (.paneTitle(pane), "-F '#{pane_title}'"),
            (.paneCurrentCommand(pane), "-F '#{pane_current_command}'"),
            (.paneCurrentPath(pane), "-F '#{pane_current_path}'"),
            (.paneAlternateOn(pane), "-F '#{alternate_on}'"),
            (.paneInMode(pane), "-F '#{pane_in_mode}'"),
            (.paneMode(pane), "-F '#{pane_mode}'"),
            (.paneMouseAnyFlag(pane), "-F '#{mouse_any_flag}'"),
            (.paneHistorySize(pane), "-F '#{history_size}'"),
            (.paneHistoryLimit(pane), "-F '#{history_limit}'"),
            (.clientName(processID: 321, createdAt: 654), "-F '#{client_name}'"),
            (.clientTTY(processID: 321, createdAt: 654), "-F '#{client_tty}'"),
            (.clientFlags(processID: 321, createdAt: 654), "-F '#{client_flags}'"),
        ]

        for (field, expectedOutput) in fields {
            let step = try renderer.renderLegacyField(field, nonce: nonce)
            #expect(step.decoding == .legacyField(field))
            #expect(step.frames.count == 1)
            #expect(step.frames[0].expectedFieldCount == 1)
            let command = try commandString(step.request)
            #expect(command.contains(expectedOutput))
            #expect(!command.contains("#{q:"))
        }

        #expect(throws: TmuxSnapshotQueryError.invalidClientProcessID) {
            try renderer.renderLegacyField(
                .clientName(processID: 0, createdAt: nil),
                nonce: nonce
            )
        }
        #expect(throws: TmuxSnapshotQueryError.invalidClientCreationTime) {
            try renderer.renderLegacyField(
                .clientName(processID: 321, createdAt: 0),
                nonce: nonce
            )
        }

        let beforeSocket = try #require(plan.steps.first {
            $0.decoding == .legacyField(.serverSocketPath(.before))
        })
        let afterSocket = try #require(plan.steps.first {
            $0.decoding == .legacyField(.serverSocketPath(.after))
        })
        #expect(try commandString(beforeSocket.request).contains("display-message -p '#{socket_path}'"))
        #expect(try commandString(afterSocket.request).contains("display-message -p '#{socket_path}'"))
        #expect(plan.steps.last?.frames.first?.section == .serverIdentityAfter)
    }

    @Test("plan construction bounds steps, sections, fields and frame markers")
    func boundsPlanShape() throws {
        let nonce = try TmuxInvocationNonce(String(repeating: "n", count: 128))

        #expect(throws: TmuxSnapshotQueryError.tooManySections(maximum: 6)) {
            let limits = try TmuxSnapshotQueryLimits(
                maximumSteps: 16,
                maximumSectionsPerStep: 6,
                maximumFieldsPerSection: 32,
                maximumMarkerBytes: 512
            )
            _ = try TmuxSnapshotQueryRenderer(limits: limits).renderPlan(
                codec: .quoted,
                nonce: nonce
            )
        }
        #expect(throws: TmuxSnapshotQueryError.tooManySteps(maximum: 9)) {
            let limits = try TmuxSnapshotQueryLimits(
                maximumSteps: 9,
                maximumSectionsPerStep: 16,
                maximumFieldsPerSection: 32,
                maximumMarkerBytes: 512
            )
            _ = try TmuxSnapshotQueryRenderer(limits: limits).renderPlan(
                codec: .legacyPerField,
                nonce: nonce
            )
        }
        #expect(throws: TmuxSnapshotQueryError.tooManyFields(maximum: 8)) {
            let limits = try TmuxSnapshotQueryLimits(
                maximumSteps: 16,
                maximumSectionsPerStep: 16,
                maximumFieldsPerSection: 8,
                maximumMarkerBytes: 512
            )
            _ = try TmuxSnapshotQueryRenderer(limits: limits).renderPlan(
                codec: .quoted,
                nonce: nonce
            )
        }
        #expect(throws: TmuxSnapshotQueryError.markerTooLong(maximumBytes: 32)) {
            let limits = try TmuxSnapshotQueryLimits(
                maximumSteps: 16,
                maximumSectionsPerStep: 16,
                maximumFieldsPerSection: 32,
                maximumMarkerBytes: 32
            )
            _ = try TmuxSnapshotQueryRenderer(limits: limits).renderPlan(
                codec: .quoted,
                nonce: nonce
            )
        }
    }
}

private func commandString(_ request: TmuxControlRequest) throws -> String {
    let newline = UInt8(ascii: "\n")
    #expect(request.wireData.last == newline)
    return try #require(String(data: request.wireData.dropLast(), encoding: .utf8))
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return haystack.components(separatedBy: needle).count - 1
}
