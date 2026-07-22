import ConnCrypto
import Foundation
import Testing
@testable import Conn

private struct StubAuthenticator: BiometricAuthenticator {
    let isAvailable = true
    let displayName = "Face ID"
    let result: BiometricResult
    func authenticate(reason: String) async -> BiometricResult { result }
}

@MainActor
struct AppLockControllerTests {
    @Test("未启用时始终解锁")
    func disabledAlwaysUnlocked() {
        let lock = AppLockController(authenticator: StubAuthenticator(result: .success), isEnabled: false)
        #expect(lock.state == .unlocked)
    }

    @Test("启用时初始为锁定")
    func enabledStartsLocked() {
        let lock = AppLockController(authenticator: StubAuthenticator(result: .success), isEnabled: true)
        #expect(lock.state == .locked)
    }

    @Test("生物识别成功 → 解锁")
    func successUnlocks() async {
        let lock = AppLockController(authenticator: StubAuthenticator(result: .success), isEnabled: true)
        await lock.unlock()
        #expect(lock.state == .unlocked)
    }

    @Test("生物识别失败 → 保持锁定")
    func failureStaysLocked() async {
        let lock = AppLockController(authenticator: StubAuthenticator(result: .failed), isEnabled: true)
        await lock.unlock()
        #expect(lock.state == .locked)
    }

    @Test("后台盖隐私遮罩，回前台移除")
    func privacyShadeToggles() {
        let lock = AppLockController(authenticator: StubAuthenticator(result: .success), isEnabled: false)
        lock.didEnterBackground()
        #expect(lock.showPrivacyShade)
        lock.willEnterForeground()
        #expect(!lock.showPrivacyShade)
    }

    @Test("后台超过宽限回前台 → 重新上锁")
    func relocksAfterGrace() async {
        var clock = Date(timeIntervalSince1970: 1000)
        let lock = AppLockController(
            authenticator: StubAuthenticator(result: .success),
            isEnabled: true,
            backgroundGrace: 60,
            now: { clock }
        )
        await lock.unlock()
        #expect(lock.state == .unlocked)

        lock.didEnterBackground()
        clock = Date(timeIntervalSince1970: 1000 + 61) // 超过 60s 宽限
        lock.willEnterForeground()
        #expect(lock.state == .locked)
    }

    @Test("后台在宽限内回前台 → 保持解锁")
    func staysUnlockedWithinGrace() async {
        var clock = Date(timeIntervalSince1970: 1000)
        let lock = AppLockController(
            authenticator: StubAuthenticator(result: .success),
            isEnabled: true,
            backgroundGrace: 60,
            now: { clock }
        )
        await lock.unlock()
        lock.didEnterBackground()
        clock = Date(timeIntervalSince1970: 1000 + 30) // 宽限内
        lock.willEnterForeground()
        #expect(lock.state == .unlocked)
    }
}
