import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnRunner

@Suite("SnippetRunner — execution plans")
struct SnippetRunnerBatchTests {
    @Test("single execution sends preparedCommand but audits only auditScript")
    func singleExecutionUsesPreparedCommandAndAuditMetadata() async throws {
        let host = Host(id: "host", name: "Host", address: "10.0.0.1", username: "ops")
        let auditScript = "printf 'user script'"
        let preparedCommand = "trusted-bootstrap && bash -c 'prepared script'"
        let wrappedAgain = "zsh -c '\(preparedCommand.replacingOccurrences(of: "'", with: "'\\''"))'"
        let transport = MockSSHTransport(behavior: .init(commandResponses: [
            preparedCommand: .init(stdout: "exact command"),
            wrappedAgain: .init(stdout: "wrapped again"),
        ]))
        let history = MemoryRunHistoryRepository()
        let runner = makeRunner(transport: transport, history: history)
        let plan = makePlan(
            for: host,
            auditScript: auditScript,
            preparedCommand: preparedCommand,
            interpreter: .zsh
        )

        let outcome = try await runner.runSilently(plan: plan, on: host)

        #expect(outcome.script == auditScript)
        #expect(outcome.interpreter == .zsh)
        #expect(outcome.stdout == "exact command")
        let recorded = history.recordedEntries
        let updates = history.updateAttempts
        #expect(recorded.count == 1)
        #expect(recorded.first?.script == auditScript)
        #expect(recorded.first?.interpreter == .zsh)
        #expect(recorded.first?.state == .pending)
        #expect(updates.count == 1)
        #expect(updates.first?.script == auditScript)
        #expect(updates.first?.interpreter == .zsh)
        #expect(updates.first?.state == .known)
        #expect(recorded.allSatisfy { !$0.script.contains("trusted-bootstrap") })
        #expect(updates.allSatisfy { !$0.script.contains("trusted-bootstrap") })
    }

    @Test("batch requires and uses the matching plan for every host")
    func batchUsesMatchingHostPlans() async {
        let first = Host(id: "first", name: "A", address: "10.0.0.1", username: "ops")
        let second = Host(id: "second", name: "B", address: "10.0.0.2", username: "ops")
        let transport = MockSSHTransport(behavior: .init(commandResponses: [
            "prepared first": .init(stdout: "first output"),
            "prepared second": .init(stdout: "second output"),
        ]))
        let runner = makeRunner(transport: transport)
        let plans = [
            first.id: makePlan(
                for: first,
                auditScript: "audit first",
                preparedCommand: "prepared first",
                interpreter: .bash
            ),
            second.id: makePlan(
                for: second,
                auditScript: "audit second",
                preparedCommand: "prepared second",
                interpreter: .zsh
            ),
        ]

        let results = await runner.runBatchSilently(plansByHostID: plans, on: [second, first])

        #expect(results.map(\.hostName) == ["A", "B"])
        #expect(results.map(\.outcome?.script) == ["audit first", "audit second"])
        #expect(results.map(\.outcome?.interpreter) == [.bash, .zsh])
        #expect(results.map(\.outcome?.stdout) == ["first output", "second output"])
    }

    @Test("missing host plan fails independently and never executes that host")
    func missingHostPlanIsIndependentFailureWithoutExecution() async {
        let missing = Host(id: "missing", name: "A Missing", address: "10.0.0.1", username: "ops")
        let ready = Host(id: "ready", name: "B Ready", address: "10.0.0.2", username: "ops")
        let commands = CommandRecorder()
        let transport = MockSSHTransport(behavior: .init(dynamicResponder: { command, endpoint in
            commands.append(command: command, host: endpoint.host)
            return .init(stdout: endpoint.host)
        }))
        let runner = makeRunner(transport: transport)

        let results = await runner.runBatchSilently(
            plansByHostID: [
                ready.id: makePlan(
                    for: ready,
                    auditScript: "audit ready",
                    preparedCommand: "prepared ready"
                ),
            ],
            on: [ready, missing]
        )

        #expect(results.map(\.hostName) == ["A Missing", "B Ready"])
        #expect(results[0].outcome == nil)
        #expect(results[0].errorMessage == SnippetRunnerError.missingExecutionPlan.localizedDescription)
        #expect(results[1].outcome?.script == "audit ready")
        #expect(results[1].errorMessage == nil)
        #expect(commands.hosts == [ready.address])
        #expect(commands.commands == ["prepared ready"])
    }

