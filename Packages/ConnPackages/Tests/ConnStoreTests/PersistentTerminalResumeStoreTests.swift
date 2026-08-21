import ConnKit
import ConnMultiplexer
import Foundation
import GRDB
import Testing
@testable import ConnStore

@Suite("GRDB persistent terminal resume store")
struct PersistentTerminalResumeStoreTests {
    @Test("恢复记录跨仓库实例完整读回")
    func roundTripsDescriptorAndMetadata() throws {
        let database = try AppDatabase.inMemory()
        let host = Host(id: "host-1", name: "web", address: "example.com", username: "root")
        try HostStore(database: database).save(host)
        let record = makeRecord(id: "resume-1", hostID: host.id, workspaceID: "$1", name: "ops")

        try PersistentTerminalResumeStore(database: database).save(record)
        let loaded = try PersistentTerminalResumeStore(database: database).allRecords()

        #expect(loaded == [record])
    }

    @Test("同一远端 Workspace 只保留最新本地入口")
    func upsertsWorkspaceIdentity() throws {
        let database = try AppDatabase.inMemory()
        let host = Host(id: "host-1", name: "web", address: "example.com", username: "root")
        try HostStore(database: database).save(host)
        let store = PersistentTerminalResumeStore(database: database)
        let first = makeRecord(id: "first", hostID: host.id, workspaceID: "$1", name: "ops")
        let replacement = makeRecord(
            id: "replacement",
            hostID: host.id,
            workspaceID: "$1",
            name: "production"
        )

        try store.save(first)
        try store.save(replacement)

        #expect(try store.allRecords() == [replacement])
    }

    @Test("删除主机级联清理恢复记录")
    func deletingHostCascadesRecords() throws {
        let database = try AppDatabase.inMemory()
        let host = Host(id: "host-1", name: "web", address: "example.com", username: "root")
        let hosts = HostStore(database: database)
        let resumes = PersistentTerminalResumeStore(database: database)
        try hosts.save(host)
        try resumes.save(makeRecord(id: "resume-1", hostID: host.id, workspaceID: "$1", name: "ops"))

        try hosts.delete(id: host.id)

        #expect(try resumes.allRecords().isEmpty)
    }

    @Test("单条损坏记录不会阻断其它可恢复终端")
    func discardsCorruptRecordWithoutHidingValidRecords() throws {
        let database = try AppDatabase.inMemory()
        let host = Host(id: "host-1", name: "web", address: "example.com", username: "root")
        try HostStore(database: database).save(host)
        let store = PersistentTerminalResumeStore(database: database)
        let corrupt = makeRecord(id: "corrupt", hostID: host.id, workspaceID: "$1", name: "bad")
        let valid = makeRecord(id: "valid", hostID: host.id, workspaceID: "$2", name: "good")
        try store.save(corrupt)
        try store.save(valid)
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE persistent_terminal_resume_record SET descriptor_json = ? WHERE uuid = ?",
                arguments: [Data([0xFF]), corrupt.id]
            )
        }

        #expect(try store.allRecords() == [valid])
        let remaining = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT uuid FROM persistent_terminal_resume_record")
        }
        #expect(remaining == [valid.id])
    }

    private func makeRecord(
        id: String,
        hostID: String,
        workspaceID: String,
        name: String
    ) -> PersistentTerminalResumeRecord {
        PersistentTerminalResumeRecord(
            id: id,
            hostID: hostID,
            hostName: "web",
            hostAddress: "root@example.com",
            descriptor: PersistentAttachmentDescriptor(
                providerID: "tmux",
                configuration: PersistentTerminalConfiguration(
                    providerID: "tmux",
                    configurationKey: "default",
                    payloadVersion: 1,
                    providerPayload: Data([1, 2])
                ),
                workspace: RemoteWorkspaceRef(
                    workspaceID: workspaceID,
                    instancePayloadVersion: 1,
                    providerInstancePayload: Data([3, 4])
                ),
                payloadVersion: 1,
                providerPayload: Data([5, 6])
            ),
            automaticAlias: name,
            createdAt: Date(timeIntervalSince1970: 1),
            lastConnectedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
