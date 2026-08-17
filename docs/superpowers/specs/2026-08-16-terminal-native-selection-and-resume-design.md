# Terminal Native Selection and Foreground Resume Design

**Date:** 2026-08-16
**Status:** Confirmed
**Scope:** iOS terminal text selection, advanced terminal tools, and foreground recovery for ordinary PTY and persistent tmux terminals

## 1. Summary

Conn will restore the platform-native mobile terminal interaction model: a long press selects directly in SwiftTerm's live renderer, preserving the terminal font, ANSI colors, attributes, viewport, and scrollback. The same renderer draws the selection highlight and handles and presents the iOS Copy/Select All menu; no `UITextView` or other text surface covers the terminal. Copy remains an explicit user action. The software keyboard and compact keybar stay usable throughout selection. Remote pointer mode remains an advanced tool and no controls float above terminal content. Remote OSC 52 clipboard reads remain denied without a session-level authorization entry point.

Returning from the background will preserve healthy SSH, PTY, and tmux attachments. Conn will recover only sessions already known to be disconnected/reconnecting or sessions whose pooled SSH transport is affirmatively dead. A surviving tmux attachment therefore remains directly operable; a dead transport is rebuilt and reattached to the original persistent descriptor.

No database migration is required. All affected state is runtime connection, interaction, and presentation state.

## 2. Root Causes

### 2.1 Selection and floating controls

`TerminalHostingView` disables SwiftTerm's built-in touch gestures so Conn can route ordinary scroll, tmux copy-mode scroll, TUI mouse reporting, and touch-pointer mode. The replacement long-press path incorrectly snapshots terminal text into `TerminalReviewTextView`. That overlay discards per-cell ANSI styling, replaces the terminal font/color rendering with a plain text rendering pass, and captures the viewport and keybar interaction until review is dismissed. The compact keybar also replaced the existing four-way direction pad with four separate arrow keycaps, consuming unnecessary horizontal space.

### 2.2 Foreground reconnect

`TerminalSessionCoordinator.resumeAfterBackground(idleFor:)` currently reconnects every tab sequentially whenever the background interval exceeds 30 seconds. `replaceDisconnectedTab` publishes `.reconnecting` before opening a replacement backend. Consequently, healthy sockets are deliberately closed, every tab displays recovery state, and one SSH handshake can hold foreground recovery for the transport timeout.

This contradicts the existing multi-session design: backgrounding must not proactively close a terminal; a surviving connection continues, and only a dead connection is recovered.

## 3. Product Behavior

### 3.1 Native text selection

- Long press always takes precedence over touch pointer input and begins word selection in the live SwiftTerm renderer.
- Long-press drag extends the native terminal selection; subsequent drags can adjust its rendered endpoints.
- Selection preserves the exact terminal canvas, font, foreground/background colors, ANSI attributes, and cursor context.
- The iOS edit menu is presented immediately and includes Copy and Select All.
- Copy writes only the current selection after the user chooses Copy.
- Select All selects the current terminal buffer using SwiftTerm's selection service.
- Entering and leaving selection does not collapse, reopen, or resize the software keyboard or keybar.
- A terminal tap or the next keyboard/keybar input clears the selection and resumes normal terminal operation; Copy also clears the selection after writing.
- Live terminal output continues in the same renderer. No overlay can leave the terminal or keybar stuck.
- Ordinary PTY, tmux, and full-screen TUIs use the same rendered-buffer selection path. Existing scroll routing remains responsible for bringing local or remote history into the viewport before selection.

### 3.2 Advanced tools

- No controls float over terminal content.
- Hardware mouse reporting and touch wheel routing remain automatic from terminal protocol state.
- Touch remote-pointer mode remains an explicit advanced action because drag gestures otherwise conflict with local scrolling and selection.
- OSC 52 clipboard writes from the remote remain bounded and replay-protected as today.
- OSC 52 clipboard reads remain denied. No terminal-session UI grants remote access to the local clipboard.
- Remote pointer mode moves into the expanded keybar as a low-frequency action.
- The compact keybar is one high-density row no taller than 52 points. It keeps a fixed compact four-way direction pad and horizontally scrolls the remaining high-frequency keys/actions.
- Keycaps may be visually smaller, but every action retains at least a 44-point effective touch target. The expanded panel remains bounded to approximately 176 points.

### 3.3 Close behavior

- The top-right close action dismisses `TerminalScreen` immediately, then releases the local terminal resources asynchronously.
- Closing a persistent tmux terminal detaches the local client; it does not kill the remote tmux session.
- Resource cleanup latency must never leave an empty terminal screen visible.

### 3.4 Foreground resume

- Background intervals at or below the existing threshold remain a no-op.
- A `.connected` tab remains untouched when the connection pool reports a live session or has no affirmative evidence that its transport died.
- `.disconnected` and `.reconnecting` tabs are eligible for recovery.
- A `.connected` tab is eligible only when its pooled SSH session is affirmatively disconnected.
- The current tab is recovered first. Other eligible tabs are recovered afterward with bounded concurrency, so an unrelated slow host does not serialize all recovery.
- Existing reconnect-task deduplication and generation fencing remain authoritative.
- Persistent tabs reconnect from their `PersistentAttachmentDescriptor`; tmux is reattached rather than recreated.
- Half-open sockets that still report alive are handled by the existing input/output failure path. Conn will not inject probe bytes into a user terminal.

