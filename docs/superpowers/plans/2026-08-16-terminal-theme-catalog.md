# Terminal Theme Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add distinct light terminal themes, real theme and cursor previews, and theme-driven light/dark terminal chrome without changing persisted theme IDs or the Conn dark default.

**Architecture:** Keep `TerminalTheme` as the only palette model in ConnTerminal and add an explicit appearance plus five built-in light palettes. Keep presentation in the app target: `TerminalSettingsView` binds existing settings while focused SwiftUI preview components render directly from `TerminalTheme` and `TerminalCursorShape`; `TerminalScreen` maps the selected theme appearance to SwiftUI `ColorScheme`. Persistence remains the existing string theme ID, so no database or UserDefaults migration is introduced.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, ConnTerminal/ConnUI, Xcode 17 workspace build.

---

## File structure

- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalTheme.swift`: add theme appearance and the five light palettes; remain UI-framework-neutral.
- Modify `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalThemeTests.swift`: verify IDs, appearance counts, palette uniqueness, contrast, ANSI completeness, and fallback behavior.
- Modify `Conn/Conn/Me/TerminalSettingsView.swift`: group the picker by appearance and replace the segmented cursor picker with the selectable preview control.
- Create `Conn/Conn/Me/TerminalSettingsPreviews.swift`: focused SwiftUI renderers for a theme row, ANSI strip, and three cursor-shape cards. These consume existing models and own no settings or persistence.
- Modify `Conn/Conn/Terminal/TerminalScreen.swift`: derive navigation, keyboard, and view color scheme from the selected theme.
- Modify `Conn/ConnTests/AppWideUIConsistencyTests.swift`: compile-independent presentation boundary checks for grouping, preview content, cursor bindings, and removal of hardcoded dark terminal mode.

Do not edit `Conn/Conn/Localizable.xcstrings`: all labels used by this feature already exist, and that file contains unrelated user-owned changes. Do not modify `SettingsStore` or any database schema.

The worktree already contains unrelated edits in several test and terminal files. For any overlapping file, inspect `git diff` and use `git add -p` to stage only this feature's hunks; never stage the whole dirty file.

### Task 1: Add appearance-aware, contrast-safe theme catalog

**Files:**
- Modify: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalThemeTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalTheme.swift`

- [ ] **Step 1: Expand catalog tests before production code**

Replace the narrow catalog count assertion with tests that encode the complete contract. Add `import Foundation` for `pow`, then add helpers local to the test suite for complete palette signatures and WCAG contrast:

```swift
@Test("内置主题 id、完整配色签名唯一且 ANSI 色完整")
func catalogIsCompleteAndUnique() {
    let themes = TerminalTheme.all

    #expect(themes.count == 13)
    #expect(Set(themes.map(\.id)).count == themes.count)
    #expect(Set(themes.map(paletteSignature)).count == themes.count)
    #expect(themes.allSatisfy { $0.ansi.count == 16 })
}

@Test("主题目录保留全部深色 id 并提供五套浅色主题")
func catalogContainsExpectedAppearances() {
    let darkIDs = Set(TerminalTheme.all.filter { $0.appearance == .dark }.map(\.id))
    let lightIDs = Set(TerminalTheme.all.filter { $0.appearance == .light }.map(\.id))

    #expect(darkIDs == [
        "conn", "dracula", "solarized-dark", "one-dark", "nord",
        "gruvbox-dark", "tokyo-night", "catppuccin-mocha",
    ])
    #expect(lightIDs == [
        "conn-light", "solarized-light", "gruvbox-light", "one-light",
        "catppuccin-latte",
    ])
}

@Test("全部主题前景与背景至少满足 WCAG AA 正文对比度")
func themesHaveReadableForegroundContrast() {
    for theme in TerminalTheme.all {
        #expect(contrast(theme.foreground, theme.background) >= 4.5, "\(theme.id) 对比度不足")
    }
}

@Test("未知主题仍回退到深色 Conn")
func unknownThemeFallsBackToConn() {
    let fallback = TerminalTheme.theme(id: "missing")
    #expect(fallback.id == TerminalTheme.conn.id)
    #expect(fallback.appearance == .dark)
}

private func paletteSignature(_ theme: TerminalTheme) -> [UInt8] {
    ([theme.background, theme.foreground, theme.cursor] + theme.ansi).flatMap {
        [$0.r, $0.g, $0.b]
    }
}

private func contrast(_ lhs: TerminalTheme.RGB, _ rhs: TerminalTheme.RGB) -> Double {
    let high = max(relativeLuminance(lhs), relativeLuminance(rhs))
    let low = min(relativeLuminance(lhs), relativeLuminance(rhs))
    return (high + 0.05) / (low + 0.05)
}

private func relativeLuminance(_ color: TerminalTheme.RGB) -> Double {
    func component(_ byte: UInt8) -> Double {
        let value = Double(byte) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * component(color.r)
        + 0.7152 * component(color.g)
        + 0.0722 * component(color.b)
}
```

