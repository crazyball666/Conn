import Foundation

/// Immutable, provider-owned launch configuration for a persistent terminal backend.
///
/// This is a value carried by an option and attachment descriptor, not a database entity.
/// Shared layers route and version it but never decode `providerPayload`.
public struct PersistentTerminalConfiguration: Sendable, Codable, Equatable, Hashable {
    public let providerID: String
    public let configurationKey: String
    public let payloadVersion: Int
    public let providerPayload: Data

    public init(
        providerID: String,
        configurationKey: String,
        payloadVersion: Int,
        providerPayload: Data
    ) {
        self.providerID = providerID
        self.configurationKey = configurationKey
        self.payloadVersion = payloadVersion
        self.providerPayload = providerPayload
    }
}
