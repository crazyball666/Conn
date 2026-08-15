# Current-Page Terminal Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every terminal creation decision and remote tmux lookup happen in a closable sheet on the current source page, while the terminal home remains a local-tab-only view and `TerminalScreen` only presents an already-created tab.

**Architecture:** Add a two-phase launch transaction to `TerminalSessionCoordinator` so cancellation wins even when SSH/PTTY opening ignores Swift task cancellation. Build a provider-neutral `NewTerminalFlowModel` and `NewTerminalSheet` around one-shot persistent workspace APIs, then route all interactive and explicit terminal entry points through source-page creation before presenting `TerminalScreen(existing:)`.

**Tech Stack:** Swift 6-compatible Swift concurrency, SwiftUI, Observation, Swift Testing, ConnTerminal/ConnMultiplexer abstractions, Xcode iOS 17 project.

---

## File map

- `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`: owns launch-attempt registration, prepare/commit/cancel arbitration, resource cleanup, and the existing convenience `launch(_:)` API.
- `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionCoordinatorTests.swift`: proves cancellation and commit semantics, including a non-cancellable shell open.
- `Packages/ConnPackages/Sources/ConnTerminal/NewTerminalFlowModel.swift`: provider-neutral, `@MainActor` state machine for host/type/provider/workspace selection and launch transactions; kept out of the app UI target so it is package-testable on macOS.
- `Conn/Conn/Terminal/NewTerminalSheet.swift`: reusable closable SwiftUI sheet; contains extracted terminal type and workspace/create UI.
- `Packages/ConnPackages/Tests/ConnTerminalTests/NewTerminalFlowModelTests.swift`: state-machine tests using injected operation closures/recorders, without performing SSH.
- `Conn/Conn/Terminal/TerminalSessionCenterView.swift`: local-store-only host/tab list and host-unfixed new-terminal sheet.
- `Conn/Conn/Terminal/TerminalScreen.swift`: existing-tab presenter, reconnect/session switching, and fixed-host new-terminal sheet for adding a tab.
- `Conn/Conn/Terminal/TerminalLaunchPresentation.swift`: small reusable source-page launch state for explicit Docker/script requests, including attempt cancellation and route creation.
- `Conn/Conn/Hosts/HostDetailView.swift`, `Conn/Conn/Servers/ServersView.swift`: open recent local tab directly or show the fixed-host sheet on the current page.
- `Conn/Conn/Hosts/DockerView.swift`, `Conn/Conn/Hosts/ContainerDetailView.swift`, `Conn/Conn/Commands/SnippetRunView.swift`: prepare and commit explicit requests before presenting an existing tab.
- `Conn/Conn/ConnApp.swift`: adapt debug terminal smoke route to pre-create or a dedicated existing-tab harness.
- `Conn/ConnTests/AppWideUIConsistencyTests.swift`: source-level architectural guards for no catalog-on-home and no create-on-terminal-screen regressions.
- `Conn/Conn/Localizable.xcstrings`: add only strings introduced by the new sheet/errors, preserving existing edits.

### Task 1: Add coordinator launch transactions

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionCoordinatorTests.swift`

- [ ] **Step 1: Write failing transaction tests**

Add tests covering these exact public operations:

```swift
let attemptID = coordinator.beginLaunchAttempt()
let prepared = await coordinator.prepareLaunch(request, attemptID: attemptID)
let committed = await coordinator.commitLaunch(attemptID: attemptID)
await coordinator.cancelLaunch(attemptID: attemptID)
```

Prove: prepare does not add a tab; commit adds and selects exactly one tab; cancel before prepare starts leaves no tab; cancel during `DelayedShellGate.wait()` closes the late channel and leaves no tab; cancel after prepare closes resources; commit followed by cancel keeps the committed tab; an unknown/reused attempt fails; host invalidation cancels a matching attempt.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter TerminalSessionCoordinatorTests
```

Expected: compilation fails because the attempt API does not exist.

- [ ] **Step 3: Add the attempt identity and state machine**

