# 负载色标 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 CPU / 内存 / 磁盘等负载指示的配色统一成一条绿→红连续渐变，取代现在「每个指标各自固定色 + 阈值处硬跳变」的做法。

**Architecture:** 新增 `ConnLoadScale`（`ConnUI/Tokens`）作为唯一色标来源，锚点复用状态胶囊的 `connGood` / `connWarn` / `connCrit` 三个语义色令牌，停靠点对齐现有的 80 / 92 阈值。四处重复的三段判定全部换成它；其中零调用方的 `MetricGauge` 直接删除。环因为 `trim` 与 `AngularGradient` 同起点同旋转而天然对齐，条形图必须显式把渐变铺满整条轨道再裁剪。

**Tech Stack:** Swift 5.10 / iOS 17 / SwiftUI / Swift Testing（`@Test` `#expect`）/ SwiftLint。

设计依据：`docs/superpowers/specs/2026-07-28-load-color-scale-design.md`。

## Global Constraints

- **平台基线 iOS 17**，SPM 包 `platforms: [.iOS(.v17), .macOS("15.0")]`，不得提高。
- **色标停靠点**：0–60 恒 `connGood`；60→80 `connGood`→`connWarn`；80→92 `connWarn`→`connCrit`；92–100 恒 `connCrit`。80 / 92 必须取自 `ConnThreshold.warn` / `.crit`，不得写成字面量——它们与 `HealthEvaluator` 的健康判定共用同一组阈值。
- **`ConnUI` 不得引入新依赖**。检查 `Packages/ConnPackages/Package.swift`，`ConnUI` target 目前零依赖。
- **设计规范 §2：色彩不是唯一指示。** 本次不削弱任何既有的形状 / 数值编码——三个环中央的百分比数字、条右侧的百分比文本都必须保留。
- 注释与文档字符串用中文，解释「为什么」而非复述代码。
- 面向用户的文案走 `L("…")`（本次不新增文案）。
- **SwiftLint 基线 7 条既有警告**，标准是**不新增**，不是归零。**必须在 `Tooling/` 目录下运行**：`cd Tooling && swiftlint lint --quiet | wc -l`（仓库根运行会漏掉 `.build` 排除规则、报出一堆假警告）。
- **包测试**：`cd Packages/ConnPackages && swift test --filter <Suite>`。
- **App 构建**：`xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug`。
- **跨模块改动后若 `swift test` 出现莫名其妙的失败或链接错误**，先 `rm -rf .build/debug` 再判断——本仓库有过 SwiftPM 增量构建导致 enum case 标签错位、五条无关测试变红的先例。签名变更导致的链接错误则用 `find Tests -name "*.swift" -exec touch {} +` 强制重编。
- **不要启动新模拟器**。先 `xcrun simctl list devices booted`；若全 Shutdown 用 `xcrun simctl bootstatus <udid> -b` 启回**同一台**。已知 `3E72DF80-B012-4A74-9217-F079D5FA00B1` 有 CoreSimulator 权限故障，可用同机已有的 `EAA9BFB6...`（iPhone 16 Pro）。
- **DerivedData 里有多个 `Conn.app`**（含 2026-07-19 的陈旧构建），装包前务必按时间取最新：`ls -dt $(find ~/Library/Developer/Xcode/DerivedData -name "Conn.app" -path "*Debug-iphonesimulator*" -not -path "*Index.noindex*") | head -1`。

---

