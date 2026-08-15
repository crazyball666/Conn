# Terminal Interaction and TUI Compatibility Design

**Date:** 2026-08-15
**Status:** Confirmed product direction; ready for implementation planning after review
**Scope:** iOS terminal scrolling, local text selection, remote mouse interaction, tmux history, and modern full-screen TUI compatibility

## 1. Summary

Conn will replace the current “allow the native pan and reject every auxiliary pan” rule with one capability-driven terminal interaction layer. The user experience is consistent across ordinary PTYs, tmux attachments, Claude Code, Hermes Agent, vim, less, htop, and future persistent-terminal providers, while each backend uses the history and input mechanisms it actually owns.

The design follows established behavior rather than identifying applications by process name:

- Termux-style touch routing: mouse tracking sends wheel events, alternate screen without mouse sends cursor keys, otherwise the emulator scrolls local history;
- SwiftTerm macOS-style line accumulation, mouse encoding, and scroll kinetics;
- tmux’s documented `mouse_any_flag` → `pane_in_mode` → `alternate_on` → copy-mode routing;
- explicit separation between touch scrolling, local selection, and remote pointer dragging;
- an optional provider facet for persistent history and provider-owned interaction state.

Long press always starts local text selection. One-finger vertical movement scrolls by default. Touch-based remote left-button dragging is available only in an explicit pointer mode; hardware mouse dragging retains normal terminal mouse semantics.

No database migration is required. Runtime terminal state, tmux snapshots, history review content, selections, and clipboard payloads remain in memory.

## 2. Problem

`KeybarTerminalView` currently allows only the inherited `UIScrollView.panGestureRecognizer` and rejects all other pan recognizers. SwiftTerm dynamically installs a selection pan after a word or line is selected and a mouse pan when a remote application requests mouse reporting. Rejecting both fixed ordinary PTY scrolling but deliberately removed drag-to-extend selection and remote mouse drag.

The same fix cannot make tmux scroll. A normal shell writes into SwiftTerm’s normal buffer, which has local scrollback. A pass-through `tmux attach-session` uses the alternate buffer, which intentionally has no emulator scrollback; tmux owns the pane history on the remote server. The current view receives only a byte terminal and has no interaction facet capable of reading or scrolling that remote history.

Modern TUIs make this distinction more important:

- Claude Code supports a full-screen alternate-screen renderer, mouse wheel interaction, a mode that disables mouse clicks while preserving wheel scrolling, and an opt-out that returns to native terminal scrollback.
- Hermes Agent’s TUI uses alternate-screen differential rendering, SGR mouse modes, separate `wheel`, `buttons`, and `all` mouse presets, bracketed paste, OSC 52 clipboard operations, and OSC 11 background probing.
- tmux may wrap either TUI, so Conn must distinguish the outer tmux client state from the active pane’s alternate-screen and copy-mode state.

Application names are neither necessary nor reliable. The terminal protocol and provider state already expose the information needed to route interaction.

## 3. Industry Baseline

The implementation will use these behaviors as normative references:

1. **Termux mobile interaction**
   - long press enters an explicit selection mode;
   - selection mode consumes touch input;
   - touch scroll sends wheel events while mouse tracking is active;
   - alternate screen without mouse receives Up/Down;
   - normal buffer scrolls local transcript history;
   - fling preserves the route selected at gesture start and aborts if mouse state changes.

2. **SwiftTerm macOS interaction**
   - precise scroll deltas accumulate by terminal-cell height;
   - non-precise wheel notches move at least one row;
   - wheel events are encoded through the emulator’s active X10/UTF-8/SGR/URxvt/pixel protocol;
   - alternate screen without mouse receives cursor keys;
   - local normal-buffer history uses the native viewport.

3. **tmux interaction**
   - mouse-aware panes or panes already in a mode receive mouse/mode input;
   - an alternate-screen pane receives Up/Down when it does not own the mouse;
   - a normal pane enters or scrolls tmux history/copy-mode;
   - `alternate_on` and `pane_in_mode` are provider state, not inferred from the command name.

4. **Apple mobile terminal interaction**
   - touch selection and touch scrolling are separate intents;
   - remote pointer dragging is not allowed to silently take ownership of ordinary scrolling;
   - hardware pointer events retain desktop-like behavior.

