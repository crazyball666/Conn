import Foundation
import Testing
@testable import ConnMultiplexer

@Suite("Persistent terminal resume repository")
struct PersistentTerminalResumeRepositoryTests {
    @Test("内存仓库按远端 Workspace 去重并保留最新记录")
    func upsertsByProviderWorkspaceIdentity() throws {
        let repository = InMemoryTerminalResumeRepository()
        let first = makeRecord(id: "first", name: "ops", lastConnectedAt: Date(timeIntervalSince1970: 1))
        let replacement = makeRecord(
            id: "replacement",
            name: "production",
            lastConnectedAt: Date(timeIntervalSince1970: 2)
        )

        try repository.save(first)
        try repository.save(replacement)

        let records = try repository.allRecords()
        #expect(records == [replacement])
    }

    @Test("不同 Workspace 分别保存并按最近连接时间排序")
    func storesDistinctWorkspacesInRecentOrder() throws {
        let repository = InMemoryTerminalResumeRepository()
        let older = makeRecord(
            id: "older",
            workspaceID: "$1",
            name: "one",
            lastConnectedAt: Date(timeIntervalSince1970: 1)
        )
        let newer = makeRecord(
            id: "newer",
            workspaceID: "$2",
            name: "two",
            lastConnectedAt: Date(timeIntervalSince1970: 2)
        )

        try repository.save(older)
        try repository.save(newer)

        #expect(try repository.allRecords().map(\.id) == ["newer", "older"])
        try repository.delete(id: newer.id)
        #expect(try repository.allRecords() == [older])
    }

    private func makeRecord(
        id: String,
        workspaceID: String = "$1",
        name: String,
        lastConnectedAt: Date
    ) -> PersistentTerminalResumeRecord {
        let descriptor = PersistentAttachmentDescriptor(
            providerID: "tmux",
            configuration: PersistentTerminalConfiguration(
                providerID: "tmux",
                configurationKey: "default",
                payloadVersion: 1,
                providerPayload: Data()
            ),
            workspace: RemoteWorkspaceRef(
                workspaceID: workspaceID,
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            payloadVersion: 1,
            providerPayload: Data()
        )
        return PersistentTerminalResumeRecord(
            id: id,
            hostID: "host-1",
            hostName: "web",
            hostAddress: "root@example.com",
            descriptor: descriptor,
            automaticAlias: name,
            createdAt: Date(timeIntervalSince1970: 0),
            lastConnectedAt: lastConnectedAt
        )
    }
}
