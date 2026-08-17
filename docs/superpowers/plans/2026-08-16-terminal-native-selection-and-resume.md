# Terminal Native Selection and Foreground Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore ANSI-preserving native iOS terminal selection in SwiftTerm, keep a compact four-way direction pad, make terminal close dismiss immediately, and preserve healthy PTY/tmux sessions when the app returns from the background.

**Architecture:** Add a read-only SSH pool-health value and a pure foreground-recovery planner, then let the existing coordinator reconnect only affirmative candidates with a two-task concurrency bound. Keep provider-neutral reconnect descriptors as the only tmux restoration mechanism. Keep Conn's provider-aware gesture router, but forward selection lifecycle events into SwiftTerm's live renderer and selection service; never cover the terminal with a `UITextView`. Keep one compact four-way direction pad in the single-row keybar.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, UIKit gesture recognizers/edit menu, ConnSSH, ConnTerminal, vendored SwiftTerm

---

## File Map

- Create `Packages/ConnPackages/Sources/ConnTerminal/TerminalForegroundRecoveryPolicy.swift`: pure candidate selection and ordering.
- Modify `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`: expose non-mutating pooled-session health.
- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`: use policy and bounded recovery.
- Modify `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift`: expose a narrow host-driven selection-pan forwarding hook around the existing selection algorithm.
- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`: forward long press/pan into SwiftTerm, make remote gestures yield to selection, clear selection on tap/input, and remove the review overlay from the long-press selection path.
- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalKeybar.swift`: use one compact horizontal row with a fixed four-way `TerminalDirectionPad`; keep pointer mode in the expanded panel.
- Keep `TerminalReviewTextView` only for the bounded tmux-history fallback; remove it from long-press selection and make any keybar/system input dismiss that fallback before continuing.
- Modify `Conn/Conn/Terminal/TerminalScreen.swift`: delayed centered reconnect notice and dismiss-before-cleanup close behavior.
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

### Task 3: Renderer-native selection and compact four-way keybar

**Files:**
- Modify: `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalKeybar.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalReviewTextView.swift` only as required for the bounded tmux-history fallback to dismiss cleanly on input.
- Test: `Conn/ConnTests/TerminalLayoutTests.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Write failing renderer-selection and keybar contracts**

Update `TerminalLayoutTests` and `AppWideUIConsistencyTests` to require:

- one installed host selection pan in addition to long press;
- long press still begins when touch pointer mode is active;
- active selection prevents remote scroll and direct-pointer recognizers from beginning;
- terminal tap and keybar/system input clear SwiftTerm selection before continuing;
- the host calls `beginHostSelection`, `extendHostSelection`, `finishHostSelection`, and the vendored selection-pan forwarding hook;
- the long-press path never captures persistent history or presents `TerminalReviewTextView`, and the keybar has no `allowsHitTesting` review lock;
- `TerminalKeybar` contains exactly one `TerminalDirectionPad`, excludes individual `.up/.down/.left/.right` compact keycaps, and has compact height no greater than 52.

- [ ] **Step 2: Verify RED**

Run the focused source contract and generic app test compilation. Expected: failure because the current host still presents `TerminalReviewTextView`, has no host selection pan, and the compact key list still contains four separate arrows.

- [ ] **Step 3: Expose the narrow SwiftTerm host hook**

Add one public method that forwards a host-installed `UIPanGestureRecognizer` to SwiftTerm's existing `panSelectionHandler`. Do not duplicate pivot choice, endpoint proximity, menu presentation, or auto-scroll in Conn. Keep the fork addition documented as a stable host interaction hook.

- [ ] **Step 4: Replace review overlay with live renderer selection**

At long-press `.began`, deactivate touch pointer mode, clear any stale selection, and call `beginHostSelection(at:granularity: .word)`. At `.changed`, call `extendHostSelection(to:)`. At `.ended`, call `finishHostSelection(showMenu: true)`; cancellation clears selection.

Install one host selection pan that begins only while `hasActiveSelection` is true and forwards all states to SwiftTerm. Make native scroll, remote scroll, and touch-pointer gestures yield while selection is active. A regular terminal tap clears selection first. Before system keyboard, keybar key, or paste input is sent, clear the selection and continue the same action instead of blocking it.

- [ ] **Step 5: Remove the invalid overlay from selection**

Remove snapshot capture/review presentation from `handleSelectionLongPress`; PTY and tmux both select the currently rendered SwiftTerm buffer. Retain bounded `capturePersistentHistory` only for provider-history scrolling so tmux scrolling does not regress. Remove the keybar hit-testing lock, and make keyboard/keybar input dismiss history review and then continue the requested input in the same action.

- [ ] **Step 6: Restore the compact four-way direction pad**

Set compact height to at most 52. Remove four arrow keys from `compactKeys`; place one 44-point `TerminalDirectionPad` at the trailing edge. Shrink visible keycaps and spacing so more keys appear, while wrapping each action in at least a 44-point effective hit target. Keep low-frequency reconnect, command picker, and pointer mode in the expanded panel.

- [ ] **Step 7: Verify GREEN**

Run `TerminalDirectionPadTests`, the focused app source/layout contracts, generic iOS `build-for-testing`, full package tests, and `git diff --check`. UIKit test execution remains explicitly unclaimed if the required already-booted simulator is unavailable.

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

### Task 5: Immediate terminal close

**Files:**
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Add a source-boundary regression test**

Assert the top-right close button calls a helper whose body captures the tab ID, invokes `dismiss()` before creating the asynchronous cleanup task, and then calls `terminalSessions.close`. This behavior is provider-neutral and must not mention tmux.

- [ ] **Step 2: Implement dismiss-before-cleanup**

Move the close behavior into `closeTerminalAndDismiss()`. Call `dismiss()` synchronously, then start an unstructured task that closes the local tab. The existing persistent attachment close continues to detach tmux without killing the remote workspace.

- [ ] **Step 3: Verify**

Compile app tests and run the static source contract. Confirm the close helper is provider-neutral and no empty-tab placeholder can become visible before dismissal.

### Task 6: Full verification and handoff

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
