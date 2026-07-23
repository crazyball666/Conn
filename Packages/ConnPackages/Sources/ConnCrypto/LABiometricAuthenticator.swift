import Foundation
import LocalAuthentication

/// `LAContext` 支撑的生物识别认证（技术方案 §4.7）。
///
/// 失败回退设备密码（`.deviceOwnerAuthentication` 而非仅 biometrics）。
public struct LABiometricAuthenticator: BiometricAuthenticator {
    public init() {}

    public var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    public var displayName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return L("设备密码")
        }
    }

    public func authenticate(reason: String) async -> BiometricResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success : .failed
        } catch {
            return .failed
        }
    }
}
