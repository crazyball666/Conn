# 负载色标：指标配色统一为绿→红连续渐变 设计文档

日期：2026-07-28

## 背景与问题

服务器卡片上 CPU / 内存 / 磁盘三个环的颜色，在阈值以下由**各指标专属色**决定，
彼此不同：CPU 紫（`connAccent`）、内存蓝（`connInfo`）、磁盘橙（`connDisk`）。

后果是**同一个百分比在不同指标上颜色不同**，横向扫一眼看不出谁负载高。
Demo 数据里 api-02 的 CPU 14%（紫）、内存 27%（蓝）、磁盘 61%（橙）——
橙色的 61% 看起来比紫色的 14% 更「热」，但那只是因为磁盘的底色本来就是橙。

另一半问题是**阈值处硬跳变**：80 和 92 两道坎上颜色瞬间切换，中间没有过渡，
79% 和 81% 看起来是两个世界，而 12% 和 78% 看起来完全一样。

### 现状：四份重复的三段判定

同一段逻辑在四处各写了一遍，只有 base tint 不同：

| 位置 | 形态 | base tint |
|---|---|---|
| `ConnUI/Components/HealthCard.swift` `ringColor(_:_:)` | 环 ×3 | 调用方传入（accent / info / disk） |
| `ConnUI/Components/MetricGauge.swift` `arcColor` | 环 | 调用方传入 |
| `Conn/Hosts/HostOverviewView.swift` `coreBarColor(_:)` | 每核 CPU 条 | `connAccent` |
| `Conn/Hosts/ContainerCard.swift` `barColor(_:_:)` | Docker CPU / 内存条 | accent / info |

四份的判定完全一致：

```swift
if value > ConnThreshold.crit { return .connCrit }   // > 92
if value > ConnThreshold.warn { return .connWarn }   // > 80
return tint
```

**`MetricGauge` 全仓零调用方**（只有自己的 `#Preview` 在用）——`HealthCard` 没用它，
而是内联画了一套自己的环。它是死代码，且是第二份会漂移的配色逻辑。

## 目标

- 负载高低由颜色**统一**表达：低=绿、高=红，与是哪个指标无关。
- 阈值处不再硬跳变，全程连续过渡。
- 四份重复的配色判定收敛成一份可单测的纯函数。

## 非目标

- **详情页的内存分解堆叠图不动。** 它画的是已用 / 缓存 / 空闲的**构成**，
  不是负载高低，套负载色标反而没法读。
- **网络 / IO 趋势线不动。** 同理，那些颜色区分的是「不同的序列」（上行 vs 下行、
  读 vs 写），不是负载。
- 不改 80 / 92 这两个阈值本身，也不改 `HealthEvaluator` 的判定。
- 不动 `connDisk` / `connAccent` / `connInfo` 这些令牌本身——它们在别处仍在用
  （`connDisk` 用于 IO 趋势图图例与 CPU 硬中断统计），只是不再充当负载指示的底色。

## 关键决策

| 决策 | 结论 | 理由 |
|---|---|---|
| 渐变形态 | **弧 / 条沿长度扫过绿→红**（转速表语义） | 环上每个角度位置对应那个位置的负载值；弧尖颜色即当前值 |
| 渐变锚点 | 锚到现有 80 / 92 阈值 | 环刚变金与胶囊刚变警告同时发生，两者讲同一个故事 |
| 锚点色值 | 直接复用 `connGood` / `connWarn` / `connCrit` | 与状态胶囊连色值都一致，且这三个令牌已适配深浅色 |
| 低载区 | 0–40 恒定绿 | 日常负载不该发黄制造警觉；上界初定 60，实测偏高，落地时下调为 40 |
| 高载区 | 92–100 恒定红 | 封顶，超过危险线没有「更红」的必要 |
| `MetricGauge` | **删除** | 零调用方的死代码，且是第二份会漂移的配色逻辑 |
| 色标位置 | `ConnUI/Tokens` | 与 `ConnThreshold` 同处；纯函数，可脱离 SwiftUI 单测 |

## 色标定义

新增 `Packages/ConnPackages/Sources/ConnUI/Tokens/ConnLoadScale.swift`：

| 区间 | 颜色 |
|---|---|
| 0 – 40 | `connGood` 恒定 |
| 40 → 80 | `connGood` → `connWarn` 线性过渡 |
| 80 → 92 | `connWarn` → `connCrit` 线性过渡 |
| 92 – 100 | `connCrit` 恒定 |