## 4. Goals and Non-goals

### 4.1 Goals

- One-finger vertical scrolling works in ordinary PTYs, tmux shells, alternate-screen applications, Claude Code, Hermes, and nested TUI-in-tmux sessions.
- Long press creates a local selection and dragging extends it in ordinary PTYs and tmux terminals.
- Default touch scrolling never turns into remote left-button dragging merely because an application enabled mouse tracking.
- Remote taps, wheel events, and explicit pointer drags use the emulator’s active mouse encoding and coordinates.
- tmux history comes from the identified remote pane and never from fabricated outer-terminal scrollback.
- Live terminal processing continues while a frozen history/selection surface is visible.
- Provider-specific state and operations remain outside the terminal view.
- New persistent providers can add interaction capabilities without changing the terminal page or database schema.
- Modern TUI features such as bracketed paste, OSC 52, OSC 11, focus reporting, synchronized output, and resize remain functional.

### 4.2 Non-goals

- Native Claude Code or Hermes chat rendering.
- Reconstructing a full-screen TUI’s private virtual conversation history from repaint bytes.
- Identifying applications by executable name, title, prompt text, or terminal output heuristics.
- Persisting terminal history, tmux capture output, selection content, or clipboard content.
- Replacing the existing SSH transport or tmux data plane.
- Automatically changing users’ `.tmux.conf`, Hermes configuration, or Claude Code environment variables.
- Full native tmux pane rendering or a local clone of tmux copy-mode.

## 5. Product Interaction Rules

### 5.1 Default touch behavior

- A one-finger vertical drag scrolls.
- A quick tap focuses the terminal and, if the application requested button reporting, sends one remote primary-button click.
- A long press starts local selection and performs haptic feedback.
- Moving after long-press recognition extends the local selection.
- Double tap selects a word; triple tap selects a row.
- Local double/triple-tap selection takes precedence over remote multi-click. Remote double-click and drag are available in explicit pointer mode.
- Tapping outside an active selection exits selection mode.

### 5.2 Explicit pointer mode

- Pointer mode is visible in the terminal toolbar and cannot be enabled implicitly.
- One-finger touch drag sends remote primary-button press, motion, and release.
- Two-finger vertical movement continues to send wheel events.
- `Esc`, a toolbar action, leaving the tab, reconnecting, or losing mouse capability exits pointer mode.
- An `Esc` used to leave pointer, review, or selection mode is consumed locally. A subsequent `Esc` in live mode is sent to the remote application normally.
- Hardware mouse primary drag follows remote mouse reporting without requiring touch pointer mode.

### 5.3 Review and selection

- Local selection is rendered on a read-only `TerminalReviewSurface` when the live surface cannot safely keep selected cells stable.
- The live emulator remains attached and processes all incoming bytes beneath the review surface.
- Ordinary PTY review may include the emulator’s complete bounded local scrollback.
- tmux review uses one immutable, bounded capture of the selected pane.
- A full-screen TUI’s private virtual history is not reconstructed. The user scrolls the TUI to the desired page, then long-presses to select that visible page.
- Leaving review immediately reveals the already-current live terminal.

## 6. Architecture

### 6.1 `TerminalProtocolState`

The SwiftTerm adapter exposes a stable, read-only value containing:

```swift
public struct TerminalProtocolState: Sendable, Equatable {
    public let bufferKind: TerminalBufferKind
    public let mouseTracking: TerminalMouseTracking
    public let mouseEncoding: TerminalMouseEncoding
    public let bracketedPasteEnabled: Bool
    public let focusReportingEnabled: Bool
    public let synchronizedOutputEnabled: Bool
    public let columns: Int
    public let rows: Int
}
```

The adapter also exposes typed operations for wheel, button, motion, cursor keys, visible snapshots, local-history snapshots, paste, and selection. Conn never manually renders mouse escape sequences.

