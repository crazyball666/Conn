import Testing
@testable import ConnAnalytics

@MainActor
private final class FakeSink: AnalyticsSink {
    var payloads: [AnalyticsPayload] = []
    var flushCount = 0

    func capture(_ payload: AnalyticsPayload) {
        payloads.append(payload)
    }

    func flush() {
        flushCount += 1
    }
}

@Suite("Analytics service")
@MainActor
struct AnalyticsServiceTests {
    @Test("合并公共属性与事件属性")
    func mergesCommonAndEventProperties() {
        let sink = FakeSink()
        let service = AnalyticsService(sink: sink)
        service.setCommonProperties([.appBuild: "100", .tier: "free"])

        service.track(.appLaunched, [.firstLaunch: "true"])

        #expect(sink.payloads == [
            AnalyticsPayload(
                event: "app_launched",
                properties: ["app_build": "100", "tier": "free", "first_launch": "true"]
            )
        ])
    }

    @Test("事件属性覆盖同名公共属性")
    func eventPropertiesOverrideCommon() {
        let sink = FakeSink()
        let service = AnalyticsService(sink: sink)
        service.setCommonProperties([.screen: "servers"])

        service.track(.screenViewed, [.screen: "terminal"])

        #expect(sink.payloads.first?.properties["screen"] == "terminal")
    }

    @Test("丢弃控制字符和超长值")
    func dropsUnsafeValues() {
        let sink = FakeSink()
        let service = AnalyticsService(sink: sink)

        service.track(.errorOccurred, [
            .area: "ssh",
            .category: "bad\nvalue",
            .source: String(repeating: "a", count: 65),
        ])

        #expect(sink.payloads == [
            AnalyticsPayload(event: "error_occurred", properties: ["area": "ssh"])
        ])
    }

    @Test("去除首尾空白并丢弃空值")
    func trimsAndDropsEmptyValues() {
        let sink = FakeSink()
        let service = AnalyticsService(sink: sink)

        service.track(.featureGated, [
            .feature: "  file_management  ",
            .source: "   ",
        ])

        #expect(sink.payloads == [
            AnalyticsPayload(event: "feature_gated", properties: ["feature": "file_management"])
        ])
    }

    @Test("禁用时不采集也不刷新")
    func disabledServiceDoesNothing() {
        let sink = FakeSink()
        let service = AnalyticsService(sink: sink, isEnabled: false)

        service.setCommonProperties([.tier: "free"])
        service.track(.appLaunched)
        service.flush()

        #expect(sink.payloads.isEmpty)
        #expect(sink.flushCount == 0)
    }

    @Test("事件名唯一且为 snake_case")
    func eventNamesAreUniqueSnakeCase() {
        let names = AnalyticsEvent.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil)
        }
    }

    @Test("XOR 混淆可往返")
    func xorRoundTrip() {
        let encoded = XORObfuscation.encode("conn-analytics", key: 0x5A)
        #expect(XORObfuscation.decode(encoded, key: 0x5A) == "conn-analytics")
    }

    @Test("XOR 解码拒绝非法 Base64")
    func xorRejectsInvalidBase64() {
        #expect(XORObfuscation.decode("not base64!!!", key: 0x5A) == nil)
    }
}