    @Test("audit record failure prevents SSH execution")
    func auditRecordFailurePreventsExecution() async {
        let host = Host(id: "blocked", name: "Blocked", address: "10.0.0.3", username: "ops")
        let commands = CommandRecorder()
        let transport = MockSSHTransport(behavior: .init(dynamicResponder: { command, endpoint in
            commands.append(command: command, host: endpoint.host)
            return .init(stdout: "must not run")
        }))
        let history = MemoryRunHistoryRepository(failingRecordHostIDs: [host.id])
        let runner = makeRunner(transport: transport, history: history)

        await #expect(throws: SnippetRunnerError.auditUnavailable) {
            try await runner.runSilently(
                plan: makePlan(for: host, auditScript: "audit", preparedCommand: "prepared"),
                on: host
            )
        }

        #expect(commands.commands.isEmpty)
    }

    @Test("final audit update failure reports auditUpdateFailed and marks history unknown")
    func finalAuditUpdateFailurePreservesSemantics() async {
        let host = Host(id: "host", name: "Host", address: "10.0.0.4", username: "ops")
        let history = MemoryRunHistoryRepository(updateFailuresRemaining: 1)
        let runner = makeRunner(
            transport: MockSSHTransport(behavior: .init(commandResponses: [
                "prepared": .init(stdout: "executed"),
            ])),
            history: history
        )

        await #expect(throws: SnippetRunnerError.auditUpdateFailed) {
            try await runner.runSilently(
                plan: makePlan(
                    for: host,
                    auditScript: "audit only",
                    preparedCommand: "prepared",
                    interpreter: .bash
                ),
                on: host
            )
        }

        #expect(history.updateAttempts.map(\.state) == [.known, .unknown])
        #expect(history.storedEntries.map(\.state) == [.unknown])
        #expect(history.storedEntries.map(\.script) == ["audit only"])
        #expect(history.storedEntries.map(\.interpreter) == [.bash])
    }

    @Test("batch keeps sorted results and isolates per-host audit errors")
    func batchSortsAndKeepsHostErrorsIndependent() async {
        let failing = Host(id: "failing", name: "Alpha", address: "10.0.0.5", username: "ops")
        let succeeding = Host(id: "succeeding", name: "Zulu", address: "10.0.0.6", username: "ops")
        let history = MemoryRunHistoryRepository(failingRecordHostIDs: [failing.id])
        let runner = makeRunner(
            transport: MockSSHTransport(behavior: .init(commandResponses: [
                "prepared success": .init(stdout: "ok"),
            ])),
            history: history
        )
        let plans = [
            failing.id: makePlan(
                for: failing,
                auditScript: "audit failure",
                preparedCommand: "must not execute"
            ),
            succeeding.id: makePlan(
                for: succeeding,
                auditScript: "audit success",
                preparedCommand: "prepared success"
            ),
        ]

        let results = await runner.runBatchSilently(plansByHostID: plans, on: [succeeding, failing])

        #expect(results.map(\.hostName) == ["Alpha", "Zulu"])
        #expect(results[0].outcome == nil)
        #expect(results[0].errorMessage == SnippetRunnerError.auditUnavailable.localizedDescription)
        #expect(results[1].outcome?.stdout == "ok")
        #expect(results[1].errorMessage == nil)
    }

    @Test("prepared plan rejects a different SSH connection identity before audit or execution")
    func planCannotExecuteOnDifferentConnectionIdentity() async {
        let preparedHost = Host(
            id: "same-id",
            name: "Prepared",
            address: "10.0.0.20",
            username: "ops"
        )
        let changedHost = Host(
            id: preparedHost.id,
            name: "Changed",
            address: "10.0.0.21",
            username: "ops"
        )
        let commands = CommandRecorder()
        let history = MemoryRunHistoryRepository()
        let runner = makeRunner(
            transport: MockSSHTransport(behavior: .init(dynamicResponder: { command, endpoint in
                commands.append(command: command, host: endpoint.host)
                return .init(stdout: "must not execute")
            })),
            history: history
        )
        let plan = makePlan(
            for: preparedHost,
            auditScript: "audit",
            preparedCommand: "prepared"
        )

        await #expect(throws: SnippetRunnerError.executionTargetMismatch) {
            try await runner.runSilently(plan: plan, on: changedHost)
        }

        #expect(commands.commands.isEmpty)
        #expect(history.recordedEntries.isEmpty)
        #expect(history.updateAttempts.isEmpty)
    }

    private func makeRunner(
        transport: MockSSHTransport,
        history: MemoryRunHistoryRepository = MemoryRunHistoryRepository()
    ) -> SnippetRunner {
        SnippetRunner(
            connectionManager: ConnectionManager(transport: transport),
            runHistory: history
        )
    }

    private func makePlan(
        for host: ConnKit.Host,
        auditScript: String,
        preparedCommand: String,
        interpreter: ShellInterpreter = .sh
    ) -> SnippetExecutionPlan {
        SnippetExecutionPlan(
            connectionIdentity: SSHConnectionIdentity(host: host),
            auditScript: auditScript,
            preparedCommand: preparedCommand,
            interpreter: interpreter,
            capabilityReport: RemoteCapabilityReport(states: [.scriptExecution: .supported])
        )
    }
}

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(command: String, host: String)] = []

    var commands: [String] {
        lock.withLock { storage.map(\.command) }
    }

    var hosts: [String] {
        lock.withLock { storage.map(\.host) }
    }

    func append(command: String, host: String) {
        lock.withLock { storage.append((command, host)) }
    }
}