The required SwiftTerm changes are maintained as a repository-owned vendor fork under `Packages/Vendor/SwiftTerm`, pinned initially to the exact upstream 1.15.0 revision and referenced by local package path. The fork contains only protocol-state, side-effect provenance, snapshot, and host-managed interaction hooks; application- or provider-specific behavior remains in Conn. Each patch is kept as an isolated commit so upstream releases can be merged and the hooks can be proposed upstream independently. Generated package checkouts are never edited.

### 6.2 `TerminalInteractionIntent`

UIKit events are normalized before routing:

```swift
public enum TerminalInteractionIntent: Sendable, Equatable {
    case scroll(TerminalScrollGesture)
    case tap(TerminalCellPoint, count: TerminalTapCount, source: TerminalInputSource)
    case longPressBegan(TerminalCellPoint)
    case longPressChanged(TerminalCellPoint)
    case longPressEnded
    case pointerDrag(TerminalPointerGesture)
    case setPointerMode(Bool)
    case escape(source: TerminalInputSource)
    case cancel
}
```

`TerminalTapCount` is the bounded semantic value `.single`, `.double`, or `.triple`; UIKit recognizer details do not cross the boundary. Single tap may become a remote click, while double and triple tap always remain local word and row selection outside explicit pointer mode. Toolbar pointer toggles produce `setPointerMode`; they never synthesize terminal bytes.

No UIKit type crosses the interaction boundary.

### 6.3 `TerminalInteractionCoordinator`

The main-actor coordinator owns only the interaction state machine:

```swift
public enum TerminalInteractionMode {
    case live
    case reviewing(TerminalReviewSession)
    case selecting(TerminalReviewSession, TerminalSelectionState)
    case remotePointer
}
```

It snapshots route inputs at gesture start, asks the pure router for an action, and delegates execution. It also owns local mode transitions: `setPointerMode(true)` is accepted only while live and mouse button reporting is active; disabling it returns to live; `escape` first dismisses pointer/review/selection and is consumed, but in live mode it is delegated to terminal input. It does not perform SSH requests, parse tmux, encode mouse bytes, or render review content.

### 6.4 `TerminalScrollRouter`

The router is a pure value-level decision. Its inputs are:

- current interaction mode;
- `TerminalProtocolState`;
- optional persistent-provider interaction state and freshness;
- input source;
- attachment and provider generation.

Its output is one action:

```swift
public enum TerminalScrollAction: Sendable, Equatable {
    case localBuffer
    case remoteWheel
    case remoteCursorKeys
    case persistentHistory
    case persistentModeScroll
    case resolvePersistentState
    case boundary
}
```

### 6.5 Executors

- `LocalTerminalInteractionExecutor` performs synchronous emulator/view operations.
- `TerminalInputInteractionExecutor` sends emulator-encoded input through the current terminal session.
- `PersistentTerminalInteractionExecutor` performs typed, generation-guarded provider operations.
- `TerminalReviewController` creates and dismisses immutable review sessions.

High-frequency scroll decisions never await provider I/O on the main actor.

### 6.6 Persistent interaction facet

The base attachment protocol remains unchanged. Providers opt in through a separate protocol:

```swift
public protocol PersistentTerminalInteractiveAttachment:
    PersistentTerminalAttachment
{
    var interaction: any PersistentTerminalInteractionFacet { get }
}
```

The facet exposes a bounded state stream, a freshness-aware state query, immutable history capture, and provider-mode scrolling. Provider state classifies an active mode by capability as `.scrollable`, `.keyDriven`, or `.unsupported`, while retaining the provider-specific mode identifier for diagnostics. Its request and response types live in `ConnMultiplexer` and contain no UIKit or SwiftTerm types.

Ordinary PTYs have no persistent facet. Future Zellij, GNU Screen, or Windows providers implement only the capabilities they actually possess.

## 7. Gesture Ownership

Stable recognizers replace dynamic recognizer discovery:

1. SwiftTerm’s native scroll pan is enabled only for local normal-buffer scrolling.
2. Conn’s remote scroll pan is enabled when a gesture must produce wheel, cursor-key, or provider history actions.
3. One long-press recognizer starts selection and its `.changed` state extends selection; no dynamic selection pan is installed.
4. One pointer pan is enabled only in explicit touch pointer mode.

