# Interactive CPU Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show all eight CPU category histories as independently toggleable lines, provide accessible haptic legend controls, and give disk read/write lines clearly distinct fixed colors.

**Architecture:** Add small Foundation/ConnMonitor value types for CPU metric identity, visibility, and rolling category history. `HostOverviewViewModel` delegates CPU category sampling to that tested model. `HostOverviewView` owns transient visibility state, renders the metric grid as buttons, and passes only visible series to the shared chart with single-series area fill disabled for CPU.

**Tech Stack:** Swift 5, SwiftUI, Swift Charts, Observation, Swift Testing, XCUITest, iOS 17 sensory feedback.

---

### Task 1: CPU metric identity, selection, and history

**Files:**
- Create: `Conn/Conn/Hosts/CPUChartState.swift`
- Create: `Conn/ConnTests/CPUChartStateTests.swift`

- [ ] **Step 1: Write failing model tests**

```swift
import ConnMonitor
import Testing
@testable import Conn

@Suite("CPU 图表状态")
struct CPUChartStateTests {
    @Test("八个指标默认全部显示，切换只影响目标指标")
    func visibilityToggle() {
        var visibility = CPUChartVisibility()
        #expect(visibility.visible == Set(CPUChartMetric.allCases))

        visibility.toggle(.system)
        #expect(!visibility.contains(.system))
        #expect(visibility.contains(.user))

        visibility.toggle(.system)
        #expect(visibility.contains(.system))
    }

    @Test("八类 CPU 时间分别进入自己的历史")
    func independentHistories() {
        var history = CPUCategoryHistory()
        history.append(
            CPUBreakdown(
                user: 1, system: 2, iowait: 3, nice: 4,
                irq: 5, softirq: 6, steal: 7, idle: 72
            ),
            limit: 40
        )

        #expect(history[.user] == [1])
        #expect(history[.system] == [2])
        #expect(history[.iowait] == [3])
        #expect(history[.idle] == [72])
        #expect(history[.nice] == [4])
        #expect(history[.irq] == [5])
        #expect(history[.softirq] == [6])
        #expect(history[.steal] == [7])
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -only-testing:ConnTests/CPUChartStateTests -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

Expected: build/test failure because `CPUChartMetric`, `CPUChartVisibility`, and `CPUCategoryHistory` do not exist.

- [ ] **Step 3: Implement the minimal state models**

```swift
import ConnMonitor
import Foundation

enum CPUChartMetric: String, CaseIterable, Hashable, Sendable {
    case user, system, iowait, idle, nice, irq, softirq, steal
}

struct CPUChartVisibility: Equatable, Sendable {
    private(set) var visible = Set(CPUChartMetric.allCases)

    func contains(_ metric: CPUChartMetric) -> Bool { visible.contains(metric) }

    mutating func toggle(_ metric: CPUChartMetric) {
        if visible.contains(metric) {
            visible.remove(metric)
        } else {
            visible.insert(metric)
        }
    }
}

struct CPUCategoryHistory: Equatable, Sendable {
    private var samples: [CPUChartMetric: [Double]] = [:]

    subscript(metric: CPUChartMetric) -> [Double] { samples[metric] ?? [] }

    mutating func append(_ value: CPUBreakdown, limit: Int) {
        append(value.user, to: .user, limit: limit)
        append(value.system, to: .system, limit: limit)
        append(value.iowait, to: .iowait, limit: limit)
        append(value.idle, to: .idle, limit: limit)
        append(value.nice, to: .nice, limit: limit)
        append(value.irq, to: .irq, limit: limit)
        append(value.softirq, to: .softirq, limit: limit)
        append(value.steal, to: .steal, limit: limit)
    }

    private mutating func append(_ value: Double, to metric: CPUChartMetric, limit: Int) {
        samples[metric, default: []].append(value)
        if samples[metric, default: []].count > limit {
            samples[metric, default: []].removeFirst(samples[metric, default: []].count - limit)
        }
    }
}
```

- [ ] **Step 4: Run the model tests and verify GREEN**

Run the Step 2 command again.

Expected: `CPUChartStateTests` passes.

### Task 2: Feed all eight histories from the overview view model

**Files:**
- Modify: `Conn/Conn/Hosts/HostOverviewViewModel.swift`
- Test: `Conn/ConnTests/CPUChartStateTests.swift`

- [ ] **Step 1: Replace combined CPU history storage**

Remove `cpuUserHistory`, `cpuSystemHistory`, `cpuIowaitHistory`, `cpuOtherHistory`, and `cpuIdleHistory`. Add:

```swift
private(set) var cpuCategoryHistory = CPUCategoryHistory()
```

Change sampling to:

```swift
private func recordCPUBreakdown(_ breakdown: CPUBreakdown?) {
    guard let breakdown else { return }
    cpuCategoryHistory.append(breakdown, limit: maxPoints)
}
```

Keep the aggregate `cpuHistory` because it remains useful independently of category history.

- [ ] **Step 2: Run model and monitor tests**

Run:

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -only-testing:ConnTests/CPUChartStateTests -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
swift test --package-path Packages/ConnPackages --filter MetricParserTests
```

Expected: CPU chart state tests and all 13 parser tests pass.

### Task 3: Interactive CPU legend and multi-line chart

