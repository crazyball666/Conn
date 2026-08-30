# tmux Viewport Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tmux terminals preserve output, use tmux-native history scrolling, resize from the visible SwiftTerm viewport exactly once, and fail or recover predictably during attachment startup.

**Architecture:** Keep the existing PTY + Control Mode design. The PTY remains the only renderer and visible size owner; Control Mode remains the serialized command/state channel. Add only two provider-neutral behaviors (`historyOwnership` and `viewportAuthority`) so the existing terminal host can distinguish local transcripts from remote-authoritative tmux viewports. Do not introduce a new provider framework or alter Zellij behavior.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI/UIKit, SwiftTerm, Citadel SSH, tmux Control Mode, XCUITest on the connected physical device.

---

### Task 1: Make persistent scroll ownership explicit

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalInteraction.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteraction.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalInteractionTests.swift`
- Test: `Conn/ConnUITests/TerminalTmuxScrollUITests.swift`

- [x] Add a failing test proving a tmux attachment consumes vertical scroll even when its current history count is zero.
- [x] Run the focused test and verify it fails because routing falls back to the local SwiftTerm scroll view.
- [x] Add `PersistentTerminalHistoryOwnership` with `.local` and `.provider`, expose it from the interaction facet with a compatibility default, and route provider-owned history without consulting `historyAvailable`.
- [x] Disable only native local scroll for provider-owned history; keep selection and plain PTY scrolling unchanged.
- [x] Verify on the physical device that the first swipe enters tmux copy mode without opening local history or showing an unsupported warning.

### Task 2: Establish one viewport geometry source

**Files:**
- Modify: `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Test: `Conn/ConnTests/TerminalLayoutTests.swift`

- [x] Add a failing geometry test proving horizontal content padding is included before SwiftTerm computes columns.
- [x] Run the test and verify the current post-layout `resize()` path fails the one-pass expectation.
- [x] Let SwiftTerm's normal layout calculation account for the horizontal viewport inset.
- [x] Remove `KeybarTerminalView`'s post-layout public `resize()` call and preserve only visual content offset clamping.
- [x] Run layout tests and verify one effective size update per layout change.

### Task 3: Make the visible tmux PTY own remote size and redraw

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlRuntime.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalTranscript.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlRuntimeTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProviderTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalTranscriptTests.swift`

- [x] Add failing tests proving a new tmux PTY starts hidden, hiding enables `ignore-size`, showing disables it, and reattaching does not replay stale raw ANSI as authoritative state.
- [x] Run each focused test and verify the expected failure.
- [x] Replace attachment-count size arbitration with explicit visible/hidden client flag updates targeted to the exact data client.
- [x] Keep Control Mode `no-output` and remove it from viewport sizing decisions.
- [x] For tmux re-presentation, reset the local renderer, apply the measured viewport size, and request one full redraw; keep transcript replay for ordinary PTY.
- [x] Verify output, page reopen, and background/foreground recovery on the physical device.

### Task 4: Bound attachment startup and verify the real workflow

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProviderTests.swift`
- Test: `Conn/ConnUITests/TerminalTmuxScrollUITests.swift`

- [x] Add failing tests proving missing remote sessions are classified as `remoteObjectMissing` and partial startup resources are rolled back.
- [x] Run the focused tests and verify the sequential startup delay and rollback gap.
- [x] Open the independently bounded data and Control Mode components concurrently, bind only after both are ready, and keep the existing rollback transaction.
- [x] Keep the existing component timeouts and retry limit; do not add a second generic deadline layer.
- [x] Run package unit tests, build the app for device `00008130-000A21003A2B803A`, then run the tmux XCUITest on that same device with parallel testing disabled.
- [x] On the physical device verify: generated scrollback, first copy-mode swipe, rapid window switching, keyboard-open pane operations, page close/reopen, and background/foreground recovery.
