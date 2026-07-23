import ConnKit
import Foundation
import Testing
@testable import ConnStore

@Suite("MetricStore 时序读写")
struct MetricStoreTests {
    private func makeStore() throws -> MetricStore {
        try MetricStore(database: AppDatabase.inMemory())
    }

    private func sample(host: String, ts: Int64, cpu: Double = 10) -> MetricSample {
        MetricSample(
            hostUUID: host, ts: ts, cpu: cpu, mem: 20, load1: 0.5,
            diskUsed: 100, diskTotal: 200, netRx: 1000, netTx: 500
        )
    }

    @Test("record 后 latest 取回最新一条")
    func recordAndLatest() throws {
        let store = try makeStore()
        try store.record(sample(host: "h1", ts: 1000, cpu: 11))
        try store.record(sample(host: "h1", ts: 2000, cpu: 22))
        let latest = try store.latest(hostUUID: "h1")
        #expect(latest?.ts == 2000)
        #expect(latest?.cpu == 22)
    }

    @Test("latest 按主机隔离")
    func latestPerHost() throws {
        let store = try makeStore()
        try store.record(sample(host: "h1", ts: 1000))
        try store.record(sample(host: "h2", ts: 3000))
        #expect(try store.latest(hostUUID: "h1")?.ts == 1000)
        #expect(try store.latest(hostUUID: "h2")?.ts == 3000)
        #expect(try store.latest(hostUUID: "missing") == nil)
    }

    @Test("recentSamples 只取 since 之后，按时间升序")
    func recentWindow() throws {
        let store = try makeStore()
        for ts in stride(from: Int64(1000), through: 5000, by: 1000) {
            try store.record(sample(host: "h1", ts: ts))
        }
        let recent = try store.recentSamples(hostUUID: "h1", since: 3000)
        #expect(recent.map(\.ts) == [3000, 4000, 5000])
    }

    @Test("prune 删除早于阈值的样本")
    func prune() throws {
        let store = try makeStore()
        for ts in [Int64(1000), 2000, 3000] {
            try store.record(sample(host: "h1", ts: ts))
        }
        try store.pruneSamples(olderThan: 2500)
        let remaining = try store.recentSamples(hostUUID: "h1", since: 0)
        #expect(remaining.map(\.ts) == [3000])
    }
}