private enum MemoryRunHistoryError: Error {
    case injected
}

private final class MemoryRunHistoryRepository: RunHistoryRepository, @unchecked Sendable {
    private let lock = NSLock()
    private let failingRecordHostIDs: Set<String>
    private var remainingUpdateFailures: Int
    private var recordedStorage: [RunHistoryEntry] = []
    private var updateStorage: [RunHistoryEntry] = []
    private var entriesByID: [String: RunHistoryEntry] = [:]

    init(
        failingRecordHostIDs: Set<String> = [],
        updateFailuresRemaining: Int = 0
    ) {
        self.failingRecordHostIDs = failingRecordHostIDs
        remainingUpdateFailures = updateFailuresRemaining
    }

    var recordedEntries: [RunHistoryEntry] {
        lock.withLock { recordedStorage }
    }

    var updateAttempts: [RunHistoryEntry] {
        lock.withLock { updateStorage }
    }

    var storedEntries: [RunHistoryEntry] {
        lock.withLock { Array(entriesByID.values) }
    }

    func record(_ entry: RunHistoryEntry) throws {
        try lock.withLock {
            recordedStorage.append(entry)
            guard !failingRecordHostIDs.contains(entry.hostUUID) else {
                throw MemoryRunHistoryError.injected
            }
            entriesByID[entry.id] = entry
        }
    }

    func update(_ entry: RunHistoryEntry) throws {
        try lock.withLock {
            updateStorage.append(entry)
            if remainingUpdateFailures > 0 {
                remainingUpdateFailures -= 1
                throw MemoryRunHistoryError.injected
            }
            entriesByID[entry.id] = entry
        }
    }

    func recoverPending() throws {}

    func recent(hostUUID: String?, limit: Int) throws -> [RunHistoryEntry] {
        lock.withLock {
            Array(entriesByID.values.filter { hostUUID == nil || $0.hostUUID == hostUUID }.prefix(limit))
        }
    }
}