- [ ] **Step 2: Run the focused test to verify RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter TerminalThemeTests
```

Expected: compile failure because `TerminalTheme.Appearance` and `appearance` do not exist, followed by count/ID failures once the type is added but light themes are not.

- [ ] **Step 3: Add appearance to the single theme model**

In `TerminalTheme.swift`, add the nested enum and property, and require appearance in the initializer:

```swift
public enum Appearance: String, Sendable, Equatable, CaseIterable {
    case dark
    case light
}

public let appearance: Appearance

public init(
    id: String,
    name: String,
    appearance: Appearance,
    background: RGB,
    foreground: RGB,
    cursor: RGB,
    ansi: [RGB]
) {
    self.id = id
    self.name = name
    self.appearance = appearance
    self.background = background
    self.foreground = foreground
    self.cursor = cursor
    self.ansi = ansi
}
```

Pass `appearance: .dark` to every existing theme. Preserve every existing ID, name, and color byte exactly.

- [ ] **Step 4: Add the five light palettes to the catalog**

Append these declarations after the matching dark families and include them in `all` after the eight existing entries. Keep the first catalog item `.conn`, preserving the current default and list ordering of existing themes.

```swift
static let connLight = TerminalTheme(
    id: "conn-light", name: "Conn Light", appearance: .light,
    background: RGB(hex: "F7F8FC"), foreground: RGB(hex: "25283A"), cursor: RGB(hex: "6C63FF"),
    ansi: [
        RGB(hex: "25283A"), RGB(hex: "D92D4F"), RGB(hex: "16835D"), RGB(hex: "9A6700"),
        RGB(hex: "3451D1"), RGB(hex: "7C3AED"), RGB(hex: "087E8B"), RGB(hex: "D9DDEA"),
        RGB(hex: "667085"), RGB(hex: "E5484D"), RGB(hex: "219B69"), RGB(hex: "B7791F"),
        RGB(hex: "4F67E8"), RGB(hex: "9355E8"), RGB(hex: "1696A7"), RGB(hex: "FFFFFF"),
    ]
)

static let solarizedLight = TerminalTheme(
    id: "solarized-light", name: "Solarized Light", appearance: .light,
    background: RGB(hex: "FDF6E3"), foreground: RGB(hex: "586E75"), cursor: RGB(hex: "657B83"),
    ansi: [
        RGB(hex: "073642"), RGB(hex: "DC322F"), RGB(hex: "859900"), RGB(hex: "B58900"),
        RGB(hex: "268BD2"), RGB(hex: "D33682"), RGB(hex: "2AA198"), RGB(hex: "EEE8D5"),
        RGB(hex: "002B36"), RGB(hex: "CB4B16"), RGB(hex: "586E75"), RGB(hex: "657B83"),
        RGB(hex: "839496"), RGB(hex: "6C71C4"), RGB(hex: "93A1A1"), RGB(hex: "FDF6E3"),
    ]
)

static let gruvboxLight = TerminalTheme(
    id: "gruvbox-light", name: "Gruvbox Light", appearance: .light,
    background: RGB(hex: "FBF1C7"), foreground: RGB(hex: "3C3836"), cursor: RGB(hex: "D65D0E"),
    ansi: [
        RGB(hex: "3C3836"), RGB(hex: "CC241D"), RGB(hex: "98971A"), RGB(hex: "D79921"),
        RGB(hex: "458588"), RGB(hex: "B16286"), RGB(hex: "689D6A"), RGB(hex: "7C6F64"),
        RGB(hex: "928374"), RGB(hex: "9D0006"), RGB(hex: "79740E"), RGB(hex: "B57614"),
        RGB(hex: "076678"), RGB(hex: "8F3F71"), RGB(hex: "427B58"), RGB(hex: "F9F5D7"),
    ]
)

