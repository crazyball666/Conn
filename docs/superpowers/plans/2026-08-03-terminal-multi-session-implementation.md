# Terminal Multi-Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every interactive terminal a globally retained, multi-session terminal with shared SSH connections, safe reconnects, and a root-level session center.

**Architecture:** `ConnTerminal` owns session-tab state, transcript replay, generation filtering, and the PTY-to-transcript bridge. The App target owns `TerminalSessionCoordinator`, which knows hosts and the shared `ConnectionManager`, applies each entry policy, and presents terminal UI from global tabs. A per-PTY `TerminalSession` writes only to its tab transcript; screens attach/detach rendering without changing SSH lifecycle.

**Tech Stack:** Swift 5.10, SwiftUI/Observation, Swift Testing, SwiftTerm, Citadel, ConnSSH `ConnectionManager`.

---

## Execution prerequisite: use only the already-booted simulator

Before any App or UI test, resolve and validate the **currently booted** iPhone 17 Pro once, then use its UDID in every command below. Do not use a name destination, do not boot/clone/erase/close a simulator, and disable parallel testing for every `xcodebuild test` invocation.

```bash
CONN_BOOTED_SIMULATOR_UDID="$(xcrun simctl list devices booted | sed -n 's/.*iPhone 17 Pro (\([A-F0-9-]*\)).*/\1/p')"
test -n "$CONN_BOOTED_SIMULATOR_UDID"
```

Every plan command written as `<SIM_DESTINATION>` means:

```bash
-destination "platform=iOS Simulator,id=$CONN_BOOTED_SIMULATOR_UDID" -parallel-testing-enabled NO
```

The user explicitly asked to work on the current branch and simulator; do not create a worktree or alter simulator lifecycle.

## File map

- `Packages/ConnPackages/Sources/ConnTerminal/TerminalReplayBuffer.swift` — new, bounded raw replay bytes with line and byte trimming.
- `Packages/ConnPackages/Sources/ConnTerminal/TerminalTranscript.swift` — new, generation-aware retained output, attachment event streams, viewport state.
- `Packages/ConnPackages/Sources/ConnTerminal/TerminalSession.swift` — replace UI callback with transcript pump, lifecycle stream and throwing I/O.
- `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionStore.swift` — enrich tab metadata; host grouping, aliases, current/recent selection and safe closing.
- `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift` — consume transcript attachment events, never start/own a session, detach safely.
- `Packages/ConnPackages/Sources/ConnSSHCitadel/CitadelShellChannel.swift` — one-shot readiness, correct EOF/error terminal lifecycle, throwing I/O after closure.
- `Packages/ConnPackages/Sources/ConnSSHCitadel/ShellChannelLifecycleGate.swift` — new testable lock-protected one-shot readiness/closure state helper.
- `Conn/Conn/Terminal/TerminalSessionCoordinator.swift` — new App-level launch/reuse/reconnect coordinator; owns no SSH connection directly.
- `Conn/Conn/Terminal/TerminalModalRoute.swift` — new shared modal state (`opening` or committed `tab`) so connecting progress is presented before a session exists.
- `Conn/Conn/Terminal/TerminalScreen.swift` — modal viewer of a global tab; back, exit, current-host session sheet and reconnect.
- `Conn/Conn/Terminal/TerminalSessionCenterView.swift` — new root terminal tab, grouped expandable host sections and host picker/new session flow.
- `Conn/Conn/ConnApp.swift` — construct and inject the coordinator once into `AppDependencies` and the root environment.
- `Conn/Conn/RootTabView.swift` — add terminal tab.
- `Conn/Conn/Hosts/HostDetailView.swift`, `Conn/Conn/Servers/ServersView.swift`, `Conn/Conn/Servers/ServersViewModel.swift`, `Conn/Conn/Hosts/DockerView.swift`, `Conn/Conn/Hosts/ContainerDetailView.swift`, `Conn/Conn/Commands/SnippetRunView.swift` — replace local `TerminalScreen` construction with coordinator launch requests and modal routes; close host PTYs before host deletion and refresh tab presentation metadata.
- `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalReplayBufferTests.swift` — new buffer tests.
- `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalTranscriptTests.swift` — new replay/order/generation tests.
- `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionTests.swift` and `TerminalSessionStoreTests.swift` — lifecycle/I/O and tab store tests.
- `Packages/ConnPackages/Tests/ConnSSHCitadelTests/ShellChannelIntegrationTests.swift` — PTY EOF, idempotent close, multi-PTY connection reuse tests.
- `Packages/ConnPackages/Tests/ConnSSHCitadelTests/ShellChannelLifecycleGateTests.swift` — new deterministic readiness/termination race tests.
- `Conn/ConnTests/TerminalSessionCoordinatorTests.swift` — new launch/reuse/failure/reconnect policy tests.
- `Conn/ConnUITests/TerminalSessionUITests.swift` — new root center and modal retention smoke tests.