**Files:**
- Modify: `Conn/Conn/Hosts/HostOverviewView.swift`
- Modify: `Conn/Conn/Hosts/MetricTrendChart.swift`
- Create: `Conn/ConnUITests/HostOverviewChartUITests.swift`

- [ ] **Step 1: Write a failing UI interaction test**

```swift
import XCTest

final class HostOverviewChartUITests: XCTestCase {
    func testSystemMetricTogglesChartVisibility() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_DETAIL"] = "1"
        app.launch()

        let systemMetric = app.buttons["cpu.metric.system"]
        XCTAssertTrue(systemMetric.waitForExistence(timeout: 8))
        XCTAssertEqual(systemMetric.value as? String, "visible")

        systemMetric.tap()

        XCTAssertEqual(systemMetric.value as? String, "hidden")
    }
}
```

- [ ] **Step 2: Run the UI test and verify RED**

Run:

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -only-testing:ConnUITests/HostOverviewChartUITests/testSystemMetricTogglesChartVisibility \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Expected: failure because no button has the `cpu.metric.system` identifier.

- [ ] **Step 3: Add view-local selection and metric presentation**

Add to `HostOverviewView`:

```swift
@State private var cpuVisibility = CPUChartVisibility()
```

Add mappings for localized label, fixed color, current numeric value, and history for every `CPUChartMetric`. Use this palette:

```swift
user: Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255)
system: Color(red: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255)
iowait: Color(red: 0xCA / 255, green: 0x8A / 255, blue: 0x04 / 255)
idle: Color(red: 0x7C / 255, green: 0x84 / 255, blue: 0x94 / 255)
nice: Color(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255)
irq: Color(red: 0x93 / 255, green: 0x33 / 255, blue: 0xEA / 255)
softirq: Color(red: 0xDB / 255, green: 0x27 / 255, blue: 0x77 / 255)
steal: Color(red: 0x0D / 255, green: 0x94 / 255, blue: 0x88 / 255)
```

Render each metric as a plain `Button` with a rectangular content shape, minimum 44-point height, identifier `cpu.metric.<rawValue>`, and accessibility value `visible`/`hidden`. Active dot and label use the metric color; hidden dot, label, and numeric value use `.connDim`.

Give every button an explicit localized accessibility label containing both the metric name and state, plus a localized toggle hint:

```swift
.accessibilityLabel(
    String(
        format: visible ? L("%@，已显示") : L("%@，已隐藏"),
        metric.label
    )
)
.accessibilityHint(L("双击切换图表折线"))
```

Attach one selection haptic to changes in `cpuVisibility`:

```swift
.sensoryFeedback(.selection, trigger: cpuVisibility)
```

- [ ] **Step 4: Render only visible series and keep CPU line-only**

Build the CPU series in `CPUChartMetric.allCases` order, filter through `cpuVisibility`, and read values from `viewModel.cpuCategoryHistory[metric]`.

If the series list is empty, show a centered `L("请选择指标")` prompt with accessibility identifier `cpu.chart.empty` in the chart's reserved 132-point area.

Add a shared chart option:

```swift
var fillsSingleSeries: Bool = true
```

Use the area mark only when `isSingle && fillsSingleSeries`; pass `fillsSingleSeries: false` from the CPU chart so a single remaining category still looks like the same line chart mode.

- [ ] **Step 5: Run the UI and model tests and verify GREEN**

Run the Step 2 UI command and Task 1 model-test command.

Expected: both pass.

- [ ] **Step 6: Add and verify the all-hidden empty-state UI test**

Add a second UI test that launches the same demo detail, taps all eight buttons by their stable identifiers, and asserts `app.staticTexts["cpu.chart.empty"]` exists. Run it with the same simulator destination and expect PASS.

### Task 4: Disk contrast and final verification

**Files:**
- Modify: `Conn/Conn/Hosts/HostOverviewView.swift`
- Verify: all files above

- [ ] **Step 1: Set high-contrast disk colors**

Use fixed palette values:

```swift
static let diskRead = Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255)
static let diskWrite = Color(red: 0xEA / 255, green: 0x58 / 255, blue: 0x0C / 255)
```

Keep legend dots and series colors sourced from these same constants.

- [ ] **Step 2: Run formatting and regression checks**

Run:

```bash
git diff --check
swift test --package-path Packages/ConnPackages --filter MetricParserTests
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -only-testing:ConnTests/CPUChartStateTests -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

Expected: no whitespace errors; 13 parser tests and CPU state tests pass.

- [ ] **Step 3: Build for the already-booted simulator**

Run:

```bash
xcodebuild build -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Visual and haptic acceptance**

Use the existing booted iPhone 17 Pro simulator only. Launch the DEBUG app with `CONN_DEMO=1` and `CONN_SMOKE_DETAIL=1`, without shutting down or cloning a simulator. Verify:

- All eight metric cells start active and use distinct colors.
- User blue and System red are immediately distinguishable.
- Tapping a metric dims the cell and removes only its line.
- Tapping again restores the same color and line.
- Source inspection and compilation confirm `.sensoryFeedback(.selection, trigger: cpuVisibility)` is wired to the tested selection state. The simulator UI test verifies exactly one visibility-state transition per tap; actual vibration strength is a physical-device acceptance item and cannot be asserted by the simulator.
- With all metrics hidden, the empty prompt appears without collapsing layout.
- Disk Read blue and Write orange-red are visibly distinct.
