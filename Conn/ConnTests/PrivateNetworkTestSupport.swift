import ConnCrypto
import ConnKit
import ConnPrivateNetwork

/// App unit tests do not need a real control plane, but AppDependencies must still
/// be assembled with the same private-network boundary as production.
final class TestPrivateNetworkProfileRepository: PrivateNetworkProfileRepository, @unchecked Sendable {
    func allProfiles() throws -> [PrivateNetworkProfile] { [] }
    func profile(id: String) throws -> PrivateNetworkProfile? { nil }
    func save(_ profile: PrivateNetworkProfile) throws {}
    func delete(id: String) throws {}
}

func makeTestPrivateNetworkRegistry(
    credentialStore: any CredentialStore
) -> PrivateNetworkRegistry {
    PrivateNetworkRegistry(
        profileRepository: TestPrivateNetworkProfileRepository(),
        credentialStore: credentialStore
    )
}