static let oneLight = TerminalTheme(
    id: "one-light", name: "One Light", appearance: .light,
    background: RGB(hex: "FAFAFA"), foreground: RGB(hex: "383A42"), cursor: RGB(hex: "526FFF"),
    ansi: [
        RGB(hex: "383A42"), RGB(hex: "E45649"), RGB(hex: "50A14F"), RGB(hex: "C18401"),
        RGB(hex: "4078F2"), RGB(hex: "A626A4"), RGB(hex: "0184BC"), RGB(hex: "A0A1A7"),
        RGB(hex: "696C77"), RGB(hex: "CA1243"), RGB(hex: "3F953A"), RGB(hex: "B76B01"),
        RGB(hex: "2F6FDB"), RGB(hex: "8E2A8C"), RGB(hex: "007FAD"), RGB(hex: "FFFFFF"),
    ]
)

static let catppuccinLatte = TerminalTheme(
    id: "catppuccin-latte", name: "Catppuccin Latte", appearance: .light,
    background: RGB(hex: "EFF1F5"), foreground: RGB(hex: "4C4F69"), cursor: RGB(hex: "8839EF"),
    ansi: [
        RGB(hex: "5C5F77"), RGB(hex: "D20F39"), RGB(hex: "40A02B"), RGB(hex: "DF8E1D"),
        RGB(hex: "1E66F5"), RGB(hex: "EA76CB"), RGB(hex: "179299"), RGB(hex: "ACB0BE"),
        RGB(hex: "6C6F85"), RGB(hex: "D20F39"), RGB(hex: "40A02B"), RGB(hex: "DF8E1D"),
        RGB(hex: "1E66F5"), RGB(hex: "EA76CB"), RGB(hex: "179299"), RGB(hex: "BCC0CC"),
    ]
)
```

- [ ] **Step 5: Run focused tests to verify GREEN**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter TerminalThemeTests
```

Expected: all `TerminalThemeTests` pass, including 13 unique themes, eight dark IDs, five light IDs, and all contrast ratios at least 4.5.

- [ ] **Step 6: Commit the domain slice**

```bash
git add -p Packages/ConnPackages/Sources/ConnTerminal/TerminalTheme.swift Packages/ConnPackages/Tests/ConnTerminalTests/TerminalThemeTests.swift
git commit -m "feat: add light terminal theme catalog"
```

### Task 2: Render grouped theme previews from the domain catalog