### Task 1: Add the replay buffer

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalReplayBuffer.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalReplayBufferTests.swift`

- [ ] **Step 1: Write failing line-limit tests**

```swift
@Test("keeps only the newest complete 10,000 lines")
func trimsOldCompleteLines() {
    var buffer = TerminalReplayBuffer(maxLines: 2, maxBytes: 1024)
    buffer.append(Array("one\\ntwo\\nthree\\n".utf8))
    #expect(String(decoding: buffer.snapshot.bytes, as: UTF8.self) == "two\\nthree\\n")
}
```

- [ ] **Step 2: Run the focused test and confirm it fails because `TerminalReplayBuffer` is absent**

Run: `swift test --package-path Packages/ConnPackages --filter TerminalReplayBufferTests`

- [ ] **Step 3: Implement the smallest pure buffer API**

Implement `append(_:)`, `snapshot`, line trimming from the oldest complete newline, byte trimming for long non-newline streams, and a `wasTruncated` bit.

- [ ] **Step 4: Add and run byte-limit/long-line tests**

Run: `swift test --package-path Packages/ConnPackages --filter TerminalReplayBufferTests`

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnTerminal/TerminalReplayBuffer.swift Packages/ConnPackages/Tests/ConnTerminalTests/TerminalReplayBufferTests.swift
git commit -m "feat: retain bounded terminal replay output"
```

### Task 2: Make transcript attachments ordered and generation-safe

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalTranscript.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalTranscriptTests.swift`

- [ ] **Step 1: Write a failing attach/replay/live ordering test**

```swift
@Test("replay completes before a new live frame")
func attachmentOrdersReplayBeforeLiveOutput() async {
    let transcript = TerminalTranscript()
    await transcript.activateGeneration(1)
    await transcript.append(Array("old\\n".utf8), generation: 1)
    let attachment = await transcript.attach()
    await transcript.append(Array("new\\n".utf8), generation: 1)
    #expect(await attachment.collectKinds() == [.replayStarted, .replayBytes, .replayFinished, .liveBytes])
}
```

- [ ] **Step 2: Run it and confirm the missing type/API failure**

Run: `swift test --package-path Packages/ConnPackages --filter TerminalTranscriptTests`

- [ ] **Step 3: Implement `TerminalTranscript`**

Implement one active attachment continuation, token-based detach, viewport persistence, ordered replay events, `activeGeneration` filtering, and a `generationBoundary` event. The boundary appends the documented ANSI normalisation bytes to the replay buffer and emits an event to a current renderer.

- [ ] **Step 4: Add failing/then passing tests for stale generations, old-token detach, viewport ordering, and boundary before live bytes**

Run: `swift test --package-path Packages/ConnPackages --filter TerminalTranscriptTests`

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnTerminal/TerminalTranscript.swift Packages/ConnPackages/Tests/ConnTerminalTests/TerminalTranscriptTests.swift
git commit -m "feat: add retained terminal transcript attachments"
```