The long-press recognizer and the active scroll pan coexist before recognition. Movement beyond the long-press tolerance lets scrolling win immediately. Holding still lets long press begin; the coordinator then cancels the scroll route and owns subsequent movement as selection.

A gesture receives an immutable `TerminalRouteToken` containing terminal-state revision, attachment generation, provider generation, target pane, route, and starting cell. If any required state changes, the executor cancels the gesture. It never switches routes mid-gesture and never continues encoding mouse input after mouse reporting is disabled.

## 8. Scroll Routing

The exact priority order is:

1. Active local selection extends the selection and scrolls only the frozen review surface at its edges.
2. Explicit touch pointer mode performs pointer drag; two-finger input still requests wheel scrolling.
3. Active terminal mouse tracking sends emulator-encoded wheel events.
4. A persistent pane in a `.scrollable` provider mode performs provider-mode scrolling.
5. A persistent pane in a `.keyDriven` provider mode receives bounded Up/Down through the live attached client so the provider's active key table handles it.
6. A persistent pane in an `.unsupported` provider mode resolves to a non-input boundary response; Conn never guesses a command.
7. A persistent alternate-screen pane receives Up/Down through the live input channel.
8. A persistent normal pane opens or scrolls its immutable history review.
9. A non-persistent alternate screen receives Up/Down.
10. A normal buffer with local history uses native viewport scrolling.
11. Otherwise the interaction resolves to a non-input boundary response.

For tmux, outer mouse tracking takes priority because tmux itself is then responsible for forwarding the event to the pane application or entering copy-mode according to its bindings. When outer mouse tracking is off, provider `pane_in_mode` and `alternate_on` disambiguate copy-mode, a nested TUI, and a normal shell.

If persistent state is missing or stale at gesture start, the router returns `resolvePersistentState`. The provider performs one read-only query, validates the same server/client/pane generation, and then replays only the bounded accumulated initial delta. It never guesses and never sends Up/Down into a shell based on stale state.

## 9. Scroll Kinetics and Backpressure

- Pixel movement is accumulated and converted to whole terminal rows using current cell height.
- Fractional remainder is retained for the next event.
- A physical wheel notch always produces at least one row.
- Wheel coordinates are pinned to the gesture’s starting cell and clamped to the current viewport.
- Fling preserves the starting route and stops if its route token becomes invalid.
- Per-frame and per-batch row counts are capped.
- Pending rows are coalesced while the session or SSH channel applies backpressure.
- Direction changes cancel opposite pending rows before enqueueing new work.
- Provider queries and history capture are never emitted once per pixel or animation frame.

Exact caps are implementation constants covered by tests and tuned against a real SSH link; they are not persisted settings in this phase.

## 10. tmux Interaction

### 10.1 State

The tmux interaction facet tracks the verified Conn data client, its current session/window/pane, and at least:

- `alternate_on`;
- `pane_in_mode` and provider mode identifier;
- `mouse_any_flag` where supported;
- pane width and height;
- server instance token;
- control and attachment generation;
- observation timestamp.

Control Mode subscriptions keep state warm. Gesture start uses the freshness rule above and performs an on-demand read-only query when required.

### 10.2 Provider-mode scrolling

The tmux facet maps `copy-mode` and read-only `view-mode` variants that accept copy-mode commands to `.scrollable`. It executes a typed equivalent of `send-keys -t <verified-pane-id> -X -N <bounded-row-count> scroll-up|scroll-down`; direction is derived from the normalized gesture and the count uses the same row accumulator and batch cap as other routes. Success means tmux accepted the command for the same server, pane, and generation; command rejection invalidates cached mode state and cancels the remaining gesture.

Choose/tree and other modes whose documented interaction is key-table based are `.keyDriven`; their bounded Up/Down input travels through the live attached tmux client, not directly to the pane PTY. Unknown mode identifiers are `.unsupported`, produce no remote input, and expose a non-blocking “This tmux mode cannot be scrolled here” boundary indication. No provider-mode failure falls through to a different route during the same gesture.

### 10.3 History capture