Implement a public opaque ID and private state owned by the coordinator's main actor:

```swift
public struct TerminalLaunchAttemptID: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

private enum LaunchAttemptState {
    case pending
    case preparing(hostID: String, hostGeneration: UInt64)
    case prepared(PreparedLaunch)
    case cancelled(workerOutstanding: Bool)
}
```

`beginLaunchAttempt()` synchronously inserts `.pending`. `prepareLaunch` atomically changes pending to preparing before its first suspension, opens/builds a temporary tab without `store.add`, and after every suspension verifies the state and host generation. A cancelled prepare closes its temporary session/attachment and acknowledges/removes the tombstone. A failed prepare removes active state and returns `TerminalLaunchFailure`.

- [ ] **Step 4: Split preparation from ownership transfer**

Extract current `createTab` construction into a private `prepareTab` returning:

```swift
private struct PreparedLaunch {
    let tab: TerminalTab
    let session: TerminalSession
    let attachment: (any PersistentTerminalAttachment)?
}
```

`commitLaunch` removes a prepared attempt, calls `store.add`, starts the session, installs lifecycle observation, and returns the tab. `cancelLaunch` first changes state to cancelled on `MainActor`, then closes prepared resources; pending/preparing tombstones remain until the prepare worker acknowledges them. Never call `store.add` from prepare.

- [ ] **Step 5: Rebuild `launch(_:)` on prepare + commit**

Keep `.existing` and `.reuseRecentOrCreate` behavior. Creation paths synchronously begin an attempt and then prepare/commit it. Host invalidation increments the existing generation and cancels attempts whose registered host matches. Preserve in-flight recent-tab deduplication.

- [ ] **Step 6: Run coordinator and package tests**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter TerminalSessionCoordinatorTests
swift test --package-path Packages/ConnPackages
```

Expected: all tests pass; no leaked attempt or local tab in cancellation cases.

### Task 2: Build the new-terminal state model

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/NewTerminalFlowModel.swift`
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/NewTerminalFlowModelTests.swift`

- [ ] **Step 1: Write failing model tests**

Cover fixed and unfixed host initialization, plain PTY without provider calls, persistent selection as the only trigger for candidate probing, full candidate diagnostics when none are usable, automatic one-shot workspace load for one usable candidate, candidate selection for multiple usable candidates, attach/create descriptor routing, refresh success replacement, refresh failure preservation, close cancellation, stale-generation result rejection, and completion emitted once.

- [ ] **Step 2: Run the package test target and verify RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter NewTerminalFlowModelTests
```

Expected: tests fail to compile because `NewTerminalFlowModel` is absent.

- [ ] **Step 3: Implement a provider-neutral state machine**

Use explicit phases such as:

```swift
enum Phase: Equatable {
    case hostSelection
    case terminalTypeSelection
    case providerLoading
    case providerSelection
    case workspaceSelection
    case creating
}
```

Keep all candidates and derive usable candidates with `.available`/`.degraded`. Inject a small `Operations` value whose closures call the concrete host repository/coordinator in production and record calls in tests. Store the active `TerminalLaunchAttemptID`, a monotonically increasing generation, current task, prior workspaces, and a one-shot completion guard.

- [ ] **Step 4: Implement close and launch ownership**

`close()` increments generation, cancels probe/list tasks, and awaits `cancelLaunch` for the active attempt. Every create path calls `beginLaunchAttempt()` before creating its task, then `prepareLaunch`, re-checks generation/closed state, and finally `commitLaunch`. A successful commit clears the attempt before emitting `(host, tabID)` so sheet dismissal cannot cancel the committed tab.

- [ ] **Step 5: Run model tests**

Run the same focused `swift test` command. Expected: all model tests pass without requiring a simulator.

### Task 3: Create the reusable sheet

**Files:**
- Create: `Conn/Conn/Terminal/NewTerminalSheet.swift`
- Modify: `Conn/Conn/Localizable.xcstrings`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Add source guards for sheet behavior**

