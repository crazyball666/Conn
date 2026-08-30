import ConnKit
import ConnMultiplexer
import Testing

@Suite("Zellij app integration")
struct ZellijFeatureIntegrationTests {
    @Test("App 默认注册 tmux 与 Zellij 两个持久终端 Provider")
    func defaultRegistryExposesBothProviders() {
        let defaults = PersistentTerminalProviderRegistry.default.registeredDefaults()

        #expect(defaults.map(\.descriptor.id) == ["tmux", "zellij"])
        let zellij = defaults.first { $0.descriptor.id == "zellij" }
        #expect(zellij?.descriptor.displayName == "Zellij")
        #expect(zellij?.descriptor.supportedPlatforms == [.linux, .macOS])
        #expect(zellij?.configuration.payloadVersion == 1)
    }
}