对外只暴露一样东西：

```swift
public enum ConnLoadScale {
    /// 渐变停靠点。`gradient` 由它派生。位置取自 `ConnThreshold`，不写字面量。
    static let stops: [(location: Double, color: Color)] = [
        (0, .connGood),
        (ConnThreshold.calm / 100, .connGood),
        (ConnThreshold.warn / 100, .connWarn),
        (ConnThreshold.crit / 100, .connCrit),
        (1, .connCrit)
    ]

    /// 铺满 0–100 整条轨道的渐变。给弧与条填充用。
    ///
    /// **必须铺满整条轨道再裁剪**，不能把它压进已填充的那一段——
    /// 详见「实现陷阱」一节。
    public static var gradient: Gradient
}
```

**不提供「取某个负载值的单色」**（本文初稿曾计划提供 `color(at:)`，评审时否掉）：
那需要在静态上下文里做 `Color` 混合，而 `Color.mix(with:by:)` 是 iOS 18 API、
本项目基线 iOS 17；退路 `Color.resolve(in:)` 虽然 iOS 17 可用，却需要
`EnvironmentValues`——传默认值会把当前外观固化，而 `connGood` / `connWarn` /
`connCrit` 三个锚点令牌都是自适应深浅色的。而它**本来就零调用方**。
渐变的插值发生在 SwiftUI 渲染管线里，适配是正确的；真需要单色时按当时的
实际需求另行设计，不预留。

低载区上界是本设计新引入的常量（`ConnThreshold` 只有 `warn` / `crit`）。
把它一并放进 `ConnThreshold`，命名 `calm`，并注明它只影响观感、不参与任何健康判定。

> 初稿定 60，落地后实测偏高——日常 40–60 的机器全是纯绿，颜色几乎不携带信息。
> 已下调为 **40**。`warn` / `crit` 不动，它们与 `HealthEvaluator` 共用。

## 四处调用点的改造

### 1. `HealthCard` 的三个环

`ring(_:value:sub:tint:)` 删掉 `tint` 参数，三个调用点跟着删。
`ringColor(_:_:)` 私有方法删掉。填充从纯色换成 `AngularGradient(ConnLoadScale.gradient, center: .center)`。

角度与负载值天然一一对应：`Circle().trim(from: 0, to: fraction)` 与 `AngularGradient`
都从 3 点钟起算，又被同一个 `.rotationEffect(.degrees(-90))` 一起旋转。
20% 的弧只吃到渐变前 20%（整体绿），94% 的弧从绿一路扫到红。

无数据（`value == nil`）时仍是 `connTrack`，与现状一致。

**弧上原有的辉光一并去掉**：改造前是 `.shadow(color: ringColor(value, tint).opacity(0.3), radius: 2)`，
取的是 `tint`（专属色）的阴影色。渐变化之后弧上已经没有单一颜色可取——阴影要固定取哪一点的颜色
没有自然答案，而设计规范 §2「层次手法」本就明确「不用外发光」，遂顺势删除，不再保留。

**但笔帽必须从 `.round` 改成 `.butt`**（本节初稿漏了这一条，截图验收才抓到）。
圆头笔帽会在弧**起点之前**多画半个笔宽（这组尺寸下约 9.13°），而 `AngularGradient`
是循环的——0° 之前取到的是色标末端的红，于是**每个低载环的起点都顶一颗红点**。

试过把渐变接缝整体平移 `capLeadIn` 来躲开：红点消失，但跨度恰好 360° 时
**≥97.5% 的弧尖会绕回绿端**（用 `ImageRenderer` 逐像素测出断点在 f=0.9746，
正好等于 `seamAngle / 360°`）——98%、99% 的环显示绿尖，把本特性的含义完全反过来。
再把跨度补足到 `360° + capLeadIn`，重叠扇区的归属又变成二义的，动画过渡期间
歇性把红点带回来。

**根因是几何冲突，不是参数没调好**：圆头笔帽的起点外伸区，与接近满载的弧尖，
占据同一个角度扇区；一条循环的 `AngularGradient` 不可能同时让它是绿的又是红的。
改用平头后弧严格占据 `[0°, 360°·负载]`，与渐变精确一一对应，问题整类消失，
代价只是弧两端由圆变平。

