import SwiftUI

/// 分组筛选条：`全部` + 各分组 chip，单选，横向滚动。
///
/// 分组 chip 长按弹出重命名 / 删除；`leading` 里的前置 chip
/// （如命令页的「常用」）不是分组，不带上下文菜单。
public struct GroupFilterBar: View {
    /// 一个可点选的 chip。
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    private let allTitle: String
    private let leading: [Item]
    private let groups: [Item]
    @Binding private var selection: String?
    private let onRename: (Item) -> Void
    private let onDelete: (Item) -> Void

    /// - Parameters:
    ///   - allTitle: 「全部」chip 的标题。
    ///   - leading: 插在「全部」之前的非分组 chip，可为空。
    ///   - groups: 分组 chip。
    ///   - selection: 当前选中项 id；`nil` 表示「全部」。
    public init(
        allTitle: String,
        leading: [Item] = [],
        groups: [Item],
        selection: Binding<String?>,
        onRename: @escaping (Item) -> Void,
        onDelete: @escaping (Item) -> Void
    ) {
        self.allTitle = allTitle
        self.leading = leading
        self.groups = groups
        _selection = selection
        self.onRename = onRename
        self.onDelete = onDelete
    }

    /// 点击某个 chip 后的新选中值。再点当前项回到「全部」（nil）。
    public static func nextSelection(tapped id: String, current: String?) -> String? {
        current == id ? nil : id
    }

    /// 轨道形状：完全圆角的胶囊。背景与裁剪必须用同一个，否则圆角处会露出底色。
    private var trackShape: Capsule {
        Capsule()
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ConnSpacing.xxs) {
                ForEach(leading) { item in
                    chip(title: item.title, isSelected: selection == item.id) {
                        selection = Self.nextSelection(tapped: item.id, current: selection)
                    }
                }
                chip(title: allTitle, isSelected: selection == nil) { selection = nil }
                ForEach(groups) { group in
                    chip(title: group.title, isSelected: selection == group.id) {
                        selection = Self.nextSelection(tapped: group.id, current: selection)
                    }
                    .contextMenu {
                        Button {
                            onRename(group)
                        } label: {
                            Label(L("重命名分组"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            onDelete(group)
                        } label: {
                            Label(L("删除分组"), systemImage: "trash")
                        }
                    }
                }
            }
            // 胶囊端头的弧在 chip 的上下缘处已内收约 6pt，内缩小于这个值
            // 首尾两枚 chip 的药丸会被切掉一角。
            .padding(.horizontal, ConnSpacing.xs)
        }
        // 横向 ScrollView 在纵向是贪心的，会吃掉父容器给的全部高度。没有背景时
        // 看不出来，一旦画上轨道就会顶到大标题上——必须先按内容高度收缩。
        .fixedSize(horizontal: false, vertical: true)
        // 轨道自身不滚动：背景与裁剪都加在 ScrollView 上，chip 在轨道内滚动。
        // 若加在 HStack 上，轨道会跟着内容一起变宽并滑出屏幕。
        .background(Color.connSurface, in: trackShape)
        .clipShape(trackShape)
        .padding(.horizontal, ConnSpacing.page)
        .sensoryFeedback(ConnHapticFeedback.highImpact, trigger: selection)
    }

    /// 单个 chip。
    ///
    /// 未选中态**不画自己的底与描边**：它已经躺在白色轨道上，再叠一层同色系的面
    /// 只会互相干扰。选中态是轨道上唯一的一枚药丸，与系统分段控件的滑块同义。
    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.connFootnote)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? .connAccent : .connMuted)
                .padding(.horizontal, ConnSpacing.sm)
                .padding(.vertical, 6)
                .background(isSelected ? Color.connAccentFill : Color.clear, in: .capsule)
                .connHitTarget()
        }
        .buttonStyle(ConnPressStyle())
    }
}
