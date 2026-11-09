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

    @Test("错误文本原样保留并去掉不支持的字符")
    func errorTextPreservesContent() {
        let sink = FakeSink()
        let service = AnalyticsService(sink: sink)
        let text = "ssh: connect failed\nline2\tend\u{0000}"

        service.track(.connectionTiming, [.errorText: text])

        #expect(sink.payloads.first?.properties["error_text"] == "ssh: connect failed\nline2\tend")
    }

    @Test("错误文本超过上限时截断")
    func errorTextTruncatesAtLimit() {
        let sink = FakeSink()
        let service = AnalyticsService(sink: sink)

        service.track(.connectionTiming, [.errorText: String(repeating: "错", count: 3_000)])

        let value = sink.payloads.first?.properties["error_text"]
        #expect(value != nil)
        #expect(value!.count <= AnalyticsService.maxErrorTextCharacters)
        #expect(value!.utf8.count <= AnalyticsService.maxErrorTextBytes)
        #expect(value!.count > AnalyticsService.maxPropertyValueLength)
    }

    @Test("地址允许超过普通属性上限")
    func addressAllowsLongerValues() {
        let sink = FakeSink()
        let service = AnalyticsService(sink: sink)
        let address = String(repeating: "a", count: 200) + ".example.com"

        service.track(.connectionTiming, [.targetAddress: address])

        #expect(sink.payloads.first?.properties["target_address"] == address)
    }

    @Test("地址超过地址上限时丢弃")
    func addressOverLimitIsDropped() {
        let sink = FakeSink()
        let service = AnalyticsService(sink: sink)

        service.track(.connectionTiming, [
            .targetAddress: String(repeating: "a", count: AnalyticsService.maxAddressLength + 1),
        ])

        #expect(sink.payloads.first?.properties["target_address"] == nil)
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
