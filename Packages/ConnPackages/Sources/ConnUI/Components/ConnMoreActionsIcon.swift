import SwiftUI

/// 列表与卡片内的统一“更多操作”图标。
///
/// 视觉保持紧凑，实际点击区域固定为 44pt；无障碍文案由外层 `Menu` 按业务语言提供。
public struct ConnMoreActionsIcon: View {
    public init() {}

    public var body: some View {
        Image(systemName: "ellipsis.circle")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.connMuted)
            .connHitTarget()
    }
}

#Preview {
    ConnMoreActionsIcon()
        .padding()
        .background(Color.connBg)
}
