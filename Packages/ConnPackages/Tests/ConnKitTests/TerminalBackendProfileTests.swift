import Foundation
import Testing
@testable import ConnKit

@Suite("Terminal backend profile domain model")
struct TerminalBackendProfileTests {
    @Test("defaults follow durable configuration conventions")
    func defaults() {
        let profile = TerminalBackendProfile(
            id: "profile-1",
            hostID: "host-1",
            providerID: "tmux",
            providerConfigurationKey: "default",
            displayName: "Default tmux",
            configurationJSON: #"{"locator":"default"}"#,
            createdAt: 123
        )

        #expect(profile.id == "profile-1")
        #expect(profile.hostID == "host-1")
        #expect(profile.providerID == "tmux")
        #expect(profile.providerConfigurationKey == "default")
        #expect(profile.isEnabled)
        #expect(!profile.isPrimary)
        #expect(profile.configurationVersion == 1)
        #expect(profile.sortOrder == 0)
        #expect(profile.createdAt == 123)
        #expect(profile.updatedAt == 123)
        #expect(!profile.syncDirty)
    }

    @Test("unknown provider configuration round-trips losslessly")
    func unknownConfigurationRoundTrip() throws {
        let original = TerminalBackendProfile(
            id: "future-1",
            hostID: "host-1",
            providerID: "future-provider",
            providerConfigurationKey: "named:ops",
            displayName: "Ops",
            isEnabled: false,
            isPrimary: false,
            configurationVersion: 7,
            configurationJSON: #"{"future":true,"nested":{"value":"原样"}}"#,
            sortOrder: 4,
            createdAt: 100,
            updatedAt: 200,
            syncDirty: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalBackendProfile.self, from: data)

        #expect(decoded == original)
        #expect(decoded.configurationJSON == original.configurationJSON)
    }

    @Test("presentation changes preserve profile identity")
    func presentationChangesPreserveIdentity() {
        var profile = TerminalBackendProfile(
            id: "profile-1",
            hostID: "host-1",
            providerID: "tmux",
            providerConfigurationKey: "named:ops",
            displayName: "Old",
            configurationJSON: "{}"
        )
        let identity = profile.identity

        profile.displayName = "New"
        profile.sortOrder = 8

        #expect(profile.identity == identity)
    }
}
