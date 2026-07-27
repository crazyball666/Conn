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

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ConnSpacing.xs) {
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
            .padding(.horizontal, ConnSpacing.page)
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.connFootnote)
                .foregroundStyle(isSelected ? .connAccent : .connMuted)
                .padding(.horizontal, ConnSpacing.sm)
                .padding(.vertical, 6)
                .background(isSelected ? Color.connAccentFill : Color.connSurface, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(
                        isSelected ? Color.connAccent.opacity(0.5) : Color.connLine,
                        lineWidth: 1
                    )
                }
                .connHitTarget()
        }
        .buttonStyle(ConnPressStyle())
    }
}
