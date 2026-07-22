import Foundation

/// 生物识别结果。
public enum BiometricResult: Sendable, Equatable {
    case success
    /// 用户取消或失败。
    case failed
    /// 设备未设置生物识别/密码。
    case unavailable
}

/// 生物识别认证抽象（技术方案 §4.7 应用锁）。
///
/// 协议化以便测试注入。真实实现 `LABiometricAuthenticator` 走 LAContext。
public protocol BiometricAuthenticator: Sendable {
    /// 是否可用（设备已录入 Face ID/Touch ID 或有设备密码）。
    var isAvailable: Bool { get }
    /// 生物识别类型的展示名（"Face ID" / "Touch ID" / "密码"）。
    var displayName: String { get }
    /// 发起认证。`reason` 展示给用户。
    func authenticate(reason: String) async -> BiometricResult
}