### Task 1: ConnLoadScale 色标

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnUI/Tokens/ConnLoadScale.swift`
- Modify: `Packages/ConnPackages/Sources/ConnUI/Tokens/ConnMetrics.swift`（`ConnThreshold` 加 `calm`）
- Test: `Packages/ConnPackages/Tests/ConnUITests/ConnLoadScaleTests.swift`（新建）

**Interfaces:**
- Consumes: 无（第一个任务）。
- Produces:
  - `ConnThreshold.calm: Double = 60`
  - `ConnLoadScale.stops: [(location: Double, color: Color)]`（internal，供测试断言）
  - `ConnLoadScale.gradient: Gradient`（public，四处调用点唯一使用的东西）

**与 spec 的一处偏离（必读）**：spec 里还列了 `color(at:)` 与插值函数。**不做**，理由有二：

1. **编译不过**。`Color.mix(with:by:)` 是 iOS 18 API，本项目基线是 iOS 17。
2. **退路会烤死深浅色适配**。`Color.resolve(in:)` 虽然 iOS 17 可用，但需要
   `EnvironmentValues`；在静态函数里传默认值会把当前外观固化，而 `connGood` /
   `connWarn` / `connCrit` 三个锚点令牌都是自适应的。

而 `color(at:)` **本来就零调用方**（spec 写的是「给未来的其它控件预留」）。
真正被四处调用点使用的只有 `gradient`，它的插值发生在 SwiftUI 渲染管线里，
深浅色适配是正确的。按 YAGNI 砍掉，连带这个难题一起消失。
需要单色时再按当时的真实需求设计，不要现在预留。

- [ ] **Step 1: 写失败测试**

新建 `Packages/ConnPackages/Tests/ConnUITests/ConnLoadScaleTests.swift`：

```swift
import Foundation
import SwiftUI
import Testing
@testable import ConnUI

@Suite("ConnLoadScale — 负载色标")
struct ConnLoadScaleTests {
    /// 停靠点在 0…1 上单调不减，且首尾正好覆盖满量程。
    /// 顺序错了会让渐变出现回折，是这类表驱动代码最容易出的错。
    @Test("停靠点单调且铺满 0…1")
    func stopsAreMonotonicAndFull() {
        let locations = ConnLoadScale.stops.map(\.location)
        #expect(locations == locations.sorted())
        #expect(locations.first == 0)
        #expect(locations.last == 1)
    }

    /// 停靠点必须取自 ConnThreshold，不能写字面量——那组阈值同时被
    /// HealthEvaluator 用于健康判定，写死会在调阈值时静默漂移，
    /// 造成「环已经变金但胶囊还说正常」。
    @Test("停靠点对齐 ConnThreshold")
    func stopsAlignWithThresholds() {
        let locations = ConnLoadScale.stops.map(\.location)
        #expect(locations.contains(ConnThreshold.calm / 100))
        #expect(locations.contains(ConnThreshold.warn / 100))
        #expect(locations.contains(ConnThreshold.crit / 100))
    }

    /// 低载平台期：0 与 calm 两个停靠点必须同色，否则 0–60 段不是恒定绿。
    @Test("低载段两端同色")
    func calmRangeIsFlat() {
        let first = ConnLoadScale.stops[0]
        let calm = ConnLoadScale.stops[1]
        #expect(first.location == 0)
        #expect(calm.location == ConnThreshold.calm / 100)
        #expect(first.color == calm.color)
    }

    /// 高载封顶：crit 与 1.0 两个停靠点必须同色。
    @Test("高载段两端同色")
    func critRangeIsFlat() {
        let crit = ConnLoadScale.stops[3]
        let last = ConnLoadScale.stops[4]
        #expect(crit.location == ConnThreshold.crit / 100)
        #expect(last.location == 1)
        #expect(crit.color == last.color)
    }