### 3.5 Reconnect presentation

- Healthy sessions show no reconnect UI.
- A real reconnect uses a compact notice centered over the terminal.
- The notice uses a continuous 9-point rounded rectangle rather than a capsule.
- Its black background uses approximately 0.82 opacity so terminal text does not bleed through excessively.
- A short grace delay avoids flashing the notice for recovery that finishes almost immediately; disconnected/error presentation remains separate.

## 4. Architecture

### 4.1 Read-only pool health

`ConnectionManager` exposes a non-mutating pool-health query with three semantic outcomes:

```swift
public enum SSHPooledSessionHealth: Sendable, Equatable {
    case absent
    case connecting
    case connected
    case disconnected
}
```

The query never creates, closes, or invalidates a connection. `.absent` and `.connecting` are not proof that an already-open terminal channel died, so a connected terminal is preserved. Only `.disconnected` is affirmative evidence for proactive recovery.

### 4.2 Resume candidate policy

A pure value-level policy accepts tab status and pool health and returns whether the tab needs recovery. Keeping this decision outside the coordinator's I/O loop makes the lifecycle behavior deterministic and directly testable.

The coordinator resolves each tab's current host configuration, evaluates the policy, prioritizes `store.currentTabID`, and invokes the existing `reconnect(_:)` path only for candidates. Missing hosts are left for the existing host-delete lifecycle rather than guessed.

### 4.3 Host-driven SwiftTerm selection

`KeybarTerminalView` continues setting `hostManagesTouchGestures = true`; Conn still needs one provider-neutral router for local scrollback, alternate buffers, tmux copy mode, mouse-reporting TUIs, and touch-pointer mode. Conn does not re-enable SwiftTerm's whole built-in gesture set because that would create competing pans and long presses.

Instead, the host forwards only selection lifecycle events into SwiftTerm's existing `SelectionService`: long-press began calls word selection at a renderer cell; changed extends the renderer selection; ended presents SwiftTerm's standard edit menu. A dedicated host selection pan delegates to SwiftTerm's existing endpoint/pivot and auto-scroll algorithm while `hasActiveSelection` is true. Remote scroll and pointer recognizers yield during that state. Terminal taps and typed/keybar input call `clearSelection()` before continuing normally.

This preserves one authoritative buffer-to-cell mapping and one rendering pass for long-press selection. `TerminalReviewTextView`, duplicate UTF-16 word selection, responder transfer, and review input locks are not part of the long-press path. The existing bounded history review remains only as the fallback for tmux history that is not present in SwiftTerm's local buffer; any terminal/keybar input dismisses that fallback and continues immediately, so it cannot lock the session.

### 4.4 Keybar tools

`TerminalKeybar` uses a one-row compact layout with the existing `TerminalDirectionPad` fixed at the trailing edge. Esc, Ctrl, Tab, Ctrl-C, paste, expand, and keyboard-dismiss actions occupy smaller horizontally scrollable keycaps. The four directions therefore consume one control footprint rather than four. The expanded panel contains low-frequency actions, including touch pointer mode when available. No callback can authorize a remote clipboard read. The terminal viewport remains visually unobstructed.

## 5. Failure Handling

- Failure to recover one tab updates only that tab through the existing disconnected lifecycle.
- Recovery of other candidates continues even if one host fails.
- If a tab closes or its generation changes during recovery, existing generation/ownership checks discard stale results.
- If pool health changes after candidate selection, `ConnectionManager.session(for:)` and backend open remain the final liveness authority.
- If selection cannot begin, the live terminal remains interactive and clipboard content is unchanged.
- Selection cancellation clears SwiftTerm's selection and immediately returns gesture/input routing to live mode.

## 6. Testing and Acceptance

Automated coverage must prove:

1. a healthy connected tab keeps its generation and status after a long background interval;
2. an explicitly disconnected tab is recovered;
3. a tab backed by an affirmatively dead pooled SSH session is recovered;
4. the current tab is selected as the first recovery candidate and unrelated healthy tabs are skipped;
5. the terminal canvas no longer contains floating pointer/actions controls;
6. the compact keybar is a single row no taller than 52 points, contains one four-way `TerminalDirectionPad`, and exposes no remote clipboard-read authorization;
7. long press is not blocked by pointer mode;
8. long press and drag call SwiftTerm's native begin/extend/finish selection hooks and never present `TerminalReviewTextView`;
9. selection remains in the ANSI renderer, remote scroll/pointer gestures yield, and terminal tap or input clears selection without blocking the keybar;
10. terminal close dismisses before asynchronous cleanup, including tmux detach;
11. the reconnect notice is centered and uses the compact rounded-rectangle style.

Run package tests, app tests that do not require a simulator, and a generic iOS build. UI acceptance may use only the one simulator already booted by the user; if CoreSimulatorService or that device is unavailable, stop simulator work and report it without creating or switching devices.

## 7. Non-goals

- Keeping SSH alive indefinitely while iOS suspends the app.
- Adding Mosh or background networking entitlements.
- Sending intrusive keepalive/probe bytes into a live PTY on foreground entry.
- Persisting live PTY or tmux attachment state in the database.
- Changing the SSH handshake timeout as part of this fix.
