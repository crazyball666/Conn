import SwiftUI

/// 可恢复加载失败的统一呈现：错误说明 + 明确的重试动作。
///
/// Feature 只传入已本地化文案和动作，避免各页面重复拼装后在间距、图标和触控热区上漂移。
public struct ConnRetryState: View {
    private let message: String
    private let retryTitle: String
    private let action: () -> Void

    public init(
        _ message: String,
        retryTitle: String,
        action: @escaping () -> Void
    ) {
        self.message = message
        self.retryTitle = retryTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            ConnBanner(
                message,
                systemImage: "exclamationmark.triangle",
                kind: .warn
            )
            Button(action: action) {
                Label(retryTitle, systemImage: "arrow.clockwise")
                    .font(.connBody)
                    .foregroundStyle(.connAccent)
                    .connHitTarget()
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ConnSpacing.md)
    }
}

#Preview {
    ConnRetryState("连接失败，请检查网络后重试", retryTitle: "重试") {}
        .padding(ConnSpacing.page)
        .background(Color.connBg)
}