### Task 3: Refactor a terminal session around transcript and lifecycle

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSession.swift`
- Modify: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionTests.swift`

- [ ] **Step 1: Write failing tests for throwing input and channel close lifecycle**

Extend the controllable test channel to throw write/resize errors and finish its output. Assert `send(_:) async throws` and `resize(cols:rows:) async throws` propagate the error, normal UI input failure publishes `.failed`, and a started session flushes final bytes before publishing `.closed` after output completion.

- [ ] **Step 2: Run the focused test and confirm current swallowed input/no lifecycle behavior fails**

Run: `swift test --package-path Packages/ConnPackages --filter TerminalSessionTests`

- [ ] **Step 3: Implement the minimal session contract**

`TerminalSession` receives transcript plus generation, starts once only when coordinator tells it to, batches output into transcript, yields `.closed`/`.failed(message:)`, exposes `func send(_:) async throws` and `func resize(cols:rows:) async throws`, and makes `close()` await final flush/pump shutdown after closing only its `ShellChannel`. Renderer call sites catch input errors and rely on the lifecycle stream to mark an existing tab disconnected.

- [ ] **Step 4: Update existing batching tests and run the full target tests**

Run: `swift test --package-path Packages/ConnPackages --filter ConnTerminalTests`

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnTerminal/TerminalSession.swift Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionTests.swift
git commit -m "feat: decouple terminal sessions from terminal views"
```

### Task 4: Enrich terminal tabs and store behavior

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionStore.swift`
- Modify: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionStoreTests.swift`

- [ ] **Step 1: Write failing metadata tests**

Cover multiple same-host tabs, most-recent connected tab lookup, alias trimming/default restore, selecting a tab, grouping by host, closing the current tab and `closeAll(forHost:)`.

- [ ] **Step 2: Run and confirm missing APIs fail**

Run: `swift test --package-path Packages/ConnPackages --filter TerminalSessionStoreTests`

- [ ] **Step 3: Implement metadata-only store changes**

Add `TerminalSessionSource`, `TerminalTabStatus`, `TerminalReconnectDescriptor`, timestamps, alias/default alias, generation, transcript, `recentTab(forHost:)`, `tabs(forHost:)`, selection, state mutation, alias update and selective close. Keep tab data only in memory.

- [ ] **Step 4: Run the focused store suite**

Run: `swift test --package-path Packages/ConnPackages --filter TerminalSessionStoreTests`

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionStore.swift Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionStoreTests.swift
git commit -m "feat: manage metadata for multiple terminal sessions"
```