- Capture targets the verified active pane, never an inferred pane name or index.
- The provider queries available history size, applies the configured line limit and a hard byte cap, then runs one capture for the resulting range.
- One capture creates one immutable review snapshot. Ongoing pane output cannot shift its line addresses.
- If older content is omitted, the snapshot carries explicit truncation metadata.
- Refresh creates a new snapshot; it never mutates the one currently selected.
- Capture output and selection text are released when review closes.

Capture styling is parsed into a restricted text/style model. Only printable UTF-8, line structure, and supported SGR attributes are accepted. OSC, DCS, APC, PM, terminal queries, title changes, hyperlinks, clipboard operations, and cursor-control instructions are stripped and never fed to the live emulator.

### 10.4 Degraded control plane

The interaction facet may perform a generation-guarded one-shot state query or history capture through the existing SSH/platform execution abstraction when the Control Mode lease is unavailable. It revalidates the tmux server identity before targeting a pane.

If both control and one-shot interaction fail, the live tmux PTY remains usable. Conn does not inject a guessed prefix or alter `.tmux.conf`; history review is temporarily unavailable and the UI presents a non-blocking retry action.

## 11. Review Surface and Selection

`TerminalReviewSnapshot` is backend-neutral:

```swift
public struct TerminalReviewSnapshot: Sendable, Equatable {
    public let source: TerminalReviewSource
    public let lines: [TerminalReviewLine]
    public let viewport: TerminalReviewViewport
    public let truncation: TerminalReviewTruncation?
    public let capturedAt: Date
    public let generation: TerminalContentGeneration
}
```

The review renderer uses the terminal font metrics and theme but does not implement terminal control semantics. Selection, handles, magnifier, autoscroll, copy, Select All, and accessibility operate on this stable model.

The live SwiftTerm remains visible underneath but does not receive touch events while review is active. It continues parsing output and replying to terminal queries. Reconnect, pane switch, resize that changes the content generation, or tab closure dismisses review and clears selection.

## 12. Modern TUI Protocol Compatibility

### 12.1 Mouse

- DECSET 9/1000/1002/1003 tracking modes are observed.
- UTF-8 1005, SGR 1006, URxvt 1015, and SGR pixel 1016 encodings are delegated to SwiftTerm.
- Touch scroll emits wheel buttons, not primary-button drag.
- Touch pointer mode emits press/motion/release.
- Hardware mouse and trackpad preserve desktop semantics and modifier bypass behavior.

### 12.2 Paste and keyboard

- Every UI paste path calls the terminal adapter’s paste API.
- When bracketed paste 2004 is active, payloads are wrapped exactly once.
- Keybar paste no longer writes raw UTF-8 directly to the session.
- Existing IME composition, Kitty keyboard protocol, sticky modifiers, and external keyboard handling remain in the emulator/input adapter.

### 12.3 Focus, output, resize, and colors

- First-responder and app foreground changes update terminal focus so DECSET 1004 reports are correct.
- Synchronized output 2026 continues to control renderer presentation without blocking protocol parsing.
- PTY resize remains driven by terminal cell dimensions and is generation-aware.
- OSC 11 background queries return the actual configured terminal background, enabling correct Hermes light/dark detection.

### 12.4 OSC 52 clipboard policy

- Every byte feed is tagged with `TerminalOutputProvenance`: current live transport generation, transcript replay, review snapshot, or local synthetic restore.
- Only current live-transport bytes may trigger delegate side effects such as OSC 52 clipboard writes. Replay, snapshot, and restore feeds update display state with host side effects disabled, so historical OSC 52 cannot rewrite the clipboard.
- Remote clipboard writes are accepted only on an interactive terminal channel, decoded with a strict size cap, written to the system clipboard, and acknowledged with a lightweight local “Copied” indication.
- Malformed or oversized writes are rejected without terminating the session.
- Remote clipboard read queries are denied by default.
- A read may be fulfilled only after the user invokes an explicit “Allow clipboard read once” terminal action. That action creates a 30-second, one-shot token scoped to the current terminal-session and attachment generation; the first OSC 52 read consumes it whether the read succeeds or fails. The token is also cleared on backgrounding, tab change, reconnect, or session closure. Terminal output alone cannot create or renew that authority.
- Clipboard bytes, selected text, and history content are never logged or persisted.

## 13. Error Handling and Degradation

