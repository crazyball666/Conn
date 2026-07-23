import ConnCrypto
import Foundation
import Observation

/// 应用锁 + 隐私遮罩状态机（技术方案 §4.7）。
///
/// - 进 App / 从后台超时回前台 → 要求生物识别。
/// - 切到后台（App 切换器）→ 盖隐私遮罩，隐藏敏感内容。
/// 开关默认由设置控制（Phase 5 先默认关，设置项在设置页接入）。
@Observable
@MainActor
final class AppLockController {
    enum State {
        case unlocked
        case locked
        case authenticating
    }

    private(set) var state: State
    /// App 切换器隐私遮罩是否显示（后台时盖住内容）。
    private(set) var showPrivacyShade = false

    /// 是否启用应用锁。关闭时永远 unlocked。
    var isEnabled: Bool {
        didSet {
            if !isEnabled {
                state = .unlocked
            }
        }
    }

    /// 回前台重新上锁的宽限（技术方案 §4.7：后台超 60s 回前台重锁）。
    private let backgroundGrace: TimeInterval
    private var backgroundedAt: Date?
    private let authenticator: any BiometricAuthenticator
    private let now: () -> Date

    init(
        authenticator: any BiometricAuthenticator,
        isEnabled: Bool = false,
        backgroundGrace: TimeInterval = 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.authenticator = authenticator
        self.isEnabled = isEnabled
        self.backgroundGrace = backgroundGrace
        self.now = now
        state = isEnabled ? .locked : .unlocked
    }

    var biometryName: String { authenticator.displayName }

    /// 发起解锁认证。
    func unlock() async {
        guard isEnabled, state != .unlocked else { return }
        state = .authenticating
        let result = await authenticator.authenticate(reason: L("解锁 Conn"))
        state = (result == .success || result == .unavailable) ? .unlocked : .locked
    }

    /// 场景进入后台。
    func didEnterBackground() {
        showPrivacyShade = true
        backgroundedAt = now()
    }

    /// 场景回到前台。超过宽限则重新上锁。
    func willEnterForeground() {
        showPrivacyShade = false
        guard isEnabled else { return }
        if let backgroundedAt, now().timeIntervalSince(backgroundedAt) > backgroundGrace {
            state = .locked
        }
        backgroundedAt = nil
    }
}