### Task 5: Correct Citadel PTY readiness and EOF semantics

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnSSHCitadel/CitadelShellChannel.swift`
- Create: `Packages/ConnPackages/Sources/ConnSSHCitadel/ShellChannelLifecycleGate.swift`
- Modify: `Packages/ConnPackages/Tests/ConnSSHCitadelTests/ShellChannelIntegrationTests.swift`
- Create: `Packages/ConnPackages/Tests/ConnSSHCitadelTests/ShellChannelLifecycleGateTests.swift`

- [ ] **Step 1: Write failing deterministic lifecycle-gate tests**

Test readiness success versus open failure completes exactly once; post-ready termination cannot resume open a second time; local close is idempotent; and no writer is available before readiness or after termination. Through the same injectable writer-state seam, call `CitadelShellChannel.write` and `resize` before readiness and after EOF/local close; each must throw `SSHError.channelClosed`.

- [ ] **Step 2: Run the focused unit test and confirm the helper is absent**

Run: `swift test --package-path Packages/ConnPackages --filter ShellChannelLifecycleGateTests`

- [ ] **Step 3: Implement the smallest lifecycle-gate helper and make its suite pass**

Keep the state helper internal to `ConnSSHCitadel`, lock-protected, and responsible only for one-shot readiness/termination ownership. It must not open network connections or contain test-only production APIs.

Run: `swift test --package-path Packages/ConnPackages --filter ShellChannelLifecycleGateTests`

- [ ] **Step 4: Write a failing remote-exit integration test**

Open a PTY, send `exit`, consume `channel.output`, and assert the stream finishes within the integration test deadline. Add two PTYs on one `SSHSession`, close one, and verify the other still receives an echo marker.

- [ ] **Step 5: Run the gated integration test and capture the current EOF timeout/failure**

Run: `CONN_SPIKE_HOST=127.0.0.1 swift test --package-path Packages/ConnPackages --filter ShellChannelIntegrationTests`

- [ ] **Step 6: Implement lifecycle-safe `CitadelShellChannel`**

Replace the raw checked continuation with a lock-protected one-shot readiness gate. On inbound EOF/error, finish the output exactly once, release the `withPTY` closure, and clear writer state. Local close is idempotent. `write` and `resize` throw `SSHError.channelClosed` when no usable writer remains.

- [ ] **Step 7: Re-run gate and integration suites**

Run: `swift test --package-path Packages/ConnPackages --filter ShellChannelLifecycleGateTests && CONN_SPIKE_HOST=127.0.0.1 swift test --package-path Packages/ConnPackages --filter ShellChannelIntegrationTests`

- [ ] **Step 8: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnSSHCitadel/CitadelShellChannel.swift Packages/ConnPackages/Sources/ConnSSHCitadel/ShellChannelLifecycleGate.swift Packages/ConnPackages/Tests/ConnSSHCitadelTests/ShellChannelIntegrationTests.swift Packages/ConnPackages/Tests/ConnSSHCitadelTests/ShellChannelLifecycleGateTests.swift
git commit -m "fix: finish terminal PTY channels on remote exit"
```

### Task 6: Build the app-global terminal coordinator

**Files:**
- Create: `Conn/Conn/Terminal/TerminalSessionCoordinator.swift`
- Create: `Conn/ConnTests/TerminalSessionCoordinatorTests.swift`
- Modify: `Conn/Conn/ConnApp.swift`

- [ ] **Step 1: Write failing coordinator tests with a recording SSH transport**

Test `reuseRecentOrCreate`, explicit new, concurrent dedupe, first `session/openShell/write` failure without a tab, failure-ID consumption once, Docker reconnect replay, script reconnect no-replay, stale old generation ignored, and close never calls `ConnectionManager.disconnect`. For both initial launch and reconnect, make `openShell` fail once: assert exactly one `ConnectionManager.invalidate(host:)`, one fresh handshake retry, then success; assert two failures stop at disconnected/error without an infinite retry.

- [ ] **Step 2: Run the App test and confirm the coordinator is absent**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn <SIM_DESTINATION> -only-testing:ConnTests/TerminalSessionCoordinatorTests`

- [ ] **Step 3: Implement coordinator and dependency injection**

Create a `@MainActor @Observable` coordinator with its single `TerminalSessionStore`, host repository and shared connection manager. Include launch policy/task ownership, pending-failure consumption, initial command rules, lifecycle observation, generation-safe reconnect sequence, host-delete `closeAll(forHost:)`, and global Toast publishing from the caller-facing app layer. On an `openShell` failure only, invalidate the pooled host entry and permit exactly one fresh handshake/open-shell retry; never use this path to close a normally closed tab. Construct it once in `AppDependencies.live()` and `.demo()`.

- [ ] **Step 4: Run coordinator plus existing App tests**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn <SIM_DESTINATION> -only-testing:ConnTests/TerminalSessionCoordinatorTests -only-testing:ConnTests/TerminalLayoutTests`

- [ ] **Step 5: Commit**

```bash
git add Conn/Conn/Terminal/TerminalSessionCoordinator.swift Conn/ConnTests/TerminalSessionCoordinatorTests.swift Conn/Conn/ConnApp.swift
git commit -m "feat: coordinate terminal sessions globally"
```

