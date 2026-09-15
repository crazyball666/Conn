import ConnKit
import Foundation
import Testing
@testable import ConnStore

@Suite("私有网络配置存储")
struct PrivateNetworkProfileStoreTests {
    @Test("配置与主机引用可往返")
    func profileAndHostReferenceRoundTrip() throws {
        let database = try AppDatabase.inMemory()
        let profiles = PrivateNetworkProfileStore(database: database)
        let hosts = HostStore(database: database)
        let profile = PrivateNetworkProfile(
            id: "tailnet-prod",
            name: "生产 Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        try profiles.save(profile)
        try hosts.save(Host(
            id: "host-1",
            name: "db",
            address: "100.64.0.10",
            username: "root",
            privateNetworkProfileID: profile.id
        ))

        let loadedProfile = try #require(try profiles.profile(id: profile.id))
        #expect(loadedProfile.id == profile.id)
        #expect(loadedProfile.provider == profile.provider)
        #expect(loadedProfile.controlURL == profile.controlURL)
        #expect(loadedProfile.syncDirty)
        #expect(try hosts.host(id: "host-1")?.privateNetworkProfileID == profile.id)
    }

    @Test("被主机引用的配置不能删除")
    func referencedProfileCannotBeDeleted() throws {
        let database = try AppDatabase.inMemory()
        let profiles = PrivateNetworkProfileStore(database: database)
        let hosts = HostStore(database: database)
        let profile = PrivateNetworkProfile(
            id: "hs",
            name: "Headscale",
            provider: .headscale,
            controlURL: "https://hs.example.com"
        )
        try profiles.save(profile)
        try hosts.save(Host(
            id: "host-1", name: "internal", address: "10.0.0.1", username: "root",
            privateNetworkProfileID: profile.id
        ))

        #expect(throws: PrivateNetworkProfileStoreError.profileInUse(profileID: profile.id)) {
            try profiles.delete(id: profile.id)
        }
    }
}
