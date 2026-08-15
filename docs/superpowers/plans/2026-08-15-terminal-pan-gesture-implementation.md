# Terminal Pan Gesture Arbitration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore one-finger vertical terminal scrollback without removing text selection or remote TUI mouse input.

**Architecture:** Add a deterministic direction policy in `ConnTerminal`, then override UIView's `gestureRecognizerShouldBegin` in `KeybarTerminalView` for SwiftTerm-added auxiliary pan recognizers. No recognizer delegate is replaced, native scrolling is never modified, and remote mouse mode bypasses Conn arbitration.

**Tech Stack:** Swift 6, Swift Testing, UIKit, SwiftTerm 1.15.

---

### Task 1: Direction policy

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalPanGesturePolicy.swift`
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalPanGesturePolicyTests.swift`

- [ ] Write failing Swift Testing cases for vertical, horizontal, balanced, and remote mouse-mode bypass. The policy is deliberately one-shot: it receives only the initial velocity, so later movement cannot reverse an accepted selection drag.
- [ ] Run `swift test --package-path Packages/ConnPackages --filter TerminalPanGesturePolicyTests` and verify the missing policy produces the expected failure.
- [ ] Implement `TerminalPanGesturePolicy.shouldBeginAuxiliaryPan(initialVelocity:remoteMouseReportingEnabled:)` using remote-mouse bypass or `abs(x) >= abs(y)`.
- [ ] Run the focused package test and verify it passes.

### Task 2: UIKit integration

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Conn/ConnTests/TerminalLayoutTests.swift`

- [ ] Add failing integration assertions that SwiftTerm's selection pan is routed through Conn's UIView begin hook while the native scroll pan and a pan with an existing delegate remain unchanged. Feed SwiftTerm's mouse-enable escape sequence and assert a vertical auxiliary pan is accepted while selection remains active, proving the view passes live `terminal.mouseMode` into the policy.
- [ ] Build/test the integration target and verify failure occurs because auxiliary pans are not yet arbitrated.
- [ ] Override `KeybarTerminalView.gestureRecognizerShouldBegin`, leave all recognizer delegates untouched, and route auxiliary pans through an internal `shouldBeginAuxiliaryPan(initialVelocity:)` method that reads the current terminal mouse mode and invokes the direction policy.
- [ ] Run the focused integration tests where the existing booted simulator is available; never create or switch simulators.

### Task 3: Regression verification

**Files:**
- No additional production files expected.

- [ ] Run all `ConnTerminalTests`.
- [ ] Run `xcodebuild build -workspace Conn.xcworkspace -scheme Conn` to compile the UIKit integration.
- [ ] Review the diff for accidental changes to native scrolling, mouse reporting, tmux, or user-owned worktree edits.
