import ConnMultiplexer
import Testing

@Suite("tmux protocol negotiation models")
struct TmuxProtocolDialectTests {
    @Test("wire grammar keeps command guards and snapshot quoting together")
    func dialectOwnsOnlyWireGrammar() {
        let legacy = TmuxProtocolDialect(
            commandGuardShape: .twoFields,
            snapshotCodec: .legacyPerField
        )
        let quoted = TmuxProtocolDialect(
            commandGuardShape: .threeFields,
            snapshotCodec: .quoted
        )

        #expect(legacy.commandGuardShape == .twoFields)
        #expect(legacy.snapshotCodec == .legacyPerField)
        #expect(quoted.commandGuardShape == .threeFields)
        #expect(quoted.snapshotCodec == .quoted)
    }

    @Test("supported flags are distinct from flags enabled on this client")
    func supportAndEnabledConfigurationRemainDistinct() {
        let capabilities = TmuxNegotiatedCapabilities(
            supportedClientFlags: [.noOutput, .waitExit, .ignoreSize, .activePane],
            supportsFormatSubscriptions: true
        )
        let configuration = TmuxControlClientConfiguration(
            enabledClientFlags: [.noOutput, .ignoreSize],
            activeSubscriptionNames: ["pane-title", "pane-path"]
        )

        #expect(capabilities.supportedClientFlags.contains(.waitExit))
        #expect(!configuration.enabledClientFlags.contains(.waitExit))
        #expect(capabilities.supportsFormatSubscriptions)
        #expect(configuration.activeSubscriptionNames == ["pane-title", "pane-path"])
    }
}
