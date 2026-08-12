import ConnKit
import GRDB
import Testing
@testable import ConnStore

@Suite("TerminalBackendProfileStore")
struct TerminalBackendProfileStoreTests {
    @Test("按 host 查询稳定排序并可选 provider 过滤")
    func orderedLookupAndProviderFilter() throws {
        let fixture = try makeFixture()
        try fixture.store.save(makeProfile(id: "z", providerID: "tmux", key: "z", sortOrder: 2, createdAt: 30))
        try fixture.store.save(makeProfile(id: "b", providerID: "tmux", key: "b", sortOrder: 1, createdAt: 20))
        try fixture.store.save(makeProfile(id: "a", providerID: "tmux", key: "a", sortOrder: 1, createdAt: 20))
        try fixture.store.save(makeProfile(id: "future", providerID: "future", key: "default", sortOrder: 0))

        #expect(try fixture.store.profiles(hostID: "host-1", providerID: "tmux").map(\.id) == ["a", "b", "z"])
        #expect(try fixture.store.profiles(hostID: "host-1", providerID: nil).map(\.id) == ["future", "a", "b", "z"])
    }

    @Test("未知 provider、配置版本和 opaque JSON 无损往返")
    func unknownConfigurationRoundTripsOpaque() throws {
        let fixture = try makeFixture()
        let profile = makeProfile(
            id: "future-profile",
            providerID: "future-provider",
            key: "opaque:v9",
            configurationVersion: 99,
            configurationJSON: #"{"unknown":[1,"二",{"x":true}]}"#
        )

        try fixture.store.save(profile)
        let loaded = try #require(try fixture.store.profile(id: profile.id))

        #expect(loaded.providerID == profile.providerID)
        #expect(loaded.providerConfigurationKey == profile.providerConfigurationKey)
        #expect(loaded.configurationVersion == 99)
        #expect(loaded.configurationJSON == profile.configurationJSON)
    }

    @Test("save 刷新 updatedAt、置 syncDirty 并保留 createdAt")
    func saveRefreshesSyncMetadata() throws {
        let fixture = try makeFixture()
        let profile = makeProfile(id: "profile", key: "default", createdAt: 1_000)

        try fixture.store.save(profile)
        let loaded = try #require(try fixture.store.profile(id: profile.id))

        #expect(loaded.createdAt == 1_000)
        #expect(loaded.updatedAt > 1_000)
        #expect(loaded.syncDirty)
    }

    @Test("同一 profile ID 不能改变 host、provider 或 configuration identity")
    func identityIsImmutable() throws {
        let fixture = try makeFixture(additionalHostID: "host-2")
        let original = makeProfile(id: "profile", key: "default")
        try fixture.store.save(original)

        let mutations = [
            makeProfile(id: "profile", hostID: "host-2", key: "default"),
            makeProfile(id: "profile", providerID: "future", key: "default"),
            makeProfile(id: "profile", key: "named:changed"),
        ]
        for mutation in mutations {
            #expect(throws: TerminalBackendProfileStoreError.identityMutation(profileID: "profile")) {
                try fixture.store.save(mutation)
            }
        }

