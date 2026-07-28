import SwiftUI

/// 负载色标：把 0–100 的负载值映射成「低=绿、高=红」的连续颜色。
///
/// **为什么要有它**：改造前 CPU / 内存 / 磁盘各有一个专属底色（紫 / 蓝 / 橙），
/// 于是同一个百分比在不同指标上颜色不同，横向扫一眼看不出谁负载高；而 80 / 92
/// 两道阈值上颜色又是硬跳变，79% 与 81% 像两个世界、12% 与 78% 却一模一样。
///
/// 锚点直接复用状态胶囊在用的三个语义色令牌，所以环刚变金与胶囊刚变「警告」
/// 是同一时刻发生的，两者讲同一个故事。
///
/// **只暴露 `gradient`，不提供「取某个值的单色」**：那需要在静态上下文里做
/// `Color` 混合，而 iOS 17 没有 `Color.mix`，退路 `Color.resolve(in:)` 又要
/// `EnvironmentValues`——传默认值会把当前外观固化，而这三个锚点令牌都是
/// 自适应深浅色的。渐变的插值发生在 SwiftUI 渲染管线里，适配是正确的。
public enum ConnLoadScale {
    /// 渐变停靠点，位置用 0…1 表示。
    ///
    /// 位置取自 `ConnThreshold`，不写字面量——那组阈值同时被 `HealthEvaluator`
    /// 用于健康判定，写死会在调阈值时静默失配。
    static let stops: [(location: Double, color: Color)] = [
        (0, .connGood),
        (ConnThreshold.calm / 100, .connGood),
        (ConnThreshold.warn / 100, .connWarn),
        (ConnThreshold.crit / 100, .connCrit),
        (1, .connCrit)
    ]

    /// 铺满 0–100 整条轨道的渐变，供弧与条填充。
    ///
    /// **必须铺满整条轨道再裁剪**，不能把它压进已填充的那一段——压缩后无论
    /// 20% 还是 94% 都会从绿扫到红，「值越高越红」的信息完全丢失。环因为
    /// `trim` 与 `AngularGradient` 同起点、同旋转而天然正确；条形图必须显式处理。
    public static var gradient: Gradient {
        Gradient(stops: stops.map { .init(color: $0.color, location: CGFloat($0.location)) })
    }
}
