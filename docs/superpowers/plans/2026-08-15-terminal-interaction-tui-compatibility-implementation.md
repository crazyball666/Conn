# Terminal Interaction and TUI Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver deterministic touch scrolling and draggable local selection for ordinary PTYs, tmux attachments, and modern full-screen TUIs while keeping backend-specific history and control behind an optional provider interaction facet.

**Architecture:** `ConnTerminal` owns UIKit normalization, protocol-state observation, a pure scroll router, gesture arbitration, and a frozen review surface. `ConnMultiplexer` owns provider-neutral interaction contracts and the tmux implementation, including verified pane state, typed mode scrolling, and bounded history capture. SwiftTerm remains the emulator and mouse encoder; a repository-owned vendor copy exposes only the small host hooks that Conn cannot express through its current public API.

**Tech Stack:** Swift 5 language mode, Swift Testing, SwiftUI, UIKit, SwiftTerm 1.15.0 (`dd2fb8ac5b861e7bf617c872895e338f38165648`), Conn SSH abstractions, tmux Control Mode and guarded one-shot commands.

**Execution constraint:** The user explicitly requested implementation directly on `main`. Do not create a branch or worktree. Preserve the pre-existing unstaged `Conn/Conn/Localizable.xcstrings` change and never stage it.

**Baseline:** `swift test` in `Packages/ConnPackages` passes 830 tests in 128 suites before implementation.

**Canonical simulator gate:** Every simulator test command in this plan must run the following gate and `xcodebuild` in the same shell invocation. If the gate cannot connect to CoreSimulatorService, finds zero devices, or finds more than one booted device, stop simulator work and report the condition. Never boot, clone, restart, shut down, or select another simulator.

```bash
set -euo pipefail
BOOTED_UDIDS="$(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-Fa-f-]{36})\) \(Booted\).*/\1/p')"
BOOTED_COUNT="$(printf '%s\n' "$BOOTED_UDIDS" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$BOOTED_COUNT" -ne 1 ]; then
  echo "Expected exactly one already-booted simulator, found $BOOTED_COUNT" >&2
  exit 64
fi
BOOTED_UDID="$BOOTED_UDIDS"
xcodebuild test \
  -workspace Conn.xcworkspace \
  -scheme Conn \
  -destination "platform=iOS Simulator,id=$BOOTED_UDID" \
  -only-testing:ConnTests/AppWideUIConsistencyTests
```

---

## File Map

### Vendor dependency

- Create `Packages/Vendor/SwiftTerm/` from upstream tag `v1.15.0` at commit `dd2fb8ac5b861e7bf617c872895e338f38165648`.
- Create `Packages/Vendor/SwiftTerm/CONN_UPSTREAM.md` recording upstream URL, tag, commit, and Conn-only patches.
- Modify `Packages/ConnPackages/Package.swift` to use `.package(path: "../Vendor/SwiftTerm")`.
- Modify the minimum SwiftTerm files needed for host-managed touch hooks and typed paste; do not edit `.build/checkouts`.

### ConnTerminal domain and host layer

