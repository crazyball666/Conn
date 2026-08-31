# Terminal File Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a terminal-session file-management action that reuses the existing remote file browser, opens at a trustworthy terminal working directory when available, and retains an independent browser state for each terminal while the terminal page remains alive.

**Architecture:** Keep attachment-upload directory handling separate from a new terminal-working-directory observation pipeline. A pure `ConnTerminal` resolver validates provider paths and OSC 7 URLs, tracks provider/OSC 7 precedence per generation, and is consumed by `TerminalScreen` through a tab-ID keyed map. `TerminalScreen` owns one `FileBrowserViewModel` per terminal tab and presents it in a navigation-stack sheet; the host-detail file browser remains untouched.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, XCTest/XCUITest, SwiftTerm terminal delegate callbacks, existing `FileBrowserViewModel`, `EntitlementGate`, and the current iPhone 17 Pro simulator.

---

## Files and responsibilities

- Create `Packages/ConnPackages/Sources/ConnTerminal/TerminalWorkingDirectory.swift`: strict OSC 7/provider path validation and the per-generation provider-vs-OSC 7 resolver.
- Create or modify `Packages/ConnPackages/Tests/ConnTerminalTests/*`: pure parser/resolver regression tests.
- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`: add a separate terminal-directory callback, preserve the existing attachment callback, and ignore replayed OSC 7 data.
- Modify `Conn/Conn/Files/FileBrowserViewModel.swift`: accept a pre-load initial path and retry `/` once when the initial non-root directory cannot be listed.
- Modify `Conn/Conn/Terminal/TerminalScreen.swift`: maintain per-tab resolver and file-browser VM state, route the new action after the action sheet dismisses, and gate entry with the existing file-management paywall.
- Modify `Conn/Conn/Terminal/TerminalScreen.swift` and/or `Conn/Conn/Files/FileBrowserView.swift`: add stable accessibility identifiers needed for UI verification without introducing new user-facing strings.
- Modify `Conn/ConnTests/AppWideUIConsistencyTests.swift` and add focused `ConnTests` coverage: enforce action routing, callback separation, ownership separation, and file-browser initial-path behavior.
- Modify or create `Conn/ConnUITests/TerminalFileBrowserUITests.swift`: verify Pro entry, free paywall, same-terminal restore, different-terminal isolation, and Docker root behavior.
- Do not modify `Conn/Conn/Hosts/HostDetailView.swift` or its host-scoped `fileVM` ownership except where a test needs to assert it remains independent.
- Do not add localization keys: `文件管理` is already present in `Conn/Conn/Localizable.xcstrings` for `zh-Hans`, `zh-Hant`, `en`, `ja`, and `ko`.

### Task 1: Add and test the working-directory parser and resolver

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalWorkingDirectory.swift`
- Create or modify: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalWorkingDirectoryTests.swift`

- [ ] **Step 1: Write failing parser tests.** Cover a standard `file:///home/demo/app` OSC 7 URL, a host-bearing `file://server/home/demo/app` URL, percent-encoded path components, case-insensitive `FILE` scheme, and trailing-slash normalization. Add rejected cases for non-file schemes, relative URLs/paths, malformed percent escapes, control/NUL characters, empty components, `.` and `..` traversal. Test provider raw absolute POSIX paths independently from URL parsing.

- [ ] **Step 2: Run the focused package tests and verify the new API is missing.**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter ConnTerminalTests.TerminalWorkingDirectoryTests
```

Expected: compile failure because the parser/resolver types do not exist yet.

- [ ] **Step 3: Write failing resolver tests.** Verify provider paths take precedence over OSC 7, clearing a stale provider reveals the latest valid OSC 7 path, a later live provider path replaces OSC 7, a generation change clears both candidates, an older generation cannot update the resolver, and separate resolver instances do not cross-contaminate tab state.

- [ ] **Step 4: Implement the minimal pure API.** Add a public source enum for `.provider` and `.osc7`, strict normalizers for OSC 7 URL and provider raw path, and a `Sendable`, `Equatable` resolver with `update(source:generation:path:)`, generation invalidation, stale-generation rejection, and `effectivePath` returning provider first then OSC 7. Treat `nil` provider updates as removal of only the provider candidate. Normalize `/` and trailing separators without resolving or permitting traversal.

- [ ] **Step 5: Run the focused tests until green.**

Run the same `swift test --package-path Packages/ConnPackages --filter ConnTerminalTests.TerminalWorkingDirectoryTests` command and expect PASS.

- [ ] **Step 6: Commit the isolated logic.**

```bash
git add Packages/ConnPackages/Sources/ConnTerminal/TerminalWorkingDirectory.swift Packages/ConnPackages/Tests/ConnTerminalTests/TerminalWorkingDirectoryTests.swift
git commit -m "feat: resolve terminal working directories safely"
```

### Task 2: Extend terminal working-directory propagation without affecting uploads

**Files:**

- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`
- Modify or create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalHostingViewTests.swift` if the package test target can exercise the callback; otherwise keep callback wiring assertions in `AppWideUIConsistencyTests`.

- [ ] **Step 1: Add failing source/wiring assertions.** Assert that `TerminalHostingView` exposes a new callback carrying source and generation, that it is threaded through `TerminalHostContent` and `TerminalInputController`, that the existing `onPersistentWorkingDirectoryChanged` remains present for uploads, and that `hostCurrentDirectoryUpdate` no longer discards its directory argument. Cover the freshness branch explicitly: a stale/unavailable provider update must send `nil` through the new terminal-directory callback so the app removes only the provider candidate and can fall back to OSC 7.

- [ ] **Step 2: Implement the new callback.** Add a public initializer callback such as `(TerminalWorkingDirectorySource, UInt64, String?) -> Void`, thread it through the private view/controller layers, and send provider updates from `acceptPersistentState`: pass the validated live provider path for live freshness and pass `nil` for stale/unavailable freshness. Keep the existing provider-only upload callback exactly separate. Do not clear the new resolver through `detach()` merely because a controller reattaches in the same generation; generation changes are handled by the resolver.

- [ ] **Step 3: Implement OSC 7 handling with replay protection.** In `hostCurrentDirectoryUpdate`, accept only normalized values from the new parser and emit them only for outside-feed/live delegate provenance; reject replay and generation-boundary output so historical transcript data cannot overwrite the current directory. Emit the current terminal generation with every callback. Do not inject `pwd`, alter shell startup, or route OSC 7 into attachment uploads.

- [ ] **Step 4: Run package and app source tests.**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter ConnTerminalTests
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/AppWideUIConsistencyTests
```