### Task 7: Rebind the terminal renderer to retained transcript output

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Conn/ConnTests/TerminalLayoutTests.swift`

- [ ] **Step 1: Write a failing rendering-boundary test**

Test the exposed boundary normalisation byte sequence and assert the existing content/layout rules are preserved after rebuilding a terminal view.

- [ ] **Step 2: Run and confirm it fails**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn <SIM_DESTINATION> -only-testing:ConnTests/TerminalLayoutTests`

- [ ] **Step 3: Replace local session start with attachment consumption**

Pass transcript (and sending session) into the controller. On `attach`, reset only when required, process replay then live events sequentially on `MainActor`, map a boundary to the specified ANSI normalisation sequence, save viewport state on detach, and leave session pumping when the UIView disappears.

- [ ] **Step 4: Run package and App layout tests**

Run: `swift test --package-path Packages/ConnPackages --filter ConnTerminalTests && xcodebuild test -workspace Conn.xcworkspace -scheme Conn <SIM_DESTINATION> -only-testing:ConnTests/TerminalLayoutTests`

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift Conn/ConnTests/TerminalLayoutTests.swift
git commit -m "feat: restore terminal output after view recreation"
```

### Task 8: Add the terminal modal and session center UI

**Files:**
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Create: `Conn/Conn/Terminal/TerminalSessionCenterView.swift`
- Create: `Conn/Conn/Terminal/TerminalModalRoute.swift`
- Modify: `Conn/Conn/RootTabView.swift`
- Create: `Conn/ConnUITests/TerminalSessionUITests.swift`

- [ ] **Step 1: Write UI tests for root terminal tab and modal retention**

Launch in demo/smoke mode; assert terminal tab, empty-state create action, collapsed host section, two-level host picker with expand/collapse, opening-progress modal, successful tab transition, failed launch dismissal with no row and one post-dismiss Toast, and returning from a terminal without removing its row. Add accessibility identifiers for each route state, session row, selected session, back, exit, session list, create session, rename and close actions.

- [ ] **Step 2: Run UI tests and confirm identifiers are absent**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn <SIM_DESTINATION> -only-testing:ConnUITests/TerminalSessionUITests`

- [ ] **Step 3: Implement UI from coordinator state**

Use one shared `TerminalModalRoute`: `.opening(requestID, request)` appears before the coordinator awaits the launch, then atomically changes to `.tab(tabID)` only after the coordinator commits the tab. On cancellation or failure, dismiss `.opening`, atomically consume its failure ID, then publish the one Toast from the presenting page. `TerminalScreen` takes a committed tab ID and coordinator; it has an explicit leading chevron, a trailing system toolbar group for exit/list, back only dismisses, and exit confirms before closing one tab. A current-host `.medium/.large` sheet selects/creates/aliases/closes sessions, provides VoiceOver custom rename/close actions, and resolves closing the selected tab to its next same-host session or dismisses. `TerminalSessionCenterView` groups rows by host, defaults groups collapsed, exposes a system add button, a two-level expandable host picker, dynamic-type-safe rows, and status indicators. Add `.terminal` to `RootTabView`, with every terminal presented modally.