| Failure | Required behavior |
| --- | --- |
| Mouse mode changes during scroll | Cancel gesture and pending fling; do not switch route |
| Attachment or provider generation changes | Cancel all interaction tokens and dismiss review |
| tmux state is stale | Resolve once, validate generation, then route bounded pending delta |
| tmux state query fails | Keep live PTY; show non-blocking history-unavailable retry |
| history capture exceeds cap | Stop capture, return a bounded snapshot with truncation metadata |
| history content is malformed | Replace invalid text, strip control sequences, keep review usable |
| remote wheel channel applies backpressure | Coalesce bounded pending rows; never queue without limit |
| terminal no longer requests mouse | Cancel remote mouse/wheel output immediately |
| long press races with scroll | Movement selects scroll; recognized hold cancels scroll and selects |
| reconnect or pane switch during selection | Dismiss review and clear clipboard menu state |
| OSC 52 read without authority | Return no clipboard data |
| OSC 52 write is malformed or oversized | Reject payload and optionally show a local warning |

No interaction failure closes a still-usable SSH or tmux data channel.

## 14. Security and Privacy

- Provider operations are typed; UI cannot submit raw tmux commands.
- Every tmux state/history request validates profile, server instance, data client, pane, and control/attachment generation.
- Captured terminal content is untrusted input and never re-enters the live emulator.
- Snapshot parsing permits only a restricted presentation grammar.
- Byte and line caps apply before allocating unbounded review content.
- OSC 52 reads require explicit local authority; writes are bounded and visible to the user.
- Terminal history, snapshots, selected text, pane content, and clipboard payloads never enter logs, analytics, SQLite, or sync.
- Review memory is cleared on dismissal, reconnect, pane change, and tab closure.

## 15. Current Code Migration

1. Vendor SwiftTerm from the exact resolved 1.15.0 revision, preserve its license and upstream metadata, switch `ConnPackages` to the local package path, and add only the isolated host-hook patches described above.
2. Remove `TerminalPanGesturePolicy` and the tests asserting that all auxiliary pans are disabled.
3. Replace `KeybarTerminalView.gestureRecognizerShouldBegin` global rejection with stable host-managed interaction hooks.
4. Add the protocol-state adapter and pure router in `ConnTerminal`.
5. Add the main-actor coordinator, gesture ownership controller, scroll accumulator, and executors.
6. Add the read-only review surface and selection controller.
7. Route keybar paste through the terminal adapter, tag live and replay feeds with provenance, and implement the bounded clipboard policy.
8. Add the optional persistent interaction facet in `ConnMultiplexer`.
9. Implement the tmux facet using the existing control runtime, identity lease, typed command/query rendering, and one-shot degraded path.
10. Pass the optional interaction facet from `TerminalTab` through `TerminalScreen` into `TerminalHostingView`.
11. Keep the existing `.byteTerminal` presentation and terminal session lifecycle unchanged.

## 16. Testing Strategy

### 16.1 Pure unit tests

- Exhaustive scroll-router matrix for every interaction mode, buffer kind, mouse mode, provider state, freshness, and input source.
- Route token cancellation on mouse-state, pane, attachment, and provider-generation changes.
- Pixel-to-row accumulation, direction reversal, fling cancellation, batch caps, and backpressure coalescing.
- Long-press versus pan state-machine transitions.
- Single/double/triple-tap routing, pointer-mode entry/exit, and local-first `Esc` consumption.
- OSC 52 size, malformed data, write, denied read, and short-lived-authority cases.
- Transcript replay containing OSC 52 updates the display but cannot invoke clipboard or other host side effects.
- Bracketed paste wraps exactly once and raw paste is not used when mode 2004 is active.
- Review snapshot truncation, malformed UTF-8, control-sequence stripping, and generation invalidation.

### 16.2 SwiftTerm adapter tests

- Mouse tracking 9/1000/1002/1003 and encodings 1005/1006/1015/1016.
- Wheel coordinates and button values for each supported encoding.
- Normal versus alternate buffer state.
- Focus reporting, synchronized output, OSC 11, Kitty keyboard state, and bracketed paste.
- Visible and local-history snapshot consistency.

### 16.3 tmux provider tests