Expected: both suites PASS on the already booted simulator.

- [ ] **Step 5: Commit callback propagation.**

```bash
git add Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift Conn/ConnTests/AppWideUIConsistencyTests.swift Packages/ConnPackages/Tests/ConnTerminalTests
git commit -m "feat: observe live terminal working directories"
```

### Task 3: Make the existing file browser accept a safe initial directory and recover from stale paths

**Files:**

- Modify: `Conn/Conn/Files/FileBrowserViewModel.swift`
- Modify: `Conn/ConnTests/RemoteFileIntegrityTests.swift` or create `Conn/ConnTests/FileBrowserViewModelTests.swift`

- [ ] **Step 1: Write failing VM tests.** Verify a valid initial absolute path is used on the first load, an initial path set after loading does not overwrite user navigation, a non-root initial path that fails listing retries `/` once and succeeds there, and a root failure remains the existing failed state. Use a focused mock `RemoteFileSystem`/transport rather than a real host.

- [ ] **Step 2: Implement pre-load initial-path setup.** Add an internal method such as `setInitialPathIfNeeded(_:)` that only accepts the already-normalized absolute path and only changes `currentPath` while `hasLoaded == false`. Preserve the existing public browser navigation behavior.

- [ ] **Step 3: Implement one-time root fallback.** Refactor the first `loadIfNeeded()` path so it tries the initial path, and if that non-root list fails, calls the existing load path for `/` exactly once. If `/` also fails, preserve the existing error state. Do not retry arbitrary paths or mask errors after the fallback.

- [ ] **Step 4: Run focused ConnTests.**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/FileBrowserViewModelTests \
  -only-testing:ConnTests/RemoteFileIntegrityTests
```

- [ ] **Step 5: Commit the VM behavior.**

```bash
git add Conn/Conn/Files/FileBrowserViewModel.swift Conn/ConnTests
git commit -m "feat: support terminal file browser initial paths"
```

### Task 4: Route the session action to a terminal-scoped file browser

**Files:**

- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Modify: `Conn/Conn/Files/FileBrowserView.swift` only for stable test identifiers if needed
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Add failing source-level ownership and routing assertions.** Cover the `文件管理` action identifier, deferred action routing after sheet dismissal, the subscription gate/paywall context, a `tabID` keyed file-browser VM map, a separate terminal-directory resolver map, navigation-stack sheet presentation, and the fact that `HostDetailView`'s `fileVM` is not passed into the terminal route. Update the old test that says session actions contain only switch/close.

- [ ] **Step 2: Add the action row.** Extend `DeferredTerminalSessionAction` with the file-browser case and add a localized `L("文件管理")` row to `TerminalSessionActionsSheet` with a stable identifier such as `terminal.session-actions.files`. Keep switch/close behavior unchanged and preserve deferred presentation sequencing.

- [ ] **Step 3: Add per-tab observation and VM storage.** In `TerminalScreen`, retain a resolver by terminal `tabID` and a `FileBrowserViewModel` by terminal `tabID`. Capture the tab ID, source, and generation in `TerminalHostingView` callbacks so a late callback from another tab or an old generation cannot update the active tab. For `.shell`, `.script`, and `.persistent`, pass the resolver's effective path to a new VM before first load; for `.docker`, pass no terminal path so the VM starts at `/`. If a valid directory arrives before an un-loaded VM starts, update only that VM's initial path; never overwrite a loaded VM's user-selected directory.

  Synchronize the resolver with `activeTab.generation` as a separate state transition, not only when a callback arrives: when the active tab's generation changes, explicitly reset that tab's resolver before the new connection reports anything. Add a test for a generation change with no new directory report, and ensure stale callbacks from the prior generation are rejected.

- [ ] **Step 4: Present and gate the browser.** After the action sheet dismisses, check `dependencies.subscription.gate.allowed(.fileManagement)`. On false, present the existing `.fileManagement` paywall. On true, create/reuse the current tab's VM, call a dedicated reset method for transient presentation state (`pendingDeletion`, `actionMessage`, and other prompt-only VM state), and present `FileBrowserView` inside a `NavigationStack` sheet. The fresh `FileBrowserView` instance must own search, sorting, editor destination, and log destination state, so those reset on every presentation while the VM's loaded directory/list remains. Replace the old fixed 296-point session-actions detent with `.medium` or a measured custom height that demonstrably contains all three rows, then assert the new row is hittable in UI tests. Keep the map alive while `TerminalScreen` is alive; dismissing the sheet must not destroy the VM. On terminal page destruction, let the map disappear with the page. Do not reuse or mutate `HostDetailView`'s VM.

- [ ] **Step 5: Add only non-localized accessibility identifiers if required.** Identify the browser root/current breadcrumb/directory rows with stable identifiers for XCUITest; do not add duplicate user-facing strings or bypass `L()`.

- [ ] **Step 6: Run the focused source tests and build.**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/AppWideUIConsistencyTests
```