- [ ] **Step 4: Run the focused UI tests on the already booted simulator**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn <SIM_DESTINATION> -only-testing:ConnUITests/TerminalSessionUITests`

- [ ] **Step 5: Commit**

```bash
git add Conn/Conn/Terminal/TerminalScreen.swift Conn/Conn/Terminal/TerminalSessionCenterView.swift Conn/Conn/Terminal/TerminalModalRoute.swift Conn/Conn/RootTabView.swift Conn/ConnUITests/TerminalSessionUITests.swift
git commit -m "feat: add terminal session center and modal controls"
```

### Task 9: Move every interactive entry point to the coordinator

**Files:**
- Modify: `Conn/Conn/Hosts/HostDetailView.swift`
- Modify: `Conn/Conn/Servers/ServersView.swift`
- Modify: `Conn/Conn/Hosts/DockerView.swift`
- Modify: `Conn/Conn/Hosts/ContainerDetailView.swift`
- Modify: `Conn/Conn/Commands/SnippetRunView.swift`
- Modify: `Conn/Conn/ConnApp.swift`
- Modify: `Conn/Conn/Servers/ServersViewModel.swift`
- Modify: `Conn/Conn/Hosts/HostFormView.swift`
- Modify: `Conn/ConnTests/HostWorkspaceNavigationTests.swift`
- Modify: `Conn/ConnTests/ServersViewModelTests.swift`
- Modify: `Conn/ConnUITests/TerminalSessionUITests.swift`

- [ ] **Step 1: Write a failing source-entry behavior test**

Assert normal host entry asks for `reuseRecentOrCreate`, Docker entry uses `createNew` and an exact replay command, script terminal entry uses `createNew` with no reconnect replay, and all screens use modal presentation. Add a host-delete test that proves every matching PTY closes before repository deletion. Add a host-save/edit test that refreshes active session row title/address presentation without closing its PTY or the pooled SSH connection.

- [ ] **Step 2: Run it and confirm old local screen construction fails the assertion**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn <SIM_DESTINATION> -only-testing:ConnTests/HostWorkspaceNavigationTests -only-testing:ConnTests/ServersViewModelTests`

- [ ] **Step 3: Replace each local terminal route**

All routes first present `TerminalModalRoute.opening`, call coordinator launch, then transition to a committed tab route or dismiss/consume a failure into `ConnToastCenter`. Keep the DEBUG smoke entry on the same coordinator path. Do not change silent batch script execution. Route destructive host delete through an async action that awaits `coordinator.closeAll(forHost:)` before deleting. Change `HostFormView` from `onSaved: () -> Void` to `onSaved: (Host) -> Void`, forwarding the non-nil result of `HostFormViewModel.save()`. In `ServersView`, invoke `viewModel.load()` and `coordinator.refreshHostPresentation(savedHost)` from that callback; do not disconnect the existing PTY or shared SSH session.

- [ ] **Step 4: Run focused App/UI tests**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn <SIM_DESTINATION> -only-testing:ConnTests/HostWorkspaceNavigationTests -only-testing:ConnTests/ServersViewModelTests -only-testing:ConnUITests/TerminalSessionUITests`

- [ ] **Step 5: Commit**

```bash
git add Conn/Conn/Hosts/HostDetailView.swift Conn/Conn/Servers/ServersView.swift Conn/Conn/Servers/ServersViewModel.swift Conn/Conn/Hosts/HostFormView.swift Conn/Conn/Hosts/DockerView.swift Conn/Conn/Hosts/ContainerDetailView.swift Conn/Conn/Commands/SnippetRunView.swift Conn/Conn/ConnApp.swift Conn/ConnTests/HostWorkspaceNavigationTests.swift Conn/ConnTests/ServersViewModelTests.swift Conn/ConnUITests/TerminalSessionUITests.swift
git commit -m "feat: route terminal entry points through global sessions"
```

### Task 10: Full verification and visual acceptance

**Files:**
- Modify only if a verification failure requires a focused regression test.

- [ ] **Step 1: Run package tests**

Run: `swift test --package-path Packages/ConnPackages`

- [ ] **Step 2: Run full iOS unit and UI suites on the already-running user simulator**

Resolve the booted iPhone 17 Pro UDID with `xcrun simctl list devices`, then run:

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination "platform=iOS Simulator,id=<BOOTED_IPHONE_17_PRO_UDID>" -parallel-testing-enabled NO
```

- [ ] **Step 3: Build Release**

Run: `xcodebuild build -workspace Conn.xcworkspace -scheme Conn -configuration Release -destination "generic/platform=iOS"`

- [ ] **Step 4: Perform manual visual acceptance on the same simulator**

Open an existing host terminal, create a second shell, return, switch through root terminal center, alias and close one session, enter a Docker console, and verify terminal keybar/keyboard layout after reopen. Do not boot, clone, erase, or close any simulator.

- [ ] **Step 5: Commit any focused verification fix and report exact evidence**

```bash
git status --short
git log --oneline -8
```
