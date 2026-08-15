# Terminal Pan Gesture Arbitration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one-finger terminal scrollback deterministic by disabling SwiftTerm's competing auxiliary pan gestures.

**Architecture:** Add a deterministic pan-ownership policy in `ConnTerminal`, then override UIView's `gestureRecognizerShouldBegin` in `KeybarTerminalView`. No recognizer delegate is replaced and only the native `UIScrollView` pan may begin.

**Tech Stack:** Swift 6, Swift Testing, UIKit, SwiftTerm 1.15.

---

### Task 1: Pan ownership policy

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalPanGesturePolicy.swift`
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalPanGesturePolicyTests.swift`

- [ ] Write failing Swift Testing cases proving the native scroll pan remains allowed and every auxiliary pan is rejected.
- [ ] Run `swift test --package-path Packages/ConnPackages --filter TerminalPanGesturePolicyTests` and verify the missing policy produces the expected failure.
- [ ] Implement `TerminalPanGesturePolicy.shouldBeginPan(isNativeScrollPan:)` so only the native scroll pan is accepted.
- [ ] Run the focused package test and verify it passes.

### Task 2: UIKit integration

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Conn/ConnTests/TerminalLayoutTests.swift`

- [ ] Add failing integration assertions that SwiftTerm's selection and mouse-reporting pans are rejected while the native scroll pan and recognizer delegates remain unchanged.
- [ ] Build/test the integration target and verify failure occurs because auxiliary pans are not yet arbitrated.
- [ ] Override `KeybarTerminalView.gestureRecognizerShouldBegin`, leave all recognizer delegates untouched, and reject every auxiliary pan through the pan-ownership policy.
- [ ] Run the focused integration tests where the existing booted simulator is available; never create or switch simulators.

### Task 3: Regression verification

**Files:**
- No additional production files expected.

- [ ] Run all `ConnTerminalTests`.
- [ ] Run `xcodebuild build -workspace Conn.xcworkspace -scheme Conn` to compile the UIKit integration.
- [ ] Review the diff for accidental changes to native scrolling, mouse reporting, tmux, or user-owned worktree edits.