- Delete `Packages/ConnPackages/Sources/ConnTerminal/TerminalPanGesturePolicy.swift`.
- Delete `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalPanGesturePolicyTests.swift`.
- Create `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteraction.swift` for protocol state, intents, modes, route tokens, and the pure router.
- Create `Packages/ConnPackages/Sources/ConnTerminal/TerminalScrollAccumulator.swift` for pixel-to-row conversion and bounded coalescing.
- Create `Packages/ConnPackages/Sources/ConnTerminal/TerminalReviewSnapshot.swift` for immutable review text, truncation, and sanitization.
- Create `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteractionController.swift` for the main-actor state machine and executor boundary.
- Create `Packages/ConnPackages/Sources/ConnTerminal/TerminalReviewTextView.swift` for the read-only selectable UIKit review surface.
- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift` to wire stable gestures, routing, review, paste, focus, and clipboard policy.
- Create corresponding tests under `Packages/ConnPackages/Tests/ConnTerminalTests/`.

### Provider-neutral persistent interaction

- Create `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalInteraction.swift` for optional interaction facets, state freshness, history requests/snapshots, and typed scroll requests.
- Create `Packages/ConnPackages/Tests/ConnMultiplexerTests/PersistentTerminalInteractionTests.swift`.

### tmux interaction implementation

- Modify `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshot.swift` to carry interaction-relevant pane state.
- Modify `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshotAssembler.swift`, `TmuxSnapshotCodec.swift`, and `TmuxSnapshotQuery.swift` to read `alternate_on`, `pane_in_mode`, `pane_mode`, `mouse_any_flag`, `history_size`, and `history_limit`.
- Create `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxInteraction.swift` for mode classification, typed interaction commands, guarded rendering, state projection, and bounded history parsing.
- Modify `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxOperation.swift`, `TmuxControlCommandRenderer.swift`, and `TmuxShellInvocationRenderer.swift` for typed copy/view-mode scrolling.
- Modify `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProviderControlRuntimeRegistry.swift` and `TmuxControlHub.swift` to resolve the identity lease's current pane without exposing raw commands.
- Modify `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift` so `TmuxPassthroughAttachment` exposes and owns the optional interaction facet.
- Add focused tmux tests under `Packages/ConnPackages/Tests/ConnMultiplexerTests/`.

### App wiring

- Modify `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionStore.swift` only if a typed computed interaction accessor is needed; do not persist new state.
- Modify `Conn/Conn/Terminal/TerminalScreen.swift` to pass the optional interaction facet and tab generation into `TerminalHostingView`.
- Modify `Conn/ConnTests/TerminalLayoutTests.swift` and `Conn/ConnTests/AppWideUIConsistencyTests.swift` for the new host contract.

---

### Task 1: Establish the pinned SwiftTerm host boundary

**Files:**
- Create: `Packages/Vendor/SwiftTerm/**`
- Create: `Packages/Vendor/SwiftTerm/CONN_UPSTREAM.md`
- Modify: `Packages/ConnPackages/Package.swift`
- Modify: `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift`
- Test: `Packages/Vendor/SwiftTerm/Tests/SwiftTermTests/TerminalTests.swift` or a new focused test file when the API is platform-neutral

- [ ] **Step 1: Add a dependency-boundary test that fails while ConnPackages still declares remote SwiftTerm**

Add a source-contract assertion in `Conn/ConnTests/AppWideUIConsistencyTests.swift` that requires:

```swift
#expect(packageSource.contains(#".package(path: "../Vendor/SwiftTerm")"#))
#expect(!packageSource.contains("github.com/migueldeicaza/SwiftTerm"))
```

- [ ] **Step 2: Run the focused app test and verify RED**

Run the canonical simulator gate with `-only-testing:ConnTests/AppWideUIConsistencyTests`. Expected: the SwiftTerm dependency assertion fails because `Package.swift` still uses the remote URL. If the gate fails, record the app-test RED step as unavailable and do not perform any other simulator action.

- [ ] **Step 3: Vendor the exact source and switch the package dependency**

Copy the upstream working tree without `.git` or build products, preserve `LICENSE`, and write `CONN_UPSTREAM.md` with:

```text
upstream=https://github.com/migueldeicaza/SwiftTerm
tag=v1.15.0
commit=dd2fb8ac5b861e7bf617c872895e338f38165648
```

Switch only the dependency declaration; keep the product name `SwiftTerm` unchanged.

- [ ] **Step 4: Add the minimum host API**

Expose high-level APIs instead of internals:

```swift
public struct TerminalInteractionHit: Sendable, Equatable {
    public let column: Int
    public let row: Int
    public let pixelX: Int
    public let pixelY: Int
}

public func interactionHit(at point: CGPoint) -> TerminalInteractionHit
public func paste(text: String)
public func beginHostSelection(at point: CGPoint, granularity: SelectionGranularity)
public func extendHostSelection(to point: CGPoint)
public func finishHostSelection(showMenu: Bool)
```

Also expose an emulator-owned protocol snapshot, monotonic revision, change callback, typed input operations, and immutable buffer snapshots:

```swift
public struct TerminalHostProtocolState: Sendable, Equatable {
    public let revision: UInt64
    public let isAlternateBuffer: Bool
    public let mouseMode: Terminal.MouseMode
    public let mouseEncoding: TerminalMouseEncoding
    public let bracketedPasteEnabled: Bool
    public let focusReportingEnabled: Bool
    public let synchronizedOutputEnabled: Bool
    public let columns: Int
    public let rows: Int
}

public var hostProtocolState: TerminalHostProtocolState { get }
public var onHostProtocolStateChanged: ((TerminalHostProtocolState) -> Void)? { get set }
public func sendHostWheel(direction: TerminalWheelDirection, count: Int,
                          at hit: TerminalInteractionHit, modifiers: TerminalModifiers)
public func sendHostPointer(_ event: TerminalPointerEvent, at hit: TerminalInteractionHit,
                            modifiers: TerminalModifiers)
public func sendHostCursorKey(_ direction: TerminalCursorDirection, count: Int)
public func makeHostSnapshot(_ scope: TerminalSnapshotScope) -> TerminalBufferSnapshot
```

SwiftTerm increments the revision when buffer kind, mouse tracking/encoding, bracketed paste, focus reporting, synchronized output, application-cursor mode, or dimensions change. Typed wheel/pointer methods always use the emulator's active encoding and clamp coordinates. Typed cursor keys choose CSI or SS3 from the emulator's current application-cursor state and apply a bounded repeat count. `.visible` snapshots include the active viewport; `.normalHistory` snapshots include bounded normal-buffer scrollback and return immutable text/style values plus cell-column-to-text-offset maps rather than live `Buffer` references.

Add a host-managed gesture flag that prevents SwiftTerm from installing its touch mouse/selection pan recognizers when Conn owns those gestures. Keep default behavior unchanged for other embedders. This flag must not disable UIKit indirect-pointer events or the typed host pointer API.

Enforce the OSC 52 write limit inside vendored `Sources/SwiftTerm/Terminal.swift`, before materializing `Data(payload)` or attempting Base64 decode. Bound both the accepted encoded length and the maximum decoded size; reject an oversized or malformed payload without invoking the delegate. Keep Conn's clipboard policy limit as defense in depth, not as the parser's primary allocation boundary.

- [ ] **Step 5: Add SwiftTerm tests for paste framing, bounded OSC 52, and default-compatible host mode**

Verify bracketed mode wraps exactly once, state revisions change for every routing-relevant protocol transition, snapshots are immutable, mouse wheel/pointer operations use the active encoding, cursor keys switch between CSI and SS3 correctly, and default host-managed mode remains disabled. Add OSC 52 parser tests proving an oversized encoded payload is rejected before Base64 decoding/allocation, an encoded payload whose decoded upper bound exceeds the configured limit is rejected, a bounded valid payload reaches the delegate, and malformed input is ignored. Platform-specific selection hooks are verified by the Conn app test target.

- [ ] **Step 6: Run vendor tests and ConnPackages tests**

Run:

```bash
swift test --package-path Packages/Vendor/SwiftTerm
swift test --package-path Packages/ConnPackages
```

Expected: both pass; ConnPackages resolves the local SwiftTerm package.

- [ ] **Step 7: Commit Task 1**

Commit only the vendor tree, package dependency, and dependency-boundary test.

---

### Task 2: Build the pure terminal interaction model

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteraction.swift`
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalScrollAccumulator.swift`
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalInteractionTests.swift`
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalScrollAccumulatorTests.swift`
- Delete: `Packages/ConnPackages/Sources/ConnTerminal/TerminalPanGesturePolicy.swift`
- Delete: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalPanGesturePolicyTests.swift`

- [ ] **Step 1: Write the exhaustive router tests first**

Cover this exact order:

```swift
selection -> pointer -> remoteMouse -> providerScrollableMode
-> providerKeyDrivenMode -> providerUnsupportedBoundary
-> providerAlternateKeys -> providerHistory
-> plainAlternateKeys -> localNormalBuffer -> boundary
```

Include stale provider state returning `.resolvePersistentState`, and prove an attachment or protocol revision mismatch invalidates the route token.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter TerminalInteractionTests
```

Expected: compile failure because the new interaction types do not exist.

- [ ] **Step 3: Implement the minimum pure types and router**

Implement the design types without UIKit imports:

```swift
public struct TerminalProtocolState: Sendable, Equatable { ... }
public enum TerminalInteractionMode: Sendable, Equatable { ... }
public enum TerminalScrollAction: Sendable, Equatable { ... }
public struct TerminalRouteToken: Sendable, Equatable { ... }
public struct TerminalScrollRouter: Sendable {
    public func route(_ input: TerminalScrollRouteInput) -> TerminalScrollAction
}
```

Use capability values, never process names or `providerID == "tmux"` branches in ConnTerminal.

- [ ] **Step 4: Write accumulator tests and verify RED**

Test fractional row retention, direction reversal, per-frame cap, pending cap, physical-wheel minimum, and generation cancellation.

- [ ] **Step 5: Implement the bounded accumulator and coalescer**

Keep constants internal and testable. Do not persist sensitivity or caps.

- [ ] **Step 6: Run all ConnTerminal tests and verify GREEN**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter ConnTerminalTests
```

- [ ] **Step 7: Commit Task 2**

Commit the pure interaction layer and removal of the obsolete all-auxiliary-pan policy.

---

### Task 3: Add the optional persistent interaction facet

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalInteraction.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/PersistentTerminalInteractionTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProvider.swift`

- [ ] **Step 1: Write protocol-contract tests first**

Use a fake attachment to prove:

- base attachments need not implement interaction;
- interactive attachments expose exactly one facet;
- state streams use bounded buffering;
- history requests reject non-positive line/byte limits;
- scroll requests reject zero or excessive row counts;
- generations and target identity are explicit values.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter PersistentTerminalInteractionTests
```

- [ ] **Step 3: Implement provider-neutral contracts**

Define:

```swift
public protocol PersistentTerminalInteractiveAttachment: PersistentTerminalAttachment {
    var interaction: any PersistentTerminalInteractionFacet { get }
}

public protocol PersistentTerminalInteractionFacet: AnyObject, Sendable {
    var states: AsyncStream<PersistentTerminalInteractionState> { get }
    func resolveState() async throws -> PersistentTerminalInteractionState
    func captureHistory(_ request: PersistentTerminalHistoryRequest) async throws
        -> PersistentTerminalHistorySnapshot
    func scrollProviderMode(_ request: PersistentTerminalModeScrollRequest) async throws
}
```

Keep every type independent of UIKit, SwiftUI, and SwiftTerm.

- [ ] **Step 4: Run ConnMultiplexer tests and verify GREEN**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter ConnMultiplexerTests
```

- [ ] **Step 5: Commit Task 3**

---

### Task 4: Extend normalized tmux state for interaction routing

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshot.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshotAssembler.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshotCodec.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshotQuery.swift`
- Modify tests: `TmuxSnapshotTests.swift`, `TmuxSnapshotAssemblerTests.swift`, `TmuxSnapshotCodecTests.swift`, `TmuxSnapshotQueryTests.swift`

- [ ] **Step 1: Add failing codec/query tests for six pane fields**

The pane record must include:

```text
alternate_on
pane_in_mode
pane_mode
mouse_any_flag
history_size
history_limit
```

Test modern quoted and legacy per-field plans. Treat absent optional formats as unavailable metadata, not as false.

- [ ] **Step 2: Run snapshot tests and verify RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter TmuxSnapshot
```

- [ ] **Step 3: Extend the normalized model and assemblers**

Add a single `TmuxPaneInteractionSnapshot` value to `TmuxPaneSnapshot` so management fields do not sprawl:

```swift
public struct TmuxPaneInteractionSnapshot: Sendable, Equatable {
    public let alternateOn: TmuxObservedValue<Bool>
    public let mode: TmuxObservedValue<String>
    public let paneInMode: TmuxObservedValue<Bool>
    public let mouseAnyFlag: TmuxObservedValue<Bool>
    public let historySize: TmuxObservedValue<Int>
    public let historyLimit: TmuxObservedValue<Int>
}
```

Validate non-negative history values and preserve freshness.

- [ ] **Step 4: Extend event reconciliation only for fields tmux can subscribe to**

Do not invent subscriptions. Fields unavailable through Control Mode events stay snapshot-fresh and trigger bounded refresh on gesture start.

- [ ] **Step 5: Run all tmux snapshot/reducer tests and verify GREEN**

- [ ] **Step 6: Commit Task 4**

---

### Task 5: Implement tmux state, mode scrolling, and immutable history capture

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxInteraction.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxOperation.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlCommandRenderer.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxShellInvocationRenderer.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlHub.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProviderControlRuntimeRegistry.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift`
- Create tests: `TmuxInteractionTests.swift`
- Modify tests: `TmuxProviderControlRuntimeRegistryTests.swift`, `TmuxControlCommandRendererTests.swift`, `TmuxProviderTests.swift`

- [ ] **Step 1: Write failing mode-classification tests**

Test:

- copy/view modes that accept `send-keys -X` -> `.scrollable`;
- documented key-table choose/tree modes -> `.keyDriven`;
- unknown mode -> `.unsupported`;
- outer mouse tracking remains separate and higher priority;
- stale state is not treated as fresh.

- [ ] **Step 2: Write failing typed-command rendering tests**

Add a closed operation:

```swift
case scrollPaneMode(TmuxPaneID, direction: TmuxScrollDirection, rows: Int)
```

Render exactly one validated target, bounded `-N`, and `scroll-up` or `scroll-down`. Mark it non-idempotent so uncertain dispatch is never retried.

- [ ] **Step 3: Implement mode projection and typed scrolling**

Resolve the data attachment's `TmuxControlInteractiveIdentity` through its registry registration. Validate scope, hub generation, current client, active pane, and server token immediately before dispatch.

Replace the current identity-only attachment registration with an attachment-scoped interaction lease:

```swift
struct TmuxProviderControlInteractionLease: Sendable {
    let registry: TmuxProviderControlRuntimeRegistry
    let scope: TmuxOperationScope
    let registrationID: UUID
    let snapshots: AsyncStream<TmuxServerSnapshot>
}
```

Acquisition atomically creates both the identity lease and an observation lease targeted at `.session(requestedSessionID)`. The observation lease keeps `TmuxControlHubStatus.requiresControlRuntime` true, so the runtime cannot be evicted while the interactive attachment is open. Registry methods resolve current state and dispatch interaction operations by `registrationID` inside the registry actor; callers never receive a raw hub or command channel. Release removes both leases before evaluating eviction. Runtime restoration reacquires both leases and reconnects the bounded snapshot stream without changing attachment identity.

- [ ] **Step 4: Write failing one-shot state-query tests**

When Control Mode is absent, render one token-guarded POSIX invocation that identifies the same data client by verified tty/PID, emits one bounded framed row, and returns the active pane interaction state. Test malformed frames, duplicate rows, changed server identity, output limits, and missing client.

- [ ] **Step 5: Implement the degraded read-only state query**

Use the existing prepared remote script runtime, executable, locator, and scope. Do not accept raw tmux text from UI callers.

- [ ] **Step 6: Write failing immutable history tests**

Verify:

- the active pane is resolved once and pinned;
- requested lines are clamped by `history_size`, configured limit, and a hard byte cap;
- capture runs once for the selected range;
- output arriving afterward cannot mutate the returned snapshot;
- truncation is explicit;
- OSC/DCS/APC/PM and invalid UTF-8 cannot become executable terminal input.

- [ ] **Step 7: Implement bounded `capture-pane`**

Use a separate typed read-only renderer and executor. Capture plain text by default; if styling is retained, parse only supported SGR into the neutral line model. Never feed capture output into SwiftTerm.

- [ ] **Step 8: Make `TmuxPassthroughAttachment` interactive**

The attachment owns a `TmuxInteractionFacet`, installs its `TmuxProviderControlInteractionLease` when Control Mode becomes available, and closes/releases both the facet state stream and interaction lease with the attachment. The base presentation stays `.byteTerminal`. Tests must prove an open interactive attachment keeps Control Mode alive and close permits eviction.

- [ ] **Step 9: Run focused and full ConnMultiplexer tests**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter TmuxInteractionTests
swift test --package-path Packages/ConnPackages --filter ConnMultiplexerTests
```

- [ ] **Step 10: Commit Task 5**

---

### Task 6: Build safe review snapshots and a selectable review surface

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalReviewSnapshot.swift`
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalReviewTextView.swift`
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalReviewSnapshotTests.swift`
- Modify: `Conn/ConnTests/TerminalLayoutTests.swift`

- [ ] **Step 1: Write failing sanitizer and snapshot tests**

Test line/byte caps, explicit truncation, malformed UTF-8 replacement, newline normalization, generation identity, and stripping of OSC/DCS/APC/PM/C0 controls except tab/newline.

- [ ] **Step 2: Run focused tests and verify RED**

- [ ] **Step 3: Implement immutable review values and sanitizer**

Keep the parser pure and backend-neutral. Add adapters from SwiftTerm `.visible` and `.normalHistory` snapshots and from `PersistentTerminalHistorySnapshot`. Preserve the captured viewport and a per-line terminal-cell-to-string-index map so a long-press location can initialize a stable native text selection without reading mutable live cells. Store no terminal history in SQLite or analytics.

- [ ] **Step 4: Add a read-only `UITextView` review surface**

Configure:

```swift
isEditable = false
isSelectable = true
alwaysBounceVertical = true
textContainer.lineFragmentPadding = 0
font = terminal monospaced font
```

Use native iOS selection handles, magnifier, drag extension, edge autoscroll, Copy, and Select All. The overlay blocks touch but not byte parsing in the underlying SwiftTerm view.

- [ ] **Step 5: Add source-contract/UI construction tests**

Assert the surface remains selectable and non-editable and has an explicit close affordance. Run the canonical simulator gate with `-only-testing:ConnTests/TerminalLayoutTests`; if unavailable, stop simulator operations and retain the package-level sanitizer RED/GREEN evidence.

- [ ] **Step 6: Run ConnTerminal and app tests, then commit Task 6**

---

### Task 7: Wire the coordinator, stable gestures, scrolling, and selection

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteractionController.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionStore.swift` if needed for a computed facet accessor
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalInteractionControllerTests.swift`
- Modify: `Conn/ConnTests/TerminalLayoutTests.swift`
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] **Step 1: Write state-machine tests first**

Cover live/review/select/pointer transitions, single/double/triple tap semantics, local-first `Esc`, reconnect/pane-change cancellation, and route pinning across fling.

- [ ] **Step 2: Run focused tests and verify RED**

- [ ] **Step 3: Implement the main-actor coordinator**

The coordinator owns state only. Async provider work runs in cancellable tasks guarded by route token and tab/provider generation.

- [ ] **Step 4: Replace global pan rejection with stable host gestures**

Install once:

- native SwiftTerm scroll pan for local normal-buffer history;
- one Conn remote scroll pan for wheel/keys/provider history;
- one long press for local selection and drag extension;
- one pointer pan enabled only in explicit pointer mode;
- two-finger wheel path while pointer mode is active.

Register indirect-pointer handling separately from touch pans. Hardware mouse primary press/motion/release must call the typed SwiftTerm pointer API whenever the remote application requests mouse reporting, without requiring touch pointer mode. Touch pointer mode gates only direct-finger primary drag. Add an input-source test proving the two paths do not share that gate.

Set failure/simultaneous-recognition relationships explicitly. Never discover recognizers by array order.

- [ ] **Step 5: Implement scroll execution**

- `.localBuffer`: leave native pan enabled and do not emit bytes;
- `.remoteWheel`: use SwiftTerm's active mouse encoder and pinned cell;
- `.remoteCursorKeys`: call SwiftTerm's typed cursor-key operation so application-cursor CSI/SS3 state is honored;
- `.persistentModeScroll`: invoke the facet;
- `.persistentHistory`: capture once and present the review overlay;
- `.resolvePersistentState`: resolve once, validate token, replay bounded initial rows.

- [ ] **Step 6: Implement local selection behavior**

Long press first freezes content, then starts local selection on the review surface:

- normal-buffer PTY: request `.normalHistory`, preserving the captured viewport;
- plain alternate-screen TUI: request `.visible`;
- persistent normal pane: request one immutable provider history capture;
- persistent alternate-screen TUI: request the emulator `.visible` snapshot rather than reconstructing application-private history.

Convert the pressed terminal cell through the snapshot's cell-to-text map and initialize the native `UITextView` selection there. The live SwiftTerm remains attached and continues parsing output under the overlay. Double tap selects a word, triple tap a row. Pointer mode owns remote multi-click and drag. Movement before long-press recognition lets scrolling win. Reconnect, pane/provider generation change, resize generation change, or tab closure dismisses the frozen session.

- [ ] **Step 7: Add visible pointer-mode and review controls**

Show pointer mode only while mouse button reporting is available. The control must be explicit, indicate active state, and exit on local `Esc`, reconnect, tab leave, or capability loss. Review has an explicit close button and non-blocking retry message for unavailable history.

- [ ] **Step 8: Pass the optional facet from the active tab**

Use protocol casting only:

```swift
(tab.persistentAttachment as? any PersistentTerminalInteractiveAttachment)?.interaction
```

Do not branch on tmux in `TerminalScreen` or `TerminalHostingView`.

- [ ] **Step 9: Run package and app tests, then commit Task 7**

Run package tests first, then run the canonical simulator gate twice with:

```text
-only-testing:ConnTests/TerminalLayoutTests
-only-testing:ConnTests/AppWideUIConsistencyTests
```

If the simulator gate is unavailable, do not substitute another destination; report the app-test portion as unexecuted.

---

### Task 8: Complete modern TUI protocol behavior

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalReplayOutboundGate.swift` or add a focused provenance type
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalClipboardPolicy.swift`
- Create tests: `TerminalClipboardPolicyTests.swift`, `TerminalPasteTests.swift`

- [ ] **Step 1: Write failing bracketed-paste tests**

Prove keybar and system paste both call one typed paste path and bracket only when mode 2004 is active.

- [ ] **Step 2: Implement typed paste**

Do not send keybar paste as raw UTF-8 and do not apply sticky Ctrl encoding to paste payloads.

- [ ] **Step 3: Write failing focus and provenance tests**

Prove terminal focus follows first-responder/app-active state and that transcript replay can render OSC 52 without changing the clipboard or returning clipboard data.

- [ ] **Step 4: Implement feed provenance and focus reporting**

Tag replay/live/generation-boundary feeds in the controller. Only current live bytes may invoke host side effects. Keep protocol response suppression during replay.

- [ ] **Step 5: Write failing OSC 52 policy tests**

Cover bounded valid write, malformed/oversized write as a defense-in-depth Conn rejection, denied read, 30-second one-shot read authority, consumption on failure, session-generation scope, clearing on background/tab/reconnect/close, and the UI action that grants exactly one token. The allocation boundary itself is tested in vendored SwiftTerm in Task 1 before its OSC 52 delegate callback.

- [ ] **Step 6: Implement clipboard policy**

Use `UIPasteboard` only on the main actor. Never log clipboard content. Surface a content-free “Copied” indication. Add an explicit terminal actions menu item labeled “Allow clipboard read once”; invoking it grants the policy token for the current session and attachment generation, shows its 30-second/one-use scope, and never sends terminal bytes. The item is the only grant path. Implement actual read authority without granting or renewing it from terminal output.

- [ ] **Step 7: Verify OSC 11 and synchronized output remain delegated to SwiftTerm**

Add regression assertions where needed; do not duplicate the emulator parser in Conn.

- [ ] **Step 8: Run focused tests and commit Task 8**

---

### Task 9: End-to-end verification and final review

**Files:**
- Modify tests only if a genuine uncovered regression is found.
- Update checkboxes in this plan.

- [ ] **Step 1: Run the full package suite**

Run:

```bash
swift test --package-path Packages/Vendor/SwiftTerm
swift test --package-path Packages/ConnPackages
```

Expected: zero failures; skipped real-host tests remain explicitly skipped unless credentials are already configured.

- [ ] **Step 2: Build the iOS app**

Run:

```bash
xcodebuild build -workspace Conn.xcworkspace -scheme Conn
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run UI/unit tests only on the user's already-booted simulator**

Run the canonical simulator gate with both `-only-testing:ConnTests/TerminalLayoutTests` and `-only-testing:ConnTests/AppWideUIConsistencyTests` in the same `xcodebuild test` invocation. The gate itself requires exactly one booted UDID. If unavailable, stop simulator work and report it; never boot, clone, restart, or switch devices.

- [ ] **Step 4: Perform manual interoperability acceptance when reachable**

Verify ordinary shell, tmux shell history, tmux copy-mode, Claude Code, Hermes wheel/buttons/all, vim/less/htop, touch selection, hardware pointer, reconnect, and pane changes. If external hosts or apps are unavailable, report those cases as unexecuted rather than claiming them.

- [ ] **Step 5: Run repository hygiene checks**

Run:

```bash
git diff --check
git status --short
```

Confirm `Conn/Conn/Localizable.xcstrings` remains the user's unstaged change and is absent from every implementation commit.

- [ ] **Step 6: Request final spec-compliance and code-quality review**

Only fix issues that are blocking or materially affect correctness, security, or extensibility.

- [ ] **Step 7: Commit final verification adjustments**

Do not push unless the user asks.
