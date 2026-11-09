import Foundation

/// 一条已经清洗过的事件，交给具体传输实现（App 层为 Pulse SDK）。
public struct AnalyticsPayload: Equatable, Sendable {
    public let event: String
    public let properties: [String: String]

    public init(event: String, properties: [String: String]) {
        self.event = event
        self.properties = properties
    }
}

/// 传输适配协议。包内不依赖任何三方采集 SDK，便于在 host 上测试。
@MainActor
public protocol AnalyticsSink: AnyObject {
    func capture(_ payload: AnalyticsPayload)
    func flush()
}

/// 事件采集入口：合并公共属性、清洗属性值、屏蔽非法输入。
///
/// 通用属性只允许枚举/分桶/短标识；`errorText` 是显式的诊断例外——原样保留
/// 错误文本（不做凭据脱敏），只去掉不支持的字符并按上限截断。采集策略（含地址、
/// 端口和错误原文）由 App 组装层和隐私文档决定。
@MainActor
public final class AnalyticsService {
    /// 属性值上限。服务端允许更长，但 Conn 的常规属性都是枚举/分桶，
    /// 超过该长度的值基本意味着调用方误传了自由文本。
    public static let maxPropertyValueLength = 64
    /// 错误文本最大字符数和 UTF-8 字节数；两者谁先到就截断。
    public static let maxErrorTextCharacters = 2_000
    public static let maxErrorTextBytes = 4_000
    /// 主机地址（IP/域名）最大长度。
    public static let maxAddressLength = 255

    private let sink: any AnalyticsSink
    private let isEnabled: Bool
    private var commonProperties: [String: String] = [:]

    public init(sink: any AnalyticsSink, isEnabled: Bool = true) {
        self.sink = sink
        self.isEnabled = isEnabled
    }

    /// 更新公共属性；非法值会被移除，避免上一次的旧值继续上报。
    public func setCommonProperties(_ properties: [AnalyticsProperty: String]) {
        guard isEnabled else { return }
        for (key, value) in properties {
            if let cleaned = Self.sanitize(value, for: key) {
                commonProperties[key.rawValue] = cleaned
            } else {
                commonProperties.removeValue(forKey: key.rawValue)
            }
        }
    }

    public func track(_ event: AnalyticsEvent, _ properties: [AnalyticsProperty: String] = [:]) {
        guard isEnabled else { return }
        var merged = commonProperties
        for (key, value) in properties {
            if let cleaned = Self.sanitize(value, for: key) {
                merged[key.rawValue] = cleaned
            }
        }
        sink.capture(AnalyticsPayload(event: event.rawValue, properties: merged))
    }

    public func flush() {
        guard isEnabled else { return }
        sink.flush()
    }

    /// 去空白、拒控制字符、限制长度。非法值返回 nil，由调用方丢弃。
    public static func sanitize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPropertyValueLength else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    /// 按属性选择清洗规则。错误文本和地址是显式的诊断例外，不走 64 字符限制。
    public static func sanitize(_ value: String, for key: AnalyticsProperty) -> String? {
        switch key {
        case .errorText:
            return sanitizeErrorText(value)
        case .targetAddress:
            return sanitizeAddress(value)
        default:
            return sanitize(value)
        }
    }

    /// 错误文本原样保留（不做凭据脱敏），只去掉不支持的字符并按上限截断。
    /// 保留换行、回车和制表符，方便在数据库里直接阅读多行错误。
    public static func sanitizeErrorText(_ value: String) -> String? {
        let allowedScalars = value.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t"
                || !CharacterSet.controlCharacters.contains(scalar)
        }
        var filtered = ""
        filtered.unicodeScalars.append(contentsOf: allowedScalars)
        guard !filtered.isEmpty else { return nil }

        var result = ""
        var byteCount = 0
        for character in filtered {
            let characterBytes = character.utf8.count
            if result.count >= maxErrorTextCharacters
                || byteCount + characterBytes > maxErrorTextBytes {
                break
            }
            result.append(character)
            byteCount += characterBytes
        }
        return result.isEmpty ? nil : result
    }

    /// 地址允许比普通属性长，但仍然拒绝控制字符和超长输入。
    public static func sanitizeAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxAddressLength else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }
}
