import Foundation

/// Storage contract for provider-neutral persistent terminal backend profiles.
public protocol TerminalBackendProfileRepository: Sendable {
    func profiles(hostID: String, providerID: String?) throws -> [TerminalBackendProfile]
    func profile(id: String) throws -> TerminalBackendProfile?
    func save(_ profile: TerminalBackendProfile) throws
    func delete(id: String) throws
    func setPrimary(id: String?, hostID: String, providerID: String) throws
}
