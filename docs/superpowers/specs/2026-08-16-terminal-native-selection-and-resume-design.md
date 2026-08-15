# Terminal Native Selection and Foreground Resume Design

**Date:** 2026-08-16
**Status:** Confirmed
**Scope:** iOS terminal text selection, advanced terminal tools, and foreground recovery for ordinary PTY and persistent tmux terminals

## 1. Summary

Conn will restore the platform-native mobile terminal interaction model: a long press on terminal content immediately opens a frozen, selectable text surface with native selection handles and the iOS edit menu. Copy and Select All are explicit user actions; entering selection never copies automatically. Remote pointer mode and OSC 52 clipboard-read authorization remain available as advanced tools but no longer float above terminal content.

Returning from the background will preserve healthy SSH, PTY, and tmux attachments. Conn will recover only sessions already known to be disconnected/reconnecting or sessions whose pooled SSH transport is affirmatively dead. A surviving tmux attachment therefore remains directly operable; a dead transport is rebuilt and reattached to the original persistent descriptor.

No database migration is required. All affected state is runtime connection, interaction, and presentation state.

## 2. Root Causes

### 2.1 Selection and floating controls

`TerminalHostingView` currently places pointer and clipboard controls in a `ZStack` over the terminal viewport. Touch pointer mode also prevents the selection long-press recognizer from beginning. `TerminalReviewTextView` becomes first responder after a programmatic selection but does not explicitly present the modern iOS edit menu, so the user does not reliably receive the native Copy/Select All interaction.

### 2.2 Foreground reconnect

`TerminalSessionCoordinator.resumeAfterBackground(idleFor:)` currently reconnects every tab sequentially whenever the background interval exceeds 30 seconds. `replaceDisconnectedTab` publishes `.reconnecting` before opening a replacement backend. Consequently, healthy sockets are deliberately closed, every tab displays recovery state, and one SSH handshake can hold foreground recovery for the transport timeout.

This contradicts the existing multi-session design: backgrounding must not proactively close a terminal; a surviving connection continues, and only a dead connection is recovered.

## 3. Product Behavior

### 3.1 Native text selection

- Long press always takes precedence over touch pointer input and opens local text selection.
- The selected word is visible with draggable native handles.
- The iOS edit menu is presented immediately and includes Copy and Select All.
- Copy writes only the current selection after the user chooses Copy.
- Select All selects the complete bounded review snapshot.
- Leaving review is an explicit Done action in the edit menu or an outside-tap dismissal supported by the review surface; there is no floating close button.
- Live terminal output continues beneath the immutable review surface.
- The same interaction is used for ordinary PTY and tmux review content; only the snapshot provider differs.

### 3.2 Advanced tools

- No controls float over terminal content.
- Hardware mouse reporting and touch wheel routing remain automatic from terminal protocol state.
- Touch remote-pointer mode remains an explicit advanced action because drag gestures otherwise conflict with local scrolling and selection.
- OSC 52 clipboard writes from the remote remain bounded and replay-protected as today.
- OSC 52 clipboard reads remain denied by default and require one explicit, single-use, 30-second authorization.
- Remote pointer and clipboard-read authorization move into one low-frequency tools menu in the existing terminal keybar.

### 3.3 Foreground resume

- Background intervals at or below the existing threshold remain a no-op.
- A `.connected` tab remains untouched when the connection pool reports a live session or has no affirmative evidence that its transport died.
- `.disconnected` and `.reconnecting` tabs are eligible for recovery.
- A `.connected` tab is eligible only when its pooled SSH session is affirmatively disconnected.
- The current tab is recovered first. Other eligible tabs are recovered afterward with bounded concurrency, so an unrelated slow host does not serialize all recovery.
- Existing reconnect-task deduplication and generation fencing remain authoritative.
- Persistent tabs reconnect from their `PersistentAttachmentDescriptor`; tmux is reattached rather than recreated.
- Half-open sockets that still report alive are handled by the existing input/output failure path. Conn will not inject probe bytes into a user terminal.

### 3.4 Reconnect presentation

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

### 4.3 Native edit-menu host

`TerminalReviewTextView` owns a `UIEditMenuInteraction` and presents it at the selected text range after becoming first responder. It keeps UIKit's built-in selection gestures and handles enabled. Its action surface explicitly supports Copy, Select All, and Done while remaining non-editable.

The live `KeybarTerminalView` long-press recognizer no longer checks touch pointer mode. Beginning selection first deactivates pointer mode through the interaction coordinator, then captures review content.

### 4.4 Keybar tools

`TerminalKeybar` receives typed state and callbacks for pointer availability/activation and one-time clipboard-read authorization. A single menu keycap renders those low-frequency actions. The terminal viewport remains visually unobstructed.

## 5. Failure Handling

- Failure to recover one tab updates only that tab through the existing disconnected lifecycle.
- Recovery of other candidates continues even if one host fails.
- If a tab closes or its generation changes during recovery, existing generation/ownership checks discard stale results.
- If pool health changes after candidate selection, `ConnectionManager.session(for:)` and backend open remain the final liveness authority.
- Selection capture failure leaves the live terminal interactive and does not alter clipboard content.

## 6. Testing and Acceptance

Automated coverage must prove:

1. a healthy connected tab keeps its generation and status after a long background interval;
2. an explicitly disconnected tab is recovered;
3. a tab backed by an affirmatively dead pooled SSH session is recovered;
4. the current tab is selected as the first recovery candidate and unrelated healthy tabs are skipped;
5. the terminal canvas no longer contains floating pointer/actions controls;
6. the keybar exposes the advanced tools menu;
7. long press is not blocked by pointer mode;
8. the review surface remains non-editable, selectable, supports native Copy/Select All/Done, and does not auto-copy;
9. the reconnect notice is centered and uses the compact rounded-rectangle style.

Run package tests, app tests that do not require a simulator, and a generic iOS build. UI acceptance may use only the one simulator already booted by the user; if CoreSimulatorService or that device is unavailable, stop simulator work and report it without creating or switching devices.

## 7. Non-goals

- Keeping SSH alive indefinitely while iOS suspends the app.
- Adding Mosh or background networking entitlements.
- Sending intrusive keepalive/probe bytes into a live PTY on foreground entry.
- Persisting live PTY or tmux attachment state in the database.
- Changing the SSH handshake timeout as part of this fix.
