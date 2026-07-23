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
        try store.record(RunHistoryEntry(hostUUID: "h1", command: "docker restart web", exitCode: 0, ranAt: 1000))
        try store.record(RunHistoryEntry(hostUUID: "h1", command: "docker stop db", exitCode: 0, ranAt: 2000))
        let recent = try store.recent(hostUUID: "h1", limit: 10)
        #expect(recent.map(\.command) == ["docker stop db", "docker restart web"])
    }

    @Test("hostUUID 为 nil 取全部主机")
    func allHosts() throws {
        let store = try makeStore()
        try store.record(RunHistoryEntry(hostUUID: "h1", command: "a", ranAt: 1000))
        try store.record(RunHistoryEntry(hostUUID: "h2", command: "b", ranAt: 2000))
        #expect(try store.recent(hostUUID: nil, limit: 10).count == 2)
        #expect(try store.recent(hostUUID: "h1", limit: 10).count == 1)
    }

    @Test("limit 生效")
    func limitApplies() throws {
        let store = try makeStore()
        for ts in 1 ... 5 {
            try store.record(RunHistoryEntry(hostUUID: "h1", command: "cmd\(ts)", ranAt: Int64(ts * 1000)))
        }
        #expect(try store.recent(hostUUID: "h1", limit: 3).count == 3)
    }

    @Test("失败记录 isSuccess 为 false")
    func failureFlag() throws {
        let store = try makeStore()
        try store.record(RunHistoryEntry(hostUUID: "h1", command: "docker rm x", exitCode: 1, ranAt: 1000))
        #expect(try store.recent(hostUUID: "h1", limit: 1).first?.isSuccess == false)
    }
}