    /// gradient 必须由 stops 派生，否则两者会漂移成两套配色。
    @Test("gradient 的停靠位置与 stops 一致")
    func gradientMatchesStops() {
        let actual = ConnLoadScale.gradient.stops.map { Double($0.location) }
        let expected = ConnLoadScale.stops.map(\.location)
        #expect(actual.count == expected.count)
        for (lhs, rhs) in zip(actual, expected) {
            #expect(abs(lhs - rhs) < 0.0001)
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter ConnLoadScaleTests 2>&1 | grep -E "error:|✘|Test run" | head -5
```

Expected: 编译失败 —— `ConnLoadScale` 与 `ConnThreshold.calm` 不存在。

- [ ] **Step 3: 给 ConnThreshold 加 calm**

`Packages/ConnPackages/Sources/ConnUI/Tokens/ConnMetrics.swift` 末尾的 `ConnThreshold` 改成：

```swift
/// 指标阈值。超阈值时指标色统一切 warn / crit（设计规范 §5）。
public enum ConnThreshold {
    /// 低于此值视为「平静」，负载色标在这一段保持恒定绿。
    ///
    /// **只影响观感，不参与任何健康判定**——`HealthEvaluator` 只认 `warn` / `crit`。
    /// 之所以要留出这段平台期：50% 的 CPU 完全正常，若从 0 就开始往黄端爬，
    /// 用户每天都在看一片发黄的卡片，真正该警觉时反而失去对比。
    public static let calm: Double = 60
    /// 超过此值转为警告色。
    public static let warn: Double = 80
    /// 超过此值转为危险色。
    public static let crit: Double = 92
}
```

- [ ] **Step 4: 实现 ConnLoadScale**

新建 `Packages/ConnPackages/Sources/ConnUI/Tokens/ConnLoadScale.swift`：

```swift
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
```

- [ ] **Step 5: 跑测试确认通过**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter ConnLoadScaleTests 2>&1 | grep -E "✘|Test run" | head -5
```

Expected: 5 条全部 PASS。

- [ ] **Step 6: 变异验证**

三次变异，每次跑 `swift test --filter ConnLoadScaleTests`，确认对应用例变红后还原：

1. 把 `(ConnThreshold.calm / 100, .connGood)` 改成 `(ConnThreshold.calm / 100, .connWarn)`
   → `calmRangeIsFlat` 应变红。
2. 把 `(1, .connCrit)` 改成 `(1, .connWarn)` → `critRangeIsFlat` 应变红。
3. 把 `stops` 里 `warn` 与 `crit` 两行对调（制造回折）→ `stopsAreMonotonicAndFull` 应变红。

三次都还原后 `git diff` 确认无残留，把失败输出写进报告。

> 若某次变异**没有**让测试变红，说明那条测试是空转的，必须先把测试修到能红再继续
> ——本仓库此前已抓到过四次假测试。

- [ ] **Step 7: 构建 + lint**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift build 2>&1 | grep -E "error:" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
```

Expected: 无 error；lint 为 7。

- [ ] **Step 8: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "feat(ui): 新增 ConnLoadScale 负载色标

低=绿、高=红的连续渐变，停靠点锚在 ConnThreshold 的 calm/warn/crit 上，
锚点色值复用状态胶囊的三个语义色令牌。只暴露 gradient——静态上下文里做
Color 混合会烤死深浅色适配（iOS 17 无 Color.mix，resolve 需要环境）。"
```

---

### Task 2: HealthCard 三个环换成负载渐变，并删除 MetricGauge

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnUI/Components/HealthCard.swift`
- Delete: `Packages/ConnPackages/Sources/ConnUI/Components/MetricGauge.swift`

**Interfaces:**
- Consumes: `ConnLoadScale.gradient`（Task 1）。
- Produces: `HealthCard` 的私有 `ring(_:value:sub:)` 不再有 `tint` 参数（仅内部影响）。

- [ ] **Step 1: 确认 MetricGauge 确实零调用方**

```bash
cd /Users/crazyball/Code/Swift/Conn && grep -rn "MetricGauge" --include="*.swift" . | grep -v "\.build" | grep -v "MetricGauge.swift"
```

Expected: 无输出。若有输出，**停下来在报告里说明**，不要硬删。

- [ ] **Step 2: 删除 MetricGauge**

```bash
rm /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages/Sources/ConnUI/Components/MetricGauge.swift
```

- [ ] **Step 3: 检查 gauge 尺寸令牌是否变成孤儿**

```bash
cd /Users/crazyball/Code/Swift/Conn && grep -rn "gaugeDiameter\|gaugeLineWidth" --include="*.swift" . | grep -v "\.build"
```

只剩 `ConnMetrics.swift` 里的声明说明它们已无人使用。**本任务不删它们**——
`ConnSize` 是设计系统的尺寸令牌表，成组存在有其意义，删单个令牌属于另一件事。
在报告里记一笔即可。

- [ ] **Step 4: 环改用负载渐变**

`HealthCard.swift` 的 `metricBand` 三个调用去掉 `tint:`：

```swift
    private var metricBand: some View {
        HStack(alignment: .top, spacing: ConnSpacing.xs) {
            ring(L("CPU"), value: model.cpu, sub: model.coresText)
            ring(L("内存"), value: model.memory, sub: model.memTotalText)
            ring(L("磁盘"), value: model.disk, sub: model.diskTotalText)
            flowColumn(L("网络"), model.net)
            flowColumn("IO", model.io)
        }
    }
```

`ring` 的签名与填充改成：

```swift
    /// 单个指标环。
    ///
    /// 颜色不再区分指标，而是**沿弧长扫过负载色标**——环上每个角度位置对应
    /// 那个位置的负载值，弧尖的颜色即当前值。`Circle().trim` 与 `AngularGradient`
    /// 都从 3 点钟起算，又被同一个 `rotationEffect(-90°)` 一起旋转，所以角度
    /// 与负载值天然对齐，不需要额外换算。
    private func ring(_ label: String, value: Double?, sub: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            ZStack {
                Circle().stroke(Color.connTrack, lineWidth: ringStroke)
                Circle().trim(from: 0, to: fraction(value))
                    .stroke(
                        arcStyle(for: value),
                        style: StrokeStyle(lineWidth: ringStroke, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.5, dampingFraction: 0.9), value: value)
                Text(value.map { "\(Int($0))%" } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .connTabularNumbers()
                    .foregroundStyle(.connInk)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: ringDiameter, height: ringDiameter)
            Text(sub)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.connMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// 无数据时是灰轨道色，有数据时是负载渐变。
    private func arcStyle(for value: Double?) -> AnyShapeStyle {
        guard value != nil else { return AnyShapeStyle(Color.connTrack) }
        return AnyShapeStyle(AngularGradient(gradient: ConnLoadScale.gradient, center: .center))
    }
```

> 原来那句 `.shadow(color: ringColor(value, tint).opacity(0.3), radius: 2)` **去掉**：
> 渐变没有单一颜色可取，而给整条弧套一个固定色阴影会与渐变打架。若视觉上
> 觉得少了层次，在截图验收时提出来另议，不要在这一步自行发明替代方案。

- [ ] **Step 5: 删掉 ringColor**

删除 `HealthCard.swift` 里整个 `private func ringColor(_ value: Double?, _ tint: Color) -> Color { … }`。

- [ ] **Step 6: 更新 HealthCard 的预览**

`HealthCard.swift` 底部 `#Preview` 里的样例数据保持不变（它们传的是 `Model`，
不涉及 `tint`）。确认预览仍能编译。

- [ ] **Step 7: 构建 + 全量包测试 + lint**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift build 2>&1 | grep -E "error:" | head -5
swift test 2>&1 | grep -E "✘|Test run" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
```

Expected: 无 error；测试全绿；lint 为 7。

- [ ] **Step 8: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "refactor(ui): HealthCard 三个环改用负载色标，删除死代码 MetricGauge

环的颜色不再区分指标，沿弧长扫过绿→红。MetricGauge 全仓零调用方，
且是第二份会漂移的配色逻辑，一并删除。"
```

---

### Task 3: 每核 CPU 条与 Docker 条换成负载渐变

两处条形图同构，且都要避开同一个陷阱，放在一个任务里做。

**Files:**
- Modify: `Conn/Conn/Hosts/HostOverviewView.swift`（`cpuPerCoreBars` 与 `coreBarColor`）
- Modify: `Conn/Conn/Hosts/ContainerCard.swift`（`metrics`、`percentCell`、`barColor`）

**Interfaces:**
- Consumes: `ConnLoadScale.gradient`（Task 1）。
- Produces: 无对外接口。

- [ ] **Step 1: 每核 CPU 条**

`HostOverviewView.swift` 的 `cpuPerCoreBars`，把内层 `ZStack` 改成：

```swift
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.connTrack)
                            // 渐变必须按**整条轨道**铺开再裁到当前值：直接
                            // `.fill(渐变).frame(width: 已填充宽度)` 会把整条渐变
                            // 压进那一小段，导致 20% 和 94% 都从绿扫到红，
                            // 「值越高越红」的信息全丢。这个错误在高载时看着
                            // 完全正常，只有低载才暴露。
                            Capsule()
                                .fill(LinearGradient(
                                    gradient: ConnLoadScale.gradient,
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(width: geometry.size.width)
                                .mask(alignment: .leading) {
                                    Capsule()
                                        .frame(width: max(4, geometry.size.width * fraction(usage)))
                                }
                        }
                    }
                    .frame(height: 6)
```

删除整个 `func coreBarColor(_ usage: Double) -> Color { … }`。

- [ ] **Step 2: Docker 条**

`ContainerCard.swift` 的 `metrics` 去掉 `tint:`：

```swift
    private var metrics: some View {
        HStack(alignment: .top, spacing: ConnSpacing.md) {
            percentCell(L("CPU"), value: container.cpuPercent)
            percentCell(L("内存"), value: container.memPercent)
            flowCell(L("网络"), container.netIO)
            flowCell("IO", container.blockIO)
        }
    }
```

`percentCell` 改成：

```swift
    /// CPU / 内存：标签 + 大百分比 + 细进度条。
    ///
    /// 条的颜色走负载色标（低=绿、高=红），与主机卡的环、详情页的每核条统一。
    private func percentCell(_ label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            Text(value.map { "\(Int($0))%" } ?? "—")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .connTabularNumbers().foregroundStyle(.connInk)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.connTrack)
                    // 渐变必须按**整条轨道**铺开再裁到当前值——直接 fill 到已填充
                    // 宽度会把整条渐变压进那一段，20% 也会从绿扫到红。
                    Capsule()
                        .fill(LinearGradient(
                            gradient: ConnLoadScale.gradient,
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: geometry.size.width)
                        .mask(alignment: .leading) {
                            Capsule()
                                .frame(width: max(3, geometry.size.width * fraction(value)))
                        }
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

删除整个 `private func barColor(_ value: Double?, _ tint: Color) -> Color { … }`。

> **无数据（`value == nil`）时**：`fraction(nil)` 返回 0，但 `max(3, ...)` 会让条子
> 仍显示 3pt 宽的绿头。这是**改动前就有的行为**（原来那 3pt 是 `barColor` 返回的
> `connTrack` 灰，与轨道同色所以看不见）。改成渐变后它会变成一小截绿色。
> **必须处理**：无数据时整段不渲染填充层，即把填充层包在 `if value != nil` 里。
> 每核 CPU 条不存在这个问题（`usage` 是非可选的 `Double`）。

- [ ] **Step 3: 构建 App**

```bash
cd /Users/crazyball/Code/Swift/Conn && xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug 2>&1 | grep -E "error:|BUILD" | head -5
```

Expected: `BUILD SUCCEEDED`。

- [ ] **Step 4: 跑 App 测试 + lint**

```bash
cd /Users/crazyball/Code/Swift/Conn
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for k,v in d.items():
    if v: print(v[0]["udid"]); break')" 2>&1 | grep -E "error:|\*\* TEST" | head -5
cd Tooling && swiftlint lint --quiet | wc -l
```

Expected: `TEST SUCCEEDED`；lint 为 7。

- [ ] **Step 5: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "refactor: 每核 CPU 条与 Docker 条改用负载色标

两处条形图都把渐变按整条轨道铺开再裁到当前值——直接 fill 到已填充宽度
会把渐变压进那一段，低载时也会从绿扫到红。Docker 条另修无数据时
露出绿头的问题（原来那 3pt 与轨道同色所以看不见）。"
```

---

### Task 4: 截图验收

渐变与轨道的对齐关系单测覆盖不到，**必须人眼确认，且必须看低载样本**——
压缩渐变那个错误在 90% 时看着完全正常。

**Files:**
- 无代码改动（仅当截图暴露问题时才回头改）

**Interfaces:**
- Consumes: Task 2 与 Task 3 的改动。
- Produces: 无。

- [ ] **Step 1: 装最新构建到已启动的模拟器**

```bash
cd /Users/crazyball/Code/Swift/Conn
DEV=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for k,v in d.items():
    if v: print(v[0]["udid"]); break')
# 没有已启动的设备时，从**已存在**的设备里挑一台 iPhone 启回来。不要 create 新设备。
if [ -z "$DEV" ]; then
  DEV=$(xcrun simctl list devices available -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for runtime, devices in d.items():
    for dev in devices:
        if dev["name"].startswith("iPhone"): print(dev["udid"]); sys.exit()')
  echo "没有已启动的设备，启回 $DEV"
  xcrun simctl bootstatus "$DEV" -b
fi
APP=$(ls -dt $(find ~/Library/Developer/Xcode/DerivedData -name "Conn.app" -path "*Debug-iphonesimulator*" -not -path "*Index.noindex*") | head -1)
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
echo "DEV=$DEV APP=$APP BUNDLE=$BUNDLE"
xcrun simctl install "$DEV" "$APP"
```

- [ ] **Step 2: 拍主机卡（含低载与高载）**

```bash
SIMCTL_CHILD_CONN_DEMO=1 xcrun simctl launch "$DEV" "$BUNDLE"
sleep 5
xcrun simctl io "$DEV" screenshot /tmp/loadscale-cards.png
```

Expected：Demo 里有 14% / 27% / 61% 的正常机与 84% / 92% / 90% 的故障机。
逐项确认：
1. **同一百分比在不同指标上颜色一致**（改动前 61% 的磁盘是橙、27% 的内存是蓝，
   这正是本次要改掉的）。
2. 低载环（14%、27%）整体偏绿，**不能**出现从绿扫到红的完整渐变——出现即是
   「渐变被压缩」的症状。
3. 高载环（92%）弧尖是红的。

- [ ] **Step 3: 拍每核 CPU 条**

```bash
xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null
SIMCTL_CHILD_CONN_DEMO=1 SIMCTL_CHILD_CONN_SMOKE_DETAIL=1 xcrun simctl launch "$DEV" "$BUNDLE"
sleep 5
xcrun simctl io "$DEV" screenshot /tmp/loadscale-cores.png
```

Expected：每核条中**低使用率的核心整条偏绿**，不是绿→红全渐变。

- [ ] **Step 4: 拍 Docker 条**

```bash
xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null
SIMCTL_CHILD_CONN_DEMO=1 SIMCTL_CHILD_CONN_SMOKE_DETAIL=1 SIMCTL_CHILD_CONN_SMOKE_SEGMENT=docker xcrun simctl launch "$DEV" "$BUNDLE"
sleep 5
xcrun simctl io "$DEV" screenshot /tmp/loadscale-docker.png
```

Expected：容器 CPU / 内存条同样低载偏绿；**无数据的容器（显示「—」）不应露出
任何彩色头部**（Task 3 Step 2 处理的那条）。

- [ ] **Step 5: 逐张读图并记录**

用 Read 工具**逐张打开这三张 PNG 亲眼看**，不要只凭截图命令成功就算通过。
把每张看到的内容写进报告：低载是什么色、高载是什么色、同卡三个指标的同值是否同色。

**若发现渐变被压缩**（低载也是绿→红全渐变），回到 Task 3 检查
`.frame(width: geometry.size.width)` 与 `.mask` 是否写对，改完重跑本任务。

- [ ] **Step 6: 提交截图记录**

截图存放在 `/tmp` 不入库。把观察结论写进报告即可，本步无需 commit。
若 Step 5 触发了回头修改，那次修改单独 commit。

---

## 附：任务顺序与验证门

| 任务 | 结束时的验证门 |
|---|---|
| 1 | `swift test --filter ConnLoadScaleTests`（5 条）+ 三次变异验证 |
| 2 | `swift build` + 全量 `swift test` + lint |
| 3 | `xcodebuild build` + `xcodebuild test` + lint |
| 4 | 三张截图逐张读图确认 |

Task 2 与 Task 3 都依赖 Task 1 的 `ConnLoadScale.gradient`，**必须先做 Task 1**。
Task 4 依赖前两者都已落地。