- Cached fresh state avoids an extra query.
- Stale state performs one read-only generation-guarded resolution.
- `pane_in_mode`, `alternate_on`, and normal-pane routes match the official tmux decision table.
- Copy/view mode uses bounded `send-keys -X` scrolling; key-driven modes use the attached client; unknown modes emit no guessed input.
- History targets the verified active pane and returns one immutable snapshot.
- Output during capture cannot shift an existing snapshot.
- Control failure uses the validated one-shot fallback.
- Both interaction paths failing do not close the data attachment.
- Server restart, pane switch, or client identity mismatch rejects the result.
- Capture output cannot execute OSC, DCS, title, clipboard, or query sequences.

### 16.4 App/UI tests

- Ordinary PTY one-finger scroll.
- Ordinary PTY long-press, drag extension, edge autoscroll, copy, and exit.
- tmux shell swipe opens remote history review.
- tmux alternate pane swipe sends keys rather than opening shell history.
- Active mouse reporting sends wheel and not pointer drag.
- Explicit pointer mode sends drag and preserves two-finger wheel.
- The first `Esc` exits a local interaction mode without reaching the remote; a second `Esc` in live mode does.
- Review overlay leaves live output processing active.
- Reconnect and pane switch dismiss stale review.
- Keybar paste uses bracketed paste.
- Clipboard UI reflects accepted OSC 52 writes without exposing content in logs.

Simulator UI acceptance uses only the already-booted user simulator and its UDID. It never creates, boots, restarts, clones, or shuts down another simulator.

### 16.5 Manual interoperability matrix

Test on Linux and macOS SSH hosts, both directly and inside tmux:

- ordinary shell with long output;
- tmux shell history and copy-mode;
- Claude Code default full-screen mode;
- Claude Code with mouse clicks disabled;
- Claude Code with alternate screen disabled;
- Hermes `wheel`, `buttons`, and `all` modes;
- vim/neovim with and without mouse;
- less/man;
- htop or another mouse-aware dashboard;
- touch, iOS software keyboard, external keyboard, hardware mouse, and trackpad;
- disconnect/reconnect and concurrent external tmux client changes.

## 17. Acceptance Criteria

- Ordinary PTY scrolling remains at least as reliable as the current native-scroll implementation.
- A user can long-press and drag to select text in both ordinary and tmux terminal pages.
- Claude Code and Hermes scroll with one finger without producing mouse escape garbage or primary-button drags.
- Claude Code/Hermes inside tmux follow tmux’s state-based routing without process-name detection.
- tmux shell history is selectable and comes from the correct verified pane.
- No stale gesture sends input after reconnect, pane switch, or mouse-mode change.
- Paste, focus, resize, OSC 11, synchronized output, and permitted OSC 52 operations remain functional.
- All history, selection, and clipboard content remains ephemeral.
- No database migration or provider-name branch is added to the terminal page.

## 18. Extension Path

- Zellij, GNU Screen, and future Windows persistent-terminal providers can add their own optional interaction facet.
- Hermes Gateway or a future Claude structured protocol may later provide native session history, but such adapters plug into the same review-snapshot contract and do not alter generic terminal routing.
- A future native tmux pane renderer may reuse the interaction facet, immutable review model, and selection surface.
- Additional terminal protocols are added in the SwiftTerm adapter and capability state, not as application-specific branches.

## 19. References

- Termux terminal view: <https://github.com/termux/termux-app/blob/master/terminal-view/src/main/java/com/termux/view/TerminalView.java>
- SwiftTerm iOS terminal view: <https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/iOS/iOSTerminalView.swift>
- SwiftTerm macOS terminal view: <https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/Mac/MacTerminalView.swift>
- tmux recipes: <https://github.com/tmux/tmux/wiki/Recipes>
- tmux manual: <https://man.openbsd.org/tmux.1>
- tmux FAQ: <https://github.com/tmux/tmux/wiki/FAQ>
- Hermes TUI documentation: <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/tui.md>
- Claude Code changelog: <https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md>
- Rootshell interaction reference: <https://github.com/kitknox/rootshell>
- iTerm2 tmux integration: <https://iterm2.com/3.3/documentation-tmux-integration.html>
