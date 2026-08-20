import ConnKit
import Testing
@testable import ConnMonitor

@Suite("Metrics provider registry")
struct MetricsProviderTests {
    @Test("Linux provider 保留 proc 采集")
    func linuxProvider() {
        let provider = MetricsProviderRegistry.provider(for: .linux)

        #expect(provider?.platform == .linux)
        #expect(provider?.command(includeExtended: true).contains("/proc/stat") == true)
        #expect(provider?.command(includeExtended: true).contains("/proc/meminfo") == true)
    }

    @Test("macOS provider 使用 Darwin 命令而非 proc")
    func darwinProvider() {
        let provider = MetricsProviderRegistry.provider(for: .macOS)
        let command = provider?.command(includeExtended: true)

        #expect(provider?.platform == .macOS)
        #expect(command?.contains("top -l 1") == true)
        #expect(command?.contains("vm_stat") == true)
        #expect(command?.contains("route -n get default") == true)
        #expect(command?.contains("/proc/") == false)
    }

    @Test("尚未支持的平台不返回错误 provider")
    func unsupportedPlatforms() {
        #expect(MetricsProviderRegistry.provider(for: .windows) == nil)
        #expect(MetricsProviderRegistry.provider(for: .unknown) == nil)
    }
}
