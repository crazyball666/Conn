import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnRunner

@Suite("SnippetRunner — 每主机脚本上下文")
struct SnippetRunnerBatchTests {
    @Test("批量执行可为不同主机使用不同的已准备脚本")
    func batchUsesPerHostScripts() async throws {
        let first = Host(id: "first", name: "A", address: "10.0.0.1", username: "ops")
        let second = Host(id: "second", name: "B", address: "10.0.0.2", username: "ops")
        let transport = MockSSHTransport(behavior: .init(commandResponses: [
            "echo default": .init(stdout: "default"),
            "echo second": .init(stdout: "second"),
        ]))
        let runner = SnippetRunner(
            connectionManager: ConnectionManager(transport: transport),
            runHistory: MemoryRunHistoryRepository()
        )

        let results = await runner.runBatchSilently(
            script: "echo default",
            scriptsByHostID: [second.id: "echo second"],
            on: [first, second]
        )

        #expect(results.map(\.outcome?.script) == ["echo default", "echo second"])
        #expect(results.map(\.outcome?.stdout) == ["default", "second"])
    }
}

private final class MemoryRunHistoryRepository: RunHistoryRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: RunHistoryEntry] = [:]

    func record(_ entry: RunHistoryEntry) throws {
        lock.withLock { entries[entry.id] = entry }
    }

    func update(_ entry: RunHistoryEntry) throws {
        lock.withLock { entries[entry.id] = entry }
    }

    func recoverPending() throws {}

    func recent(hostUUID: String?, limit: Int) throws -> [RunHistoryEntry] {
        lock.withLock {
            Array(entries.values.filter { hostUUID == nil || $0.hostUUID == hostUUID }.prefix(limit))
        }
    }
}
