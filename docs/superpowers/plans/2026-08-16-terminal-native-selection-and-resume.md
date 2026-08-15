# Terminal Native Selection and Foreground Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore native iOS terminal text selection, remove canvas-floating advanced controls, and preserve healthy PTY/tmux sessions when the app returns from the background.

**Architecture:** Add a read-only SSH pool-health value and a pure foreground-recovery planner, then let the existing coordinator reconnect only affirmative candidates with a two-task concurrency bound. Keep provider-neutral reconnect descriptors as the only tmux restoration mechanism. Move advanced interaction actions into `TerminalKeybar`, and make `TerminalReviewTextView` own native edit-menu presentation and selection handles.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, UIKit (`UITextView`, `UIEditMenuInteraction`), ConnSSH, ConnTerminal, SwiftTerm

---

## File Map

- Create `Packages/ConnPackages/Sources/ConnTerminal/TerminalForegroundRecoveryPolicy.swift`: pure candidate selection and ordering.
- Modify `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`: expose non-mutating pooled-session health.
- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`: use policy and bounded recovery.
- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`: remove canvas actions, route long press ahead of pointer mode, and pass tools into keybar.
- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalKeybar.swift`: add one advanced-tools menu keycap.
- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalReviewTextView.swift`: native word selection and edit menu; remove floating close button.
- Create `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalReviewSelectionPolicyTests.swift`: executable Foundation-only selection/action behavior.
- Modify `Conn/Conn/Terminal/TerminalScreen.swift`: delayed centered reconnect notice.
- Modify package/app tests listed below; do not modify `Conn/Conn/Localizable.xcstrings`.

### Task 1: Read-only SSH pool health

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`
- Test: `Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift`

- [ ] **Step 1: Write failing health-query tests**

Add tests for `.absent`, `.connected`, and `.disconnected`. Create a session with `MockSSHTransport`, cast it to the test-visible `MockSSHSession`, call `simulateDisconnect()`, and verify the query reports dead without creating or evicting another entry.

```swift
#expect(await manager.pooledSessionHealth(for: host) == .absent)
let session = try await manager.session(for: host)
#expect(await manager.pooledSessionHealth(for: host) == .connected)
(session as? MockSSHSession)?.simulateDisconnect()
#expect(await manager.pooledSessionHealth(for: host) == .disconnected)
#expect(await manager.activeCount == 1)
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path Packages/ConnPackages --filter ConnectionManagerTests`

Expected: compile failure because `SSHPooledSessionHealth` / `pooledSessionHealth(for:)` do not exist.

- [ ] **Step 3: Implement the minimal query**

Add public `SSHPooledSessionHealth` cases `.absent`, `.connecting`, `.connected`, `.disconnected`. Switch over the private pool entry without changing it:

```swift
public func pooledSessionHealth(for host: ConnKit.Host) -> SSHPooledSessionHealth {
    switch entries[poolKey(for: host)] {
    case nil: .absent
    case .connecting: .connecting
    case let .connected(session): session.isConnected ? .connected : .disconnected
    }
}
```

- [ ] **Step 4: Verify GREEN**

Run the same filtered tests; expected PASS.

### Task 2: Health-aware foreground recovery

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalForegroundRecoveryPolicy.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionCoordinatorTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalForegroundRecoveryPolicyTests.swift`

- [ ] **Step 1: Write failing pure-policy tests**

Cover:

- connected + connected/absent/connecting pool health is preserved;
- connected + disconnected pool health is recovered;
- disconnected/reconnecting tabs are recovered regardless of pool health;
- the current tab ID sorts first and other candidates retain most-recently-used order.

The policy returns tab IDs only and performs no I/O.

- [ ] **Step 2: Replace the old coordinator regression test**

Replace `backgroundResumeReconnectsAllSessions` with three complete fixtures. The healthy case launches one tab, saves its generation, resumes after 31 seconds, and asserts the stored tab remains connected at the same generation:

```swift
@Test("健康终端从后台返回时保持原 generation")
func backgroundResumePreservesHealthySession() async {
    let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
    let coordinator = TerminalSessionCoordinator(
        hostRepository: TerminalHostRepository(hosts: [host]),
        connectionManager: ConnectionManager(transport: MockSSHTransport())
    )
    guard case let .success(tab) = await coordinator.launch(
        .init(host: host, policy: .createNew, source: .shell)
    ) else {
        Issue.record("初次创建应成功")
        return
    }

    await coordinator.resumeAfterBackground(idleFor: 31)

    #expect(coordinator.store.tab(id: tab.id)?.generation == tab.generation)
    #expect(coordinator.store.tab(id: tab.id)?.status == .connected)
}
```

Extract the arrangement above into a suite helper `launchTab(using:) async -> (TerminalSessionCoordinator, TerminalTab)` that constructs the same host/repository/coordinator, launches exactly one shell tab, and records a test issue plus terminates the test if launch fails. The explicit-disconnect case calls that complete helper, marks the tab disconnected, resumes, and asserts `generation == tab.generation + 1` and `.connected`.