### 2. `MetricGauge`

整个文件删除。零调用方，删掉即可，无连带改动。

### 3. `HostOverviewView` 的每核 CPU 条

`coreBarColor(_:)` 删掉，`Capsule().fill(...)` 换成负载渐变。
**必须按下节的陷阱处理**——条形图不像环那样天然正确。

### 4. `ContainerCard` 的 Docker 条

`barColor(_:_:)` 删掉，`percentCell(_:value:tint:)` 删掉 `tint` 参数，
CPU 与内存两个调用点跟着删。填充同样按下节处理。

> Docker 的网络 / IO 走 `flowCell`，是纯文本流量读数、没有颜色，不受影响。

## 实现陷阱：条形图的渐变必须铺满轨道

条现在是这样画的（`HostOverviewView` 与 `ContainerCard` 同构）：

```swift
ZStack(alignment: .leading) {
    Capsule().fill(Color.connTrack)
    Capsule().fill(coreBarColor(usage))
        .frame(width: max(4, geometry.size.width * fraction(usage)))
}
```

直接把 `fill` 换成渐变，SwiftUI 会**把整条渐变压缩进已填充的宽度**——
结果是无论 20% 还是 94%，条子都从绿扫到红，「值越高越红」的信息完全丢失。

正确做法：让渐变铺满**整条轨道**，再裁到当前宽度。落地时把这段收进了
`ConnUI/Components/ConnLoadBar.swift`（初稿计划是两处各贴一份，评审判定该抽），
两个调用点各剩一行——这个技巧只此一份，将来新增条形图不会重犯。组件形如

```swift
Capsule()
    .fill(LinearGradient(gradient: ConnLoadScale.gradient,
                         startPoint: .leading, endPoint: .trailing))
    .frame(width: geometry.size.width)          // 渐变按全宽铺
    .mask(alignment: .leading) {                 // 再裁到当前值
        Capsule().frame(width: max(4, geometry.size.width * fraction(usage)))
    }
```

**这个错误在 90% 时看着完全正常，只有低载才暴露**——所以验收必须拿低载样本。

## 测试

**ConnUITests**（断言 `stops` 表本身，不碰颜色解析）
- 停靠点在 0…1 上单调不减，首尾正好是 0 与 1（顺序错会让渐变回折）。
- 停靠点位置取自 `ConnThreshold.calm / .warn / .crit`，不是字面量。
- 低载段两端同色（0 与 calm）、高载段两端同色（crit 与 1.0）——这两条保证
  恒定段真的恒定。
- `gradient` 的停靠位置与 `stops` 一致（防止两条路径漂移）。

> 不去断言「70 应等于 50/50 混合」这类插值结果：在 host 上把资源目录里的
> `Color` 解析成 RGB 并不可靠，而插值本身由 SwiftUI 的 `Gradient` 负责，
> 不是我们的代码。`stops` 表就是我们全部的行为。

**变异验证**（必做，本仓库已抓到过四次假测试）
- 把 calm 那个停靠点的颜色改成 `connWarn`，确认「低载段两端同色」变红。
- 把 1.0 那个停靠点的颜色改成 `connWarn`，确认「高载段两端同色」变红。
- 把 warn 与 crit 两行对调制造回折，确认「停靠点单调」变红。

> 「渐变有没有铺满轨道」这一条**单测覆盖不到**——它是 SwiftUI 的布局行为，
> 只能靠截图验收，见下。这是本次改动最容易出错、又最没有自动化护栏的地方。

**截图验收**（渐变与轨道的对齐关系单测覆盖不到）
- 主机卡：Demo 里有 14% / 27% / 61% 的正常机与 84% / 92% / 90% 的故障机，
  两种都要拍。重点确认**同一百分比在不同指标上颜色一致**——这正是本次要改的。
- 每核 CPU 条：详情页概览段（`CONN_SMOKE_DETAIL=1`）。
- Docker 条：`CONN_SMOKE_DETAIL=1` + `CONN_SMOKE_SEGMENT=docker`。
- **低载样本是必须的**：上述实现陷阱在高载时看不出来。

## i18n

本次不新增任何面向用户的文案。

## 待办（不在本次范围）

- 详情页内存分解堆叠图与网络 / IO 趋势线的配色（它们表达的是构成与序列，
  不是负载，若要改需另行设计）。