Assert the sheet owns a `NavigationStack`, has a top-bar Close action at the shared shell level, and does not reference `openPersistentCatalog`/catalog attachment types.

- [ ] **Step 2: Implement sheet rendering**

Render host selection, type selection, provider diagnostics/selection, workspace rows, create-name field, loading/empty/error states, Retry/Refresh/Back, and a fixed Close button for every phase. Apply `interactiveDismissDisabled()` so a swipe cannot bypass the explicit cancellation path, and call the model's idempotent `close()` from `onDisappear` as a safety net for parent-driven/system dismissal; successful completion must clear the active attempt first, making this cleanup a no-op for committed tabs. Reuse one workspace row/create form; do not include a plain-PTY fallback inside the explicit persistent workspace stage.

- [ ] **Step 3: Add surgical localizations and compile**

Modify only required entries in `Localizable.xcstrings`, preserving the pre-existing dirty diff. Run formatter/lint if configured, then generic iOS build:

```bash
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -configuration Debug -destination 'generic/platform=iOS Simulator'
```

Expected: build succeeds.

### Task 4: Make the terminal home local-only

**Files:**
- Modify: `Conn/Conn/Terminal/TerminalSessionCenterView.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Replace old architectural assertions with required guards**

Assert zero references to `remoteCatalogs`, catalog tasks/handles, `openPersistentCatalog`, `RemoteWorkspaceSummary`, or window/pane management routes. Assert displayed groups filter out `tabs.isEmpty`, existing rows route by tab ID, and the plus button presents `NewTerminalSheet` on this view.

- [ ] **Step 2: Run the focused tests and verify RED**

Run `AppWideUIConsistencyTests` on the booted simulator only. Expected: old implementation violates the new guards.

- [ ] **Step 3: Remove remote catalog state and UI**

Delete expansion-triggered network work, inline remote session rows, freshness UI, management navigation, catalog cleanup, and the old `TerminalHostPickerSheet`. Build host groups solely from `TerminalSessionStore`, omitting zero-tab hosts.

- [ ] **Step 4: Add current-page new flow and existing-tab route**

The plus button presents `NewTerminalSheet(fixedHost: nil)`. Completion first dismisses the sheet, then sets a route containing host/tab ID and presents `TerminalScreen(..., tabID:)`. Existing local rows set the same existing route directly.

- [ ] **Step 5: Run focused tests and compile**

Expected: architectural guards pass and terminal center compiles with no catalog references.

### Task 5: Convert TerminalScreen to an existing-tab presenter

**Files:**
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Add failing source/API guards**

Assert production initializer requires an existing `tabID`; source contains no `launchIfNeeded`, backend picker, workspace picker, `persistentBackendCandidates`, or create-new policy. Assert the session-list Create action presents `NewTerminalSheet` with the current host.

- [ ] **Step 2: Remove initial creation state and UI**

Delete launch policy/source/backend/initial command fields and backend/workspace picker logic. Initialize selected tab from the existing ID, fail closed if it no longer exists, and retain reconnect, close, command insertion, rename, and session switching.

- [ ] **Step 3: Reuse the sheet for an additional terminal**

When Session List requests Create, dismiss that list, then present the fixed-host sheet from `TerminalScreen`. On success, keep the outer screen, select the committed tab ID, and never create a second `TerminalScreen`.

- [ ] **Step 4: Run focused tests and generic build**

Expected: no terminal type picker appears after TerminalScreen is presented.

### Task 6: Migrate host and server entry points

**Files:**
- Modify: `Conn/Conn/Hosts/HostDetailView.swift`
- Modify: `Conn/Conn/Servers/ServersView.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Add routing guards**

Require each entry to query `terminalSessions.store.recentTab(forHost:)`; existing recent tabs route directly to existing TerminalScreen, otherwise the current page presents a fixed-host `NewTerminalSheet`.

- [ ] **Step 2: Implement route and sheet state on each source page**