```swift
@Test("已断开的终端从后台返回时恢复")
func backgroundResumeRecoversDisconnectedSession() async {
    let (coordinator, tab) = await launchTab(using: MockSSHTransport())
    coordinator.store.updateStatus(tab.id, to: .disconnected(message: nil))
    await coordinator.resumeAfterBackground(idleFor: 31)
    #expect(coordinator.store.tab(id: tab.id)?.generation == tab.generation + 1)
    #expect(coordinator.store.tab(id: tab.id)?.status == .connected)
}
```

The dead-transport case uses a private `ControllableTerminalTransport` whose `connect` stores a `ControllableTerminalSession`. The session implements `SSHSession`, returns a mock shell, and exposes `simulateDisconnect()` that changes `isConnected` to false. After launch, mark that exact pooled session dead, resume, then assert the tab advances one generation and returns to `.connected`:

```swift
@Test("连接池确认死亡时恢复仍显示 connected 的终端")
func backgroundResumeRecoversAffirmativelyDeadTransport() async {
    let transport = ControllableTerminalTransport()
    let (coordinator, tab) = await launchTab(using: transport)
    guard let session = transport.latestSession else {
        Issue.record("transport 应记录创建的池化会话")
        return
    }
    session.simulateDisconnect()
    await coordinator.resumeAfterBackground(idleFor: 31)
    #expect(coordinator.store.tab(id: tab.id)?.generation == tab.generation + 1)
    #expect(coordinator.store.tab(id: tab.id)?.status == .connected)
}
```

Use a test transport that exposes its created session for the dead-transport case. Assert status and generation, not implementation call counts.

- [ ] **Step 3: Verify RED**

Run: `swift test --package-path Packages/ConnPackages --filter TerminalForegroundRecoveryPolicyTests`

Then run: `swift test --package-path Packages/ConnPackages --filter TerminalSessionCoordinatorTests.backgroundResume`

Expected: missing policy compile failure first; after adding test scaffolding, existing unconditional reconnect fails the healthy-generation assertion.

- [ ] **Step 4: Implement the pure planner**

Define a Sendable input containing `id`, `status`, `poolHealth`, and `lastUsedAt`. Use an exhaustive status/health switch. Sort the current tab before candidates, then descending `lastUsedAt`, then stable ID for deterministic ties.

- [ ] **Step 5: Implement bounded coordinator recovery**

Keep `idleFor > 30`. Resolve each tab's host with `try? hostRepository.host(id:)`; if lookup throws or returns nil, skip that tab without changing its status. Query `ConnectionManager.pooledSessionHealth(for:)`; create candidates; execute existing `reconnect(_:)` with at most two tasks in flight. Enqueue the current tab first. Ignore one failure and continue other candidates; existing reconnect logic publishes per-tab status.

Do not call `invalidateAll`, do not write probe bytes, and do not special-case tmux/provider IDs.

- [ ] **Step 6: Verify GREEN**

Run both filtered suites; expected PASS.

