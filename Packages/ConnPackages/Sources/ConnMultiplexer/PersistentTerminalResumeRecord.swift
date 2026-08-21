import Foundation

/// Stable provider-neutral identity of one restorable remote workspace.
///
/// The shared layer deliberately uses only routing identifiers. Provider-specific
/// details stay opaque inside `PersistentAttachmentDescriptor`.
public struct PersistentTerminalResumeIdentity: Sendable, Codable, Equatable, Hashable {
    public let hostID: String
    public let providerID: String
    public let configurationKey: String
    public let workspaceID: String

    public init(
        hostID: String,
        providerID: String,
        configurationKey: String,
        workspaceID: String
    ) {
        self.hostID = hostID
        self.providerID = providerID
        self.configurationKey = configurationKey
        self.workspaceID = workspaceID
    }
}

/// A local bookmark for a provider-owned persistent terminal workspace.
///
/// This is runtime restoration metadata, not a host setting or a provider profile.
/// Credentials, terminal output and transient connection state must never be stored here.
public struct PersistentTerminalResumeRecord: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let hostID: String
    public var hostName: String
    public var hostAddress: String
    public let descriptor: PersistentAttachmentDescriptor
    public var automaticAlias: String
    public var alias: String?
    public let createdAt: Date
    public var lastConnectedAt: Date

    public init(
        id: String = UUID().uuidString,
        hostID: String,
        hostName: String,
        hostAddress: String,
        descriptor: PersistentAttachmentDescriptor,
        automaticAlias: String,
        alias: String? = nil,
        createdAt: Date = .now,
        lastConnectedAt: Date = .now
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.hostAddress = hostAddress
        self.descriptor = descriptor
        self.automaticAlias = automaticAlias
        self.alias = Self.cleaned(alias)
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    public var identity: PersistentTerminalResumeIdentity {
        PersistentTerminalResumeIdentity(
            hostID: hostID,
            providerID: descriptor.providerID,
            configurationKey: descriptor.configurationKey,
            workspaceID: descriptor.workspace.workspaceID
        )
    }

    public var providerID: String { descriptor.providerID }
    public var workspaceID: String { descriptor.workspace.workspaceID }
    public var displayName: String { alias ?? automaticAlias }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Persistence boundary for local restoration bookmarks. Implementations may use GRDB,
/// a versioned file, or an in-memory store without changing terminal orchestration.
public protocol PersistentTerminalResumeRepository: Sendable {
    func allRecords() throws -> [PersistentTerminalResumeRecord]
    func save(_ record: PersistentTerminalResumeRecord) throws
    func delete(id: String) throws
    func delete(hostID: String) throws
}

/// Thread-safe ephemeral repository used by previews and tests.
public final class InMemoryTerminalResumeRepository:
    PersistentTerminalResumeRepository,
    @unchecked Sendable {
    private let lock = NSLock()
    private var records: [PersistentTerminalResumeRecord]

    public init(records: [PersistentTerminalResumeRecord] = []) {
        self.records = Self.deduplicated(records)
    }

    public func allRecords() throws -> [PersistentTerminalResumeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    public func save(_ record: PersistentTerminalResumeRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.id == record.id || $0.identity == record.identity }
        records.append(record)
    }

    public func delete(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.id == id }
    }

    public func delete(hostID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.hostID == hostID }
    }

    private static func deduplicated(
        _ records: [PersistentTerminalResumeRecord]
    ) -> [PersistentTerminalResumeRecord] {
        var latest: [PersistentTerminalResumeIdentity: PersistentTerminalResumeRecord] = [:]
        for record in records {
            if let existing = latest[record.identity],
               existing.lastConnectedAt >= record.lastConnectedAt {
                continue
            }
            latest[record.identity] = record
        }
        return Array(latest.values)
    }
}
