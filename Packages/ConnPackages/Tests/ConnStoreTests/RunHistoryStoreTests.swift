import ConnKit
import Foundation
import Testing
@testable import ConnStore

@Suite("RunHistoryStore 审计读写")
struct RunHistoryStoreTests {
    private func makeStore() throws -> RunHistoryStore {
        try RunHistoryStore(database: AppDatabase.inMemory())
    }

    @Test("record 后按时间降序取回")
    func recordAndRecent() throws {
        let store = try makeStore()
        try store.record(RunHistoryEntry(hostUUID: "h1", script: "docker restart web", exitCode: 0, ranAt: 1000))
        try store.record(RunHistoryEntry(hostUUID: "h1", script: "docker stop db", exitCode: 0, ranAt: 2000))
        let recent = try store.recent(hostUUID: "h1", limit: 10)
        #expect(recent.map(\.script) == ["docker stop db", "docker restart web"])
    }

    @Test("hostUUID 为 nil 取全部主机")
    func allHosts() throws {
        let store = try makeStore()
        try store.record(RunHistoryEntry(hostUUID: "h1", script: "a", ranAt: 1000))
        try store.record(RunHistoryEntry(hostUUID: "h2", script: "b", ranAt: 2000))
        #expect(try store.recent(hostUUID: nil, limit: 10).count == 2)
        #expect(try store.recent(hostUUID: "h1", limit: 10).count == 1)
    }

    @Test("limit 生效")
    func limitApplies() throws {
        let store = try makeStore()
        for ts in 1 ... 5 {
            try store.record(RunHistoryEntry(hostUUID: "h1", script: "cmd\(ts)", ranAt: Int64(ts * 1000)))
        }
        #expect(try store.recent(hostUUID: "h1", limit: 3).count == 3)
    }

    @Test("失败记录 isSuccess 为 false")
    func failureFlag() throws {
        let store = try makeStore()
        try store.record(RunHistoryEntry(hostUUID: "h1", script: "docker rm x", exitCode: 1, ranAt: 1000))
        #expect(try store.recent(hostUUID: "h1", limit: 1).first?.isSuccess == false)
    }

    @Test("pending 审计以相同 UUID 更新为已知结果")
    func pendingBecomesKnownWithSameID() throws {
        let store = try makeStore()
        let pending = RunHistoryEntry(
            id: "pull-1", hostUUID: "h1", script: "Docker 拉取镜像",
            state: .pending, ranAt: 1000
        )
        try store.record(pending)

        try store.update(RunHistoryEntry(
            id: pending.id, hostUUID: pending.hostUUID, script: pending.script,
            exitCode: 0, state: .known, ranAt: pending.ranAt
        ))

        let entry = try #require(store.recent(hostUUID: "h1", limit: 1).first)
        #expect(entry.id == pending.id)
        #expect(entry.state == .known)
        #expect(entry.isSuccess)
    }

    @Test("启动恢复将未完成审计批量标记为未知")
    func recoverPendingMarksOnlyPendingEntriesUnknown() throws {
        let store = try makeStore()
        try store.record(RunHistoryEntry(
            id: "pending", hostUUID: "h1", script: "Docker 拉取镜像", state: .pending, ranAt: 1000
        ))
        try store.record(RunHistoryEntry(
            id: "known", hostUUID: "h1", script: "Docker 拉取镜像",
            exitCode: 0, state: .known, ranAt: 2000
        ))

        try store.recoverPending()

        let entries = try store.recent(hostUUID: "h1", limit: 10)
        let pending = try #require(entries.first { $0.id == "pending" })
        let known = try #require(entries.first { $0.id == "known" })
        #expect(pending.state == .unknown)
        #expect(pending.exitCode == nil)
        #expect(!pending.isSuccess)
        #expect(known.state == .known)
        #expect(known.isSuccess)
    }
}