- [ ] **Step 7: Commit terminal routing.**

```bash
git add Conn/Conn/Terminal/TerminalScreen.swift Conn/Conn/Files/FileBrowserView.swift Conn/ConnTests/AppWideUIConsistencyTests.swift
git commit -m "feat: open file manager from terminal sessions"
```

### Task 5: Add end-to-end UI regression coverage

**Files:**

- Create or modify: `Conn/ConnUITests/TerminalFileBrowserUITests.swift`
- Modify: `Conn/ConnUITests/TerminalKeybarLayoutUITests.swift` only if shared action-sheet assertions should include the new row

- [ ] **Step 1: Write the Pro UI tests.** Launch the existing demo with `CONN_DEMO=1`, `CONN_SUBSCRIPTION_STATE=pro`, and `CONN_SMOKE_TERMINAL=1`. Open session actions, tap `terminal.session-actions.files`, verify the file browser sheet, navigate from `/` into the mock `home` directory, dismiss the sheet, reopen it from the same terminal, and verify the `home` directory remains selected. Verify that the third action row is visible and hittable despite the old sheet-height constraint. Do not rely on a newly added user-visible debug string.

- [ ] **Step 2: Add deterministic isolation and source tests.** Through the existing terminal/session UI, create or switch to a second terminal session, open its file manager, and assert it begins independently at `/` (or its own known directory). Reopen the first session and verify its `home` state remains unchanged. Add a deterministic demo fixture/launch flag if the current smoke launch does not expose a Docker console with a non-root OSC 7 report; use that fixture to prove a Docker terminal still opens the host file browser at `/`, even when the terminal reports a non-root container path. Also cover that the host-detail browser and terminal browser do not share state, that search/sort/editor/log presentation state resets on a sheet reopen, that the retained VM's prompt state is cleared before reopening, and that destroying/recreating the terminal page does not restore the old VM.

- [ ] **Step 3: Add the free/paywall UI tests.** Launch the same demo with `CONN_SUBSCRIPTION_STATE=free`, then with `loading` and `unavailable` if the existing demo subscription switch supports those states, open the terminal action sheet, tap the file-management row, and assert the existing file-management paywall appears while the terminal page remains alive in every fail-closed state. If the current live store cannot deterministically expose `unavailable`, add a test-only fixed unavailable snapshot at the app composition boundary rather than changing production entitlement semantics.

- [ ] **Step 4: Run only the relevant UI tests on the current simulator.**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnUITests/TerminalFileBrowserUITests \
  -only-testing:ConnUITests/TerminalKeybarLayoutUITests
```

Expected: PASS with the user’s already running iPhone 17 Pro; do not start, clone, restart, or close any simulator.

- [ ] **Step 5: Commit UI coverage.**

```bash
git add Conn/ConnUITests
git commit -m "test: cover terminal file manager flow"
```

### Task 6: Full verification and delivery checkpoint

**Files:**

- Verify all changed files; no additional production changes unless a test exposes a real regression.

- [ ] **Step 1: Run package tests.**

```bash
swift test --package-path Packages/ConnPackages
```

- [ ] **Step 2: Run the complete app test target on the exact booted simulator.**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests
```

- [ ] **Step 3: Run the terminal UI regression suite again if the full test run does not include it.** Use the Task 5 command and record any environment-only failure explicitly.

- [ ] **Step 4: Inspect the final diff.** Run `git diff --check`, review that only terminal file-manager behavior and its tests changed, confirm no localization key is missing, and verify HostDetail’s VM ownership remains independent.

- [ ] **Step 5: Report evidence.** Include the exact commands, simulator UDID, pass/fail results, changed behavior, and any test limitation. Do not claim completion if required tests were not executed or failed.
