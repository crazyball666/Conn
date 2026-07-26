import ConnUI
import SwiftUI

/// 把内容包在应用锁之后。
///
/// - 锁定时盖全屏解锁页，要求生物识别。
struct AppLockGate<Content: View>: View {
    @State private var lock: AppLockController
    @Environment(\.scenePhase) private var scenePhase
    private let content: Content

    init(lock: AppLockController, @ViewBuilder content: () -> Content) {
        _lock = State(initialValue: lock)
        self.content = content()
    }

    var body: some View {
        content
            .overlay {
                if lock.state != .unlocked {
                    lockScreen
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background, .inactive:
                    lock.didEnterBackground()
                case .active:
                    lock.willEnterForeground()
                    if lock.state == .locked {
                        Task { await lock.unlock() }
                    }
                @unknown default:
                    break
                }
            }
            .task {
                if lock.state == .locked {
                    await lock.unlock()
                }
            }
    }

    private var lockScreen: some View {
        ZStack {
            Color.connBg.ignoresSafeArea()
            VStack(spacing: ConnSpacing.md) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.connAccent)
                Text(L("Conn 已锁定"))
                    .font(.connSectionTitle)
                    .foregroundStyle(.connInk)
                ConnButton(String(format: L("用 %@ 解锁"), lock.biometryName)) {
                    Task { await lock.unlock() }
                }
                .frame(maxWidth: 240)
            }
        }
    }
}
