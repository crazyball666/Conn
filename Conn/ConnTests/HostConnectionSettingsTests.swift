import ConnCrypto
import ConnKit
import ConnStore
import Foundation
import Testing
@testable import Conn

@Suite("主机连接设置草稿")
@MainActor
struct HostConnectionSettingsTests {
    private func model(
        database: AppDatabase,
        credentials: InMemoryCredentialStore = InMemoryCredentialStore(),
        host: Host? = nil
    ) -> HostFormViewModel {
        HostFormViewModel(
            draft: host.map(HostDraft.init(from:)) ?? HostDraft(address: "target.example.com", username: "fixture"),
            editingHostID: host?.id,
            hostStore: HostStore(database: database),
            credentialStore: credentials,
            groupStore: HostGroupStore(database: database),
            keyStore: SSHKeyStore(database: database),
            privateNetworkProfileStore: PrivateNetworkProfileStore(database: database)
        )
    }

    @Test("切换方式保留代理草稿，但只保存当前方式")
    func preservesInactiveProxyWithoutPersistingIt() throws {
        let database = try AppDatabase.inMemory()
        let credentials = InMemoryCredentialStore()
        let vm = model(database: database, credentials: credentials)
        vm.selectNetworkConnectionMode(.proxy)
        vm.draft.proxyConfiguration?.host = "proxy.example.com"
        vm.draft.proxyConfiguration?.authentication = .password
        vm.draft.proxyConfiguration?.username = "fixture"
        vm.proxyPassword = "fixture-secret"
        let proxy = vm.draft.proxyConfiguration
        vm.selectNetworkConnectionMode(.direct)
        #expect(vm.draft.proxyConfiguration == nil)
        #expect(vm.currentProxyPassword == nil)
        vm.selectNetworkConnectionMode(.proxy)
        #expect(vm.draft.proxyConfiguration == proxy)
        #expect(vm.proxyPassword == "fixture-secret")
        vm.selectNetworkConnectionMode(.direct)
        let saved = try #require(vm.save())
        #expect(saved.host.proxyConfiguration == nil)
        #expect(try credentials.proxyPassword(forHost: saved.host.id) == nil)
    }

    @Test("选择私有网络但未选配置，不能测试或静默保存为直连")
    func requiresPrivateNetworkSelection() throws {
        let database = try AppDatabase.inMemory()
        let vm = model(database: database)
        vm.selectNetworkConnectionMode(.privateNetwork)
        #expect(!vm.canTestConnection)
        #expect(vm.save() == nil)
        #expect(vm.fieldErrors[.privateNetwork] != nil)
        #expect(try HostStore(database: database).allHosts().isEmpty)
        vm.selectNetworkConnectionMode(.direct)
        #expect(vm.canTestConnection)
        #expect(vm.fieldErrors[.privateNetwork] == nil)
    }

    @Test("已有私有网络切换到代理再返回会恢复选择")
    func restoresExistingPrivateNetwork() throws {
        let database = try AppDatabase.inMemory()
        let profile = PrivateNetworkProfile(name: "Fixture", provider: .headscale, controlURL: "https://control.example.com")
        try PrivateNetworkProfileStore(database: database).save(profile)
        var host = Host(name: "Fixture", address: "target.example.com", username: "fixture", authKind: .password)
        host.privateNetworkProfileID = profile.id
        try HostStore(database: database).save(host)
        let vm = model(database: database, host: host)
        #expect(vm.networkConnectionMode == .privateNetwork)
        vm.selectNetworkConnectionMode(.proxy)
        #expect(vm.draft.privateNetworkProfileID == nil)
        vm.selectNetworkConnectionMode(.privateNetwork)
        #expect(vm.draft.privateNetworkProfileID == profile.id)
        #expect(vm.draft.proxyConfiguration == nil)
        #expect(try #require(vm.save()).host.privateNetworkProfileID == profile.id)
    }

    @Test("刷新私有网络列表不覆盖未保存的密码")
    func refreshingProfilesPreservesCredentialEdits() throws {
        let database = try AppDatabase.inMemory()
        let credentials = InMemoryCredentialStore()
        let host = Host(name: "Fixture", address: "target.example.com", username: "fixture")
        try HostStore(database: database).save(host)
        try credentials.setPassword("old-password", forHost: host.id)
        let vm = model(database: database, credentials: credentials, host: host)
        vm.password = "edited-password"
        vm.proxyPassword = "edited-proxy-password"
        let profile = PrivateNetworkProfile(name: "Fixture", provider: .tailscale)
        try PrivateNetworkProfileStore(database: database).save(profile)
        vm.reloadPrivateNetworkProfiles()
        #expect(vm.availablePrivateNetworkProfiles.map(\.id) == [profile.id])
        #expect(vm.password == "edited-password")
        #expect(vm.proxyPassword == "edited-proxy-password")
    }

    @Test("清空已有主机的私有网络选择仍留在私有网络方式")
    func clearingExistingProfileDoesNotSelectDirect() throws {
        let database = try AppDatabase.inMemory()
        let profile = PrivateNetworkProfile(name: "Fixture", provider: .tailscale)
        try PrivateNetworkProfileStore(database: database).save(profile)
        var host = Host(name: "Fixture", address: "target.example.com", username: "fixture", authKind: .password)
        host.privateNetworkProfileID = profile.id
        try HostStore(database: database).save(host)
        let vm = model(database: database, host: host)
        vm.draft.privateNetworkProfileID = nil
        #expect(vm.networkConnectionMode == .privateNetwork)
        #expect(!vm.canTestConnection)
        #expect(vm.save() == nil)
        #expect(vm.fieldErrors[.privateNetwork] != nil)
        #expect(try HostStore(database: database).host(id: host.id)?.privateNetworkProfileID == profile.id)
    }

    @Test("切换方式不会恢复已经清空的私有网络选择")
    func clearedProfileRemainsClearedAfterModeRoundTrip() throws {
        let database = try AppDatabase.inMemory()
        let vm = model(database: database)
        vm.selectNetworkConnectionMode(.privateNetwork)
        vm.draft.privateNetworkProfileID = "fixture-profile"
        vm.selectNetworkConnectionMode(.direct)
        vm.selectNetworkConnectionMode(.privateNetwork)
        vm.draft.privateNetworkProfileID = nil
        vm.selectNetworkConnectionMode(.direct)
        vm.selectNetworkConnectionMode(.privateNetwork)
        #expect(vm.draft.privateNetworkProfileID == nil)
        #expect(!vm.canTestConnection)
    }

    @Test("可用跳板机不会自动加入链，且顺序原样保存")
    func jumpChainRequiresExplicitSelection() throws {
        let database = try AppDatabase.inMemory()
        let hosts = (1...2).map { Host(name: "Jump \($0)", address: "jump\($0).example.com", username: "fixture") }
        for host in hosts { try HostStore(database: database).save(host) }
        let vm = model(database: database)
        #expect(vm.draft.jumpChain.isEmpty)
        vm.draft.jumpChain = hosts.reversed().map(\.id)
        let saved = try #require(vm.save())
        #expect(saved.host.jumpChain == hosts.reversed().map(\.id))
        vm.draft.jumpChain.append("missing-host")
        #expect(vm.save() == nil)
        #expect(vm.fieldErrors[.jumpChain] != nil)
    }
}