**Files:**
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`
- Create: `Conn/Conn/Me/TerminalSettingsPreviews.swift`
- Modify: `Conn/Conn/Me/TerminalSettingsView.swift`

- [ ] **Step 1: Add failing presentation boundary tests**

Add a test that reads both settings source files and verifies the intended data flow rather than pixel details:

```swift
@Test("终端主题按明暗分组并展示真实颜色预览")
func terminalThemesUseGroupedPalettePreviews() throws {
    let settings = try appSource("Me/TerminalSettingsView.swift")
    let previews = try appSource("Me/TerminalSettingsPreviews.swift")

    #expect(settings.contains("themes(appearance: .dark)"))
    #expect(settings.contains("themes(appearance: .light)"))
    #expect(settings.contains("Section(L(\"深色\"))"))
    #expect(settings.contains("Section(L(\"浅色\"))"))
    #expect(settings.contains("TerminalThemePickerLabel(theme: theme)"))
    #expect(previews.contains("Text(\"Aa\")"))
    #expect(previews.contains("theme.background"))
    #expect(previews.contains("theme.foreground"))
    #expect(previews.contains("theme.cursor"))
    #expect(previews.contains("ForEach(Array(theme.ansi.prefix(8).enumerated())"))
}
```

This source-boundary test complements compilation; it does not attempt snapshot testing.

- [ ] **Step 2: Verify RED**

Run this simulator-independent source contract:

```bash
zsh -c 'rg -Fq "themes(appearance: .dark)" Conn/Conn/Me/TerminalSettingsView.swift && rg -Fq "themes(appearance: .light)" Conn/Conn/Me/TerminalSettingsView.swift && test -f Conn/Conn/Me/TerminalSettingsPreviews.swift && rg -Fq "Text(\"Aa\")" Conn/Conn/Me/TerminalSettingsPreviews.swift && rg -Fq "theme.ansi.prefix(8)" Conn/Conn/Me/TerminalSettingsPreviews.swift'
```

Expected: exit 1 because `TerminalSettingsPreviews.swift`, appearance grouping, and `TerminalThemePickerLabel` do not exist. Do not boot or switch simulators.

- [ ] **Step 3: Create the theme preview renderer**

Create `TerminalSettingsPreviews.swift`. Add one file-local RGB-to-SwiftUI conversion and a focused `TerminalThemePickerLabel` that renders:

- a 56×32 rounded swatch using `theme.background`;
- foreground `Aa` in a monospaced semibold font;
- a small cursor rectangle using `theme.cursor`;
- an eight-segment ANSI strip from `theme.ansi.prefix(8)`;
- the theme name outside the swatch;
- `.accessibilityElement(children: .ignore)` with the theme name as its label, so decorative color elements are not announced individually.

Use `ConnSpacing` and `ConnRadius`; do not copy palette values into this view. The essential shape is:

```swift
struct TerminalThemePickerLabel: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: ConnSpacing.sm) {
            VStack(spacing: 3) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                        .fill(terminalColor(theme.background))
                    Text("Aa")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(terminalColor(theme.foreground))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    Rectangle()
                        .fill(terminalColor(theme.cursor))
                        .frame(width: 5, height: 13)
                        .padding(4)
                }
                .frame(width: 56, height: 32)

                HStack(spacing: 1) {
                    ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, rgb in
                        Rectangle().fill(terminalColor(rgb))
                    }
                }
                .frame(width: 56, height: 4)
                .clipShape(.capsule)
            }
            Text(theme.name)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
    }
}
```

- [ ] **Step 4: Group the picker without changing persisted values**

In `TerminalSettingsView`, keep selection bound to `$settings.terminalThemeID`. Replace the flat `ForEach` with two `Section`s whose rows remain tagged by `theme.id`:

```swift
Picker(selection: $settings.terminalThemeID) {
    Section(L("深色")) {
        ForEach(themes(appearance: .dark)) { theme in
            TerminalThemePickerLabel(theme: theme).tag(theme.id)
        }
    }
    Section(L("浅色")) {
        ForEach(themes(appearance: .light)) { theme in
            TerminalThemePickerLabel(theme: theme).tag(theme.id)
        }
    }
} label: {
    Label(L("主题"), systemImage: "paintpalette")
}
```

Add only this catalog filter helper:

```swift
private func themes(appearance: TerminalTheme.Appearance) -> [TerminalTheme] {
    TerminalTheme.all.filter { $0.appearance == appearance }
}
```

Delete the old `themeLabel` three-circle implementation. Do not add storage fields or cache a second catalog.

- [ ] **Step 5: Verify the grouped picker compiles**

Run:

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing
```

Expected: `BUILD SUCCEEDED`. This compiles app tests but does not claim they executed.

- [ ] **Step 6: Commit the grouped preview slice**

```bash
git add Conn/Conn/Me/TerminalSettingsPreviews.swift
git add -p Conn/Conn/Me/TerminalSettingsView.swift Conn/ConnTests/AppWideUIConsistencyTests.swift
git commit -m "feat: preview terminal theme palettes"
```

### Task 3: Replace the cursor segmented control with selectable shape previews