Use a small identifiable route carrying `(Host, tabID)`. Sheet completion dismisses before route presentation. Do not use `TerminalLaunchPolicy.reuseRecentOrCreate` from a TerminalScreen initializer.

- [ ] **Step 3: Run focused tests and build**

Expected: no empty TerminalScreen opens from either entry.

### Task 7: Migrate explicit Docker and script entry points

**Files:**
- Create: `Conn/Conn/Terminal/TerminalLaunchPresentation.swift`
- Modify: `Conn/Conn/Hosts/DockerView.swift`
- Modify: `Conn/Conn/Hosts/ContainerDetailView.swift`
- Modify: `Conn/Conn/Commands/SnippetRunView.swift`
- Modify: `Conn/Conn/ConnApp.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Add failing explicit-entry guards**

Assert Docker/script production calls do not pass `.createNew` to TerminalScreen and do pass an existing tab ID. Assert the explicit source page owns launch progress/error state and a launch-attempt cancellation path.

- [ ] **Step 2: Implement reusable explicit launch presentation state**

Provide a `@MainActor` helper that synchronously begins an attempt, prepares the caller-supplied request, commits only while its generation is active, exposes loading/error/route state, and cancels on source disappearance. It must not present the ordinary/tmux picker.

- [ ] **Step 3: Migrate Docker and container console actions**

Create `.docker(containerName:)` requests on the Docker source page with command replay enabled. Show progress there; only successful commit presents TerminalScreen with the tab ID.

- [ ] **Step 4: Migrate snippet terminal execution**

After risk confirmation, create `.script(title:)` request on `SnippetRunView`; preserve the prepared command and existing compatibility/risk behavior. Present only the committed existing tab.

- [ ] **Step 5: Adapt debug smoke route**

Keep diagnostics coverage without reintroducing a production create-on-TerminalScreen initializer. Use a small smoke host wrapper that commits the request before rendering the existing tab.

- [ ] **Step 6: Run focused tests and generic build**

Expected: every production `TerminalScreen(` call receives an existing tab ID; Docker/script failures stay on their source page.

### Task 8: Full review and verification

**Files:**
- Review all files above

- [ ] **Step 1: Run architectural searches**

```bash
rg -n "openPersistentCatalog|remoteCatalogs|PersistentWorkspacePicker|beginLaunchChoice|launchPolicy: \.createNew" Conn/Conn/Terminal Conn/Conn/Hosts Conn/Conn/Servers Conn/Conn/Commands
rg -n "TerminalScreen\(" Conn/Conn
```

Expected: Catalog API is absent from terminal home/new sheet; old picker flow is absent; every production TerminalScreen route is existing-tab-only.

- [ ] **Step 2: Run package tests**

```bash
swift test --package-path Packages/ConnPackages
```

Expected: all package tests pass.

- [ ] **Step 3: Run app tests on the one booted simulator**

First read the booted UDID, then run only that destination:

```bash
xcrun simctl list devices booted
xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,id=<BOOTED_UDID>'
```

Expected: all app tests pass. If CoreSimulatorService or that device is unavailable, stop simulator operations and report; do not create or boot another simulator.

- [ ] **Step 4: Run Release generic iOS build**

```bash
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -configuration Release -destination 'generic/platform=iOS'
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Independently review the implementation**

Use `superpowers:requesting-code-review`. Fix only real correctness, lifecycle, architecture, and regression issues. Re-run affected tests after every fix.

- [ ] **Step 6: Perform UI acceptance if the user's simulator is available**

Verify: home contains only local tabs and omits zero-tab hosts; sheet is on the source page and always closable; plain PTY does no tmux work; tmux loads one-shot workspaces only after selection; close leaves no tab/navigation; success opens the existing tab; additional session switches in place; Docker/script open only after creation.

- [ ] **Step 7: Verify the final diff and status**

Use `superpowers:verification-before-completion`, inspect `git diff` without overwriting unrelated dirty work, and report any simulator limitation explicitly. Do not commit implementation unless the user requests it.