### Task 3: Native review selection and advanced tools placement

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalReviewTextView.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalKeybar.swift`
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalReviewSelectionPolicyTests.swift`
- Test: `Conn/ConnTests/TerminalLayoutTests.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Write failing interaction tests**

First create `TerminalReviewSelectionPolicyTests.swift` with tests for UTF-16 word selection over `hello world`, Select All range, Copy returning only selected text, and Done returning no clipboard effect. These tests must reference the not-yet-created production `TerminalReviewSelectionPolicy`, so the filtered command fails to compile during RED rather than silently matching zero tests.

Update `TerminalLayoutTests` to assert:

- selection long press begins even when `shouldBeginDirectPointer` returns true;
- review contains no close button;
- review installs one `UIEditMenuInteraction`;
- displaying `hello world` at an offset inside `hello` selects the complete word;
- Select All covers all UTF-16 text;
- no display path invokes an injected clipboard writer before an explicit Copy action;
- explicit Copy invokes the writer with the selected text and then calls `onClose`;
- Done calls `onClose` without invoking the writer;
- a tap outside the selected UTF-16 range calls `onClose`, while a tap inside preserves review.

Update source-boundary tests to assert `TerminalHostingView` no longer has `terminalActions`, `terminal.pointerMode`, or `terminal.actions`, while `TerminalKeybar` contains `terminal.keybar.tools`.

- [ ] **Step 2: Verify RED with executable package/static contracts, then compile app tests**

CoreSimulatorService is currently unavailable and project constraints prohibit creating or switching devices. Execute the UIKit-independent selection-range/action-policy tests in `ConnTerminalTests`, then use a one-off source contract as the executable RED check for UIKit wiring:

Run: `swift test --package-path Packages/ConnPackages --filter TerminalReviewSelectionPolicyTests`

Expected: compile failure because the pure selection/action policy does not exist.

Run:

```bash
zsh -c '! rg -Eq "terminalActions|terminal.pointerMode|terminal.actions" Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift && rg -Fq "terminal.keybar.tools" Packages/ConnPackages/Sources/ConnTerminal/TerminalKeybar.swift'
```

Expected before implementation: exit 1 because floating actions still exist and keybar tools do not.

Then compile all UIKit tests:

`xcodebuild -workspace Conn.xcworkspace -scheme Conn -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing`

Expected: compile/test-source failure until the new review/menu API and keybar arguments exist. Do not claim these UIKit tests executed. If CoreSimulatorService later exposes exactly one already-booted device, execute them only on that UDID; otherwise report compilation plus the package/static checks.

- [ ] **Step 3: Implement native review menu**

Add a Foundation-only `TerminalReviewSelectionPolicy` with tested UTF-16 word-range, Select All, Copy-effect, and Done-effect semantics. Make `TerminalReviewTextView` conform to `UIEditMenuInteractionDelegate`. Remove `closeButton`. Install one edit-menu interaction plus one non-cancelling outside-selection tap recognizer. After assigning snapshot text:

1. derive a tokenizer word range from the UTF-16 offset, falling back to one composed character;
2. make the text view first responder;
3. present a menu at `firstRect(for:)` on the next main run-loop turn.

Build Copy, Select All, and Done `UIAction`s. Copy extracts the selected text, invokes an injectable writer whose production default writes `UIPasteboard.general.string`, then dismisses review. Select All changes the native selected range and re-presents the menu. Done calls `onClose` without touching the clipboard. A completed single tap outside the current selected text range dismisses review; taps inside and handle drags remain owned by `UITextView`. Do not replace UITextView's selection handles.

- [ ] **Step 4: Make long press win over pointer mode**

Remove the direct-pointer check from `gestureRecognizerShouldBegin` for `selectionLongPress`. At `.began`, deactivate touch pointer mode before capturing a snapshot and synchronize presentation.

- [ ] **Step 5: Move advanced controls into the keybar**

Delete `terminalActions` and its viewport overlay. Extend `TerminalKeybar` with pointer state and callbacks plus clipboard authorization. Add one `Menu` keycap with accessibility ID `terminal.keybar.tools`; include pointer toggle only when available and always include one-time OSC 52 read authorization. Use it in compact and expanded keybar rows.

- [ ] **Step 6: Verify GREEN**

Re-run `TerminalReviewSelectionPolicyTests`, the source-contract command, and generic `build-for-testing`; expected package tests PASS, source contract exit 0, and BUILD SUCCEEDED. UIKit test execution remains explicitly unclaimed while CoreSimulatorService is unavailable.

### Task 4: Delayed centered reconnect notice

**Files:**
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Write failing presentation boundary test**

Assert source contains a dedicated reconnect progress view with:

- `Task.sleep(for: .milliseconds(350))`;
- default centered overlay rather than `.overlay(alignment: .top)` for reconnecting state;
- `RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)`;
- `.black.opacity(0.82)`.

Also assert disconnected content retains explicit top alignment and remains immediately visible.

- [ ] **Step 2: Verify RED**

Run this executable source contract:

```bash
zsh -c 'rg -Fq "Task.sleep(for: .milliseconds(350))" Conn/Conn/Terminal/TerminalScreen.swift && rg -Fq "RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)" Conn/Conn/Terminal/TerminalScreen.swift && rg -Fq "black.opacity(0.82)" Conn/Conn/Terminal/TerminalScreen.swift'
```

Expected before implementation: exit 1. Also compile the updated `AppWideUIConsistencyTests` with generic build-for-testing; do not claim they executed without the required booted simulator.

- [ ] **Step 3: Implement the notice**

Create a private `TerminalReconnectingNotice` with local `isVisible = false`. In `.task`, sleep 350ms, honor cancellation, then publish visibility. Render a compact `HStack` with spinner and label, horizontal/vertical padding, 9-point continuous rounded rectangle, and 0.82 black opacity. Use a centered overlay for reconnecting and a separate top-aligned branch for disconnected status.

- [ ] **Step 4: Verify build and focused tests**

Re-run the source contract; expected exit 0. Run generic iOS build-for-testing; expected BUILD SUCCEEDED. If and only if CoreSimulatorService exposes exactly one already-booted device, run the focused app tests on that exact UDID; otherwise record that simulator execution was unavailable.

### Task 5: Full verification and handoff

**Files:**
- Review all files above and `docs/superpowers/specs/2026-08-16-terminal-native-selection-and-resume-design.md`.

- [ ] **Step 1: Run package regression suite**

Run: `swift test --package-path Packages/ConnPackages`

Expected: all tests pass with zero failures.

- [ ] **Step 2: Run generic iOS build**

Run:

`xcodebuild build -workspace Conn.xcworkspace -scheme Conn -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run app build-for-testing**

Run the generic simulator build-for-testing command. If CoreSimulatorService works and exactly one already-booted simulator exists, run focused app tests only on that UDID. Otherwise stop simulator work and report the limitation.

- [ ] **Step 4: Inspect diff and ownership**

Run `git status --short` and `git diff --check`. Confirm `Conn/Conn/Localizable.xcstrings` remains unstaged and unchanged by this work.

- [ ] **Step 5: Commit implementation only if requested**

Do not push unless the user requests it. Stage only implementation/test/plan files; never stage the user's localization change.