**Files:**
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`
- Modify: `Conn/Conn/Me/TerminalSettingsPreviews.swift`
- Modify: `Conn/Conn/Me/TerminalSettingsView.swift`

- [ ] **Step 1: Add the failing cursor preview contract**

Add this test beside the theme-preview test:

```swift
@Test("终端光标设置显示三种真实形状并直接绑定现有枚举")
func terminalCursorUsesSelectableShapePreviews() throws {
    let settings = try appSource("Me/TerminalSettingsView.swift")
    let previews = try appSource("Me/TerminalSettingsPreviews.swift")

    #expect(settings.contains("TerminalCursorShapePicker("))
    #expect(settings.contains("selection: $settings.terminalCursorShape"))
    #expect(settings.contains("theme: selectedTheme"))
    #expect(settings.contains("Toggle(isOn: $settings.terminalCursorBlinking)"))
    #expect(!settings.contains(".pickerStyle(.segmented)"))
    #expect(previews.contains("ForEach(TerminalCursorShape.allCases)"))
    #expect(previews.contains("selection = shape"))
    #expect(previews.contains("case .block:"))
    #expect(previews.contains("case .bar:"))
    #expect(previews.contains("case .underline:"))
    #expect(previews.contains(".frame(minHeight: 44)"))
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
zsh -c 'rg -Fq "TerminalCursorShapePicker(" Conn/Conn/Me/TerminalSettingsView.swift && rg -Fq "ForEach(TerminalCursorShape.allCases)" Conn/Conn/Me/TerminalSettingsPreviews.swift && ! rg -Fq ".pickerStyle(.segmented)" Conn/Conn/Me/TerminalSettingsView.swift'
```

Expected: exit 1 because the implementation still uses the segmented picker and has no shape preview control.

- [ ] **Step 3: Implement a binding-based cursor preview control**

In `TerminalSettingsPreviews.swift`, add:

```swift
struct TerminalCursorShapePicker: View {
    @Binding var selection: TerminalCursorShape
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: ConnSpacing.xs) {
            ForEach(TerminalCursorShape.allCases) { shape in
                Button {
                    selection = shape
                } label: {
                    TerminalCursorShapeCard(
                        shape: shape,
                        theme: theme,
                        isSelected: selection == shape
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == shape ? .isSelected : [])
            }
        }
    }
}
```

Implement `TerminalCursorShapeCard` with a terminal glyph cell using the active theme background and foreground. Overlay a cursor rectangle whose geometry is exhaustive over the existing enum:

```swift
@ViewBuilder
private var cursor: some View {
    switch shape {
    case .block:
        Rectangle().frame(width: 12, height: 18)
    case .bar:
        Rectangle().frame(width: 2, height: 18)
    case .underline:
        Rectangle().frame(width: 12, height: 2)
    }
}
```

Anchor block and bar to the glyph cell center; anchor underline to its bottom. Use `theme.cursor` for cursor fill, `theme.background` for the terminal cell, and `theme.foreground` for a monospaced glyph. Put the existing localized shape label below the cell. Give each card `.frame(maxWidth: .infinity).frame(minHeight: 44)`, a selected `.connAccent` stroke/fill treatment, and a combined accessibility label/value. Keep previews static even when blinking is enabled.

- [ ] **Step 4: Bind the control to current settings and selected theme**

In `TerminalSettingsView`, add:

```swift
private var selectedTheme: TerminalTheme {
    TerminalTheme.theme(id: settings.terminalThemeID)
}
```

Replace the segmented picker with:

```swift
VStack(alignment: .leading, spacing: ConnSpacing.xs) {
    Label(L("光标形状"), systemImage: "cursorarrow")
    TerminalCursorShapePicker(
        selection: $settings.terminalCursorShape,
        theme: selectedTheme
    )
}
```

Retain the existing blinking toggle immediately after it. Remove the old view-local `cursorLabel` and RGB conversion helpers once all preview rendering lives in `TerminalSettingsPreviews.swift`.

- [ ] **Step 5: Verify cursor preview compilation**

Run:

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing
```

Expected: `BUILD SUCCEEDED`; all three enum cases compile exhaustively and no persistence API changes are required.

- [ ] **Step 6: Commit the cursor preview slice**

```bash
git add -p Conn/Conn/Me/TerminalSettingsView.swift Conn/Conn/Me/TerminalSettingsPreviews.swift Conn/ConnTests/AppWideUIConsistencyTests.swift
git commit -m "feat: preview terminal cursor shapes"
```

### Task 4: Drive terminal system appearance from the selected theme