        #expect(try fixture.store.profile(id: "profile")?.identity == original.identity)
    }

    @Test("setPrimary 原子切换且拒绝 disabled、scope mismatch 和 missing profile")
    func setPrimaryValidatesAndSwitches() throws {
        let fixture = try makeFixture()
        try fixture.store.save(makeProfile(id: "first", key: "first"))
        try fixture.store.save(makeProfile(id: "second", key: "second"))
        try fixture.store.save(makeProfile(id: "disabled", key: "disabled", isEnabled: false))
        try fixture.store.save(makeProfile(id: "future", providerID: "future", key: "default"))

        try fixture.store.setPrimary(id: "first", hostID: "host-1", providerID: "tmux")
        try fixture.store.setPrimary(id: "second", hostID: "host-1", providerID: "tmux")

        let profiles = try fixture.store.profiles(hostID: "host-1", providerID: "tmux")
        #expect(profiles.filter(\.isPrimary).map(\.id) == ["second"])

        #expect(throws: TerminalBackendProfileStoreError.disabledPrimary(profileID: "disabled")) {
            try fixture.store.setPrimary(id: "disabled", hostID: "host-1", providerID: "tmux")
        }
        #expect(throws: TerminalBackendProfileStoreError.scopeMismatch(
            profileID: "future",
            expectedHostID: "host-1",
            expectedProviderID: "tmux"
        )) {
            try fixture.store.setPrimary(id: "future", hostID: "host-1", providerID: "tmux")
        }
        #expect(throws: TerminalBackendProfileStoreError.profileNotFound("missing")) {
            try fixture.store.setPrimary(id: "missing", hostID: "host-1", providerID: "tmux")
        }
    }

    @Test("禁用和删除 primary 按 sortOrder、createdAt、uuid 稳定补选")
    func disablingAndDeletingPrimaryElectsStableFallback() throws {
        let fixture = try makeFixture()
        try fixture.store.save(makeProfile(id: "current", key: "current", sortOrder: 0, createdAt: 1))
        try fixture.store.save(makeProfile(id: "z", key: "z", sortOrder: 1, createdAt: 10))
        try fixture.store.save(makeProfile(id: "b", key: "b", sortOrder: 1, createdAt: 5))
        try fixture.store.save(makeProfile(id: "a", key: "a", sortOrder: 1, createdAt: 5))
        try fixture.store.setPrimary(id: "current", hostID: "host-1", providerID: "tmux")

        var disabledCurrent = try #require(try fixture.store.profile(id: "current"))
        disabledCurrent.isEnabled = false
        try fixture.store.save(disabledCurrent)

        #expect(try primaryID(in: fixture.store) == "a")
        #expect(try fixture.store.profile(id: "current")?.isPrimary == false)

        try fixture.store.delete(id: "a")
        #expect(try primaryID(in: fixture.store) == "b")
    }

    @Test("没有 enabled fallback 时允许无 primary，nil 可显式清空")
    func noEnabledFallbackLeavesNoPrimary() throws {
        let fixture = try makeFixture()
        try fixture.store.save(makeProfile(id: "only", key: "only"))
        try fixture.store.setPrimary(id: "only", hostID: "host-1", providerID: "tmux")
        try fixture.store.setPrimary(id: nil, hostID: "host-1", providerID: "tmux")
        #expect(try primaryID(in: fixture.store) == nil)

        try fixture.store.setPrimary(id: "only", hostID: "host-1", providerID: "tmux")
        var disabled = try #require(try fixture.store.profile(id: "only"))
        disabled.isEnabled = false
        try fixture.store.save(disabled)
        #expect(try primaryID(in: fixture.store) == nil)
    }

    @Test("primary 切换后的写入失败会回滚整笔事务")
    func failedSaveRollsBackPrimaryMutation() throws {
        let fixture = try makeFixture()
        try fixture.store.save(makeProfile(id: "original", key: "default"))
        try fixture.store.setPrimary(id: "original", hostID: "host-1", providerID: "tmux")

        let duplicateIdentity = makeProfile(
            id: "duplicate",
            key: "default",
            isPrimary: true
        )
        #expect(throws: DatabaseError.self) {
            try fixture.store.save(duplicateIdentity)
        }

        #expect(try primaryID(in: fixture.store) == "original")
        #expect(try fixture.store.profile(id: "duplicate") == nil)
    }

    @Test("删除 host 通过外键级联清理 profile")
    func hostDeletionCascadesProfiles() throws {
        let fixture = try makeFixture()
        try fixture.store.save(makeProfile(id: "profile", key: "default"))

        try HostStore(database: fixture.database).delete(id: "host-1")

        #expect(try fixture.store.profiles(hostID: "host-1", providerID: nil).isEmpty)
    }
}

private struct StoreFixture {
    let store: TerminalBackendProfileStore
    let database: AppDatabase
}

private func makeFixture(additionalHostID: String? = nil) throws -> StoreFixture {
    let database = try AppDatabase.inMemory()
    let hosts = HostStore(database: database)
    try hosts.save(Host(id: "host-1", name: "Primary", address: "one.local", username: "tester"))
    if let additionalHostID {
        try hosts.save(Host(id: additionalHostID, name: "Other", address: "two.local", username: "tester"))
    }
    return StoreFixture(store: TerminalBackendProfileStore(database: database), database: database)
}

private func makeProfile(
    id: String,
    hostID: String = "host-1",
    providerID: String = "tmux",
    key: String,
    isEnabled: Bool = true,
    isPrimary: Bool = false,
    configurationVersion: Int = 1,
    configurationJSON: String = "{}",
    sortOrder: Int = 0,
    createdAt: Int64 = 1
) -> TerminalBackendProfile {
    TerminalBackendProfile(
        id: id,
        hostID: hostID,
        providerID: providerID,
        providerConfigurationKey: key,
        displayName: key,
        isEnabled: isEnabled,
        isPrimary: isPrimary,
        configurationVersion: configurationVersion,
        configurationJSON: configurationJSON,
        sortOrder: sortOrder,
        createdAt: createdAt,
        updatedAt: createdAt
    )
}

private func primaryID(in store: TerminalBackendProfileStore) throws -> String? {
    try store.profiles(hostID: "host-1", providerID: "tmux").first(where: \.isPrimary)?.id
}
