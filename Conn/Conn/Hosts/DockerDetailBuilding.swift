import ConnUI
import SwiftUI

/// Docker 各详情页 + 列表行共用的版式构件。
///
/// `section`/`infoRows`/`containerRow`/`unusedNotice` 从 `ContainerDetailView` 的
/// 私有方法抽出——卷、网络、镜像三个详情页要用同一套版式，照抄三份就是四份会
/// 各自漂移的重复。`resourceRow` 是卷、网络两个列表分段共用的行样式，二者结构
/// 完全一致（图标 + 名称/副标题 + 尾部徽标 + chevron），只有图标与徽标判据不同。
enum DockerDetail {
    /// 带眉标的分组卡片。
    @ViewBuilder
    static func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(title).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                content()
            }
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .connSurface(cornerRadius: ConnRadius.card)
        }
    }

    /// 左标签右取值的键值行组，行间细分隔线。
    static func infoRows(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                HStack(spacing: ConnSpacing.sm) {
                    Text(row.0).font(.connSubheadline).foregroundStyle(.connMuted)
                    Spacer()
                    Text(row.1).font(.connData()).connTabularNumbers().foregroundStyle(.connInk)
                        .lineLimit(1).minimumScaleFactor(0.6).multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .padding(.vertical, ConnSpacing.sm)
            }
        }
    }

    /// 可点的容器行。三个详情页的「引用/接入容器」段共用。
    static func containerRow(name: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "shippingbox").font(.system(size: 11))
                    .foregroundStyle(.connMuted).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.connData(.caption2)).foregroundStyle(.connInk)
                    if let subtitle {
                        Text(subtitle).font(.connData(.caption2)).foregroundStyle(.connMuted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.connMuted)
            }
            .padding(.vertical, ConnSpacing.xs)
        }
        .buttonStyle(.plain)
    }

    /// 「没有容器在用」的空态，可选带「未使用」徽标。
    ///
    /// - Parameter showsUnusedBadge: 默认 true（卷 / 镜像详情页的既有调用点不用改）。
    ///   预置网络（bridge/host/none）必须传 `false`——它们永远删不掉，这里若还打出
    ///   「未使用」warn 胶囊，会跟同一屏顶部已经显示的「预置，不可删除」自相矛盾，
    ///   也推翻了列表侧 `DockerView.networkRow`「预置优先于未使用」的既有判断。
    static func unusedNotice(_ text: String, showsUnusedBadge: Bool = true) -> some View {
        HStack(spacing: ConnSpacing.xs) {
            if showsUnusedBadge {
                StatusPill(L("未使用"), semantic: .warn)
            }
            Text(text).font(.connFootnote).foregroundStyle(.connMuted)
        }
    }

    /// 卷 / 网络列表行：图标 + 名称/副标题 + 可选尾部徽标 + chevron，整行可点。
    /// 两个列表的行样式逐字相同，抽出以免各自漂移。
    /// `title` 打包 name/subtitle 两项——不打包会撞 SwiftLint 的参数个数上限。
    static func resourceRow(
        icon: String,
        accented: Bool,
        title: (name: String, subtitle: String),
        badge: (text: String, semantic: StatusPill.Semantic)?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: icon).font(.system(size: 18))
                    .foregroundStyle(accented ? .connAccent : .connMuted).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.name).font(.connData(.footnote)).foregroundStyle(.connInk).lineLimit(1)
                    Text(title.subtitle).font(.connData(.caption2)).foregroundStyle(.connMuted).lineLimit(1)
                }
                Spacer(minLength: ConnSpacing.xs)
                if let badge {
                    StatusPill(badge.text, semantic: badge.semantic)
                }
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.connMuted)
            }
            .padding(ConnSpacing.cardPadding)
            .connSurface(cornerRadius: ConnRadius.card)
        }
        .buttonStyle(.plain)
    }

    /// 列表头：计数文案 + 刷新按钮。卷 / 网络两个分段共用
    /// （镜像段另带清理悬空菜单，结构不同，不强行复用）。
    static func listHeader(count: String, onRefresh: @escaping () -> Void) -> some View {
        HStack {
            Text(count).font(.connData(.caption2)).foregroundStyle(.connDim)
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 16)).foregroundStyle(.connAccent)
            }
        }
    }

    /// `listBody` 的加载状态：错误 / 加载中 / 空态文案。打包成具名类型而非元组——
    /// 四个字段的元组会撞 SwiftLint 的 `large_tuple` 上限（>3 个成员即报错）。
    struct ListState {
        let error: String?
        let loaded: Bool
        let loadingText: String
        let emptyText: String

        init(error: String?, loaded: Bool, loadingText: String, emptyText: String) {
            self.error = error
            self.loaded = loaded
            self.loadingText = loadingText
            self.emptyText = emptyText
        }
    }

    /// 列表分段的加载状态机：错误 / 加载中 / 空 / 有内容四态。
    /// 镜像、卷、网络三个分段结构完全一致，只有文案与行视图不同——抽出以免
    /// 三份各自漂移（也是 `DockerView` 顶着 SwiftLint `type_body_length` 阈值时
    /// 挤出的空间，属于真去重而非单纯挪代码）。
    @ViewBuilder
    static func listBody<Item: Identifiable>(
        items: [Item],
        state: ListState,
        @ViewBuilder row: @escaping (Item) -> some View
    ) -> some View {
        if let error = state.error {
            ConnBanner(error, systemImage: "exclamationmark.triangle")
        } else if !state.loaded {
            ProgressView(state.loadingText).font(.connFootnote).foregroundStyle(.connMuted)
                .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
        } else if items.isEmpty {
            Text(state.emptyText).font(.connSubheadline).foregroundStyle(.connMuted)
                .padding(.vertical, ConnSpacing.xl)
        } else {
            ForEach(items) { row($0) }
        }
    }
}