**Files:**
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`

- [ ] **Step 1: Add the failing terminal appearance boundary test**

```swift
@Test("终端系统明暗外观跟随当前终端主题")
func terminalScreenUsesThemeAppearance() throws {
    let source = try appSource("Terminal/TerminalScreen.swift")

    #expect(source.contains("settings.terminalConfiguration.theme.appearance"))
    #expect(source.contains("private var terminalColorScheme: ColorScheme"))
    #expect(source.contains(".toolbarColorScheme(terminalColorScheme, for: .navigationBar)"))
    #expect(source.contains(".preferredColorScheme(terminalColorScheme)"))
    #expect(!source.contains(".toolbarColorScheme(.dark, for: .navigationBar)"))
    #expect(!source.contains(".preferredColorScheme(.dark)"))
}
```

- [ ] **Step 2: Verify RED**

Run this simulator-independent source contract:

```bash
zsh -c 'rg -Fq "settings.terminalConfiguration.theme.appearance" Conn/Conn/Terminal/TerminalScreen.swift && rg -Fq ".preferredColorScheme(terminalColorScheme)" Conn/Conn/Terminal/TerminalScreen.swift && ! rg -Fq ".preferredColorScheme(.dark)" Conn/Conn/Terminal/TerminalScreen.swift'
```

Expected: exit 1 because `TerminalScreen` still hardcodes dark appearance.

- [ ] **Step 3: Add one appearance-to-SwiftUI mapping at the app boundary**

Add this computed property to `TerminalScreen`:

```swift
private var terminalColorScheme: ColorScheme {
    switch settings.terminalConfiguration.theme.appearance {
    case .dark: .dark
    case .light: .light
    }
}
```

Replace only the two hardcoded modifiers:

```swift
.toolbarColorScheme(terminalColorScheme, for: .navigationBar)
// ...
.preferredColorScheme(terminalColorScheme)
```

Do not change the app-global appearance setting. The existing terminal theme still supplies viewport/foreground/cursor/ANSI colors through `TerminalConfiguration`; the local preferred scheme makes navigation, keybar dynamic assets, and keyboard match it.

- [ ] **Step 4: Verify terminal appearance compilation**

Run:

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing
```

Expected: `BUILD SUCCEEDED` and no hardcoded terminal dark scheme remains.

- [ ] **Step 5: Commit the appearance slice**

```bash
git add -p Conn/Conn/Terminal/TerminalScreen.swift Conn/ConnTests/AppWideUIConsistencyTests.swift
git commit -m "feat: match terminal chrome to theme"
```

### Task 5: Full regression verification and visual acceptance

**Files:**
- Verify only; update this plan's checkboxes as tasks complete.

- [ ] **Step 1: Run all package tests**

```bash
swift test --package-path Packages/ConnPackages
```

Expected: all suites pass, including `TerminalThemeTests`.

- [ ] **Step 2: Compile the application and all app tests**

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing
```

Expected: `BUILD SUCCEEDED`.

Re-run the three simulator-independent `zsh -c` source contracts from Tasks 2–4; expected exit 0 for each. This verifies their behavior boundaries even when app tests cannot execute.

- [ ] **Step 3: Run app tests only if the user's existing simulator is available**

Read the current simulator state without starting, cloning, switching, restarting, or stopping any device. If CoreSimulatorService exposes exactly the already-booted user device, run tests with that exact UDID:

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,id=<CURRENT_BOOTED_UDID>'
```

Expected: tests pass. If CoreSimulatorService or that device is unavailable, stop simulator operations and report package test plus generic build evidence; do not substitute another destination.

- [ ] **Step 4: Perform visual acceptance on that same simulator when available**

Verify in Terminal Settings:

- dark and light sections both appear;
- theme rows show distinguishable canvas, `Aa`, cursor, and ANSI strip previews;
- the five light themes remain readable;
- cursor cards show actual block, bar, and underline geometry and selection updates immediately without animation;
- blinking stays a separate toggle;
- opening one dark and one light terminal switches navigation, terminal canvas, keybar, and software keyboard coherently.

- [ ] **Step 5: Check patch hygiene**

```bash
git diff --check
git status --short --branch
```

Expected: no whitespace errors. Confirm `Conn/Conn/Localizable.xcstrings` was not staged or modified by this work, and that unrelated pre-existing terminal changes remain preserved.
