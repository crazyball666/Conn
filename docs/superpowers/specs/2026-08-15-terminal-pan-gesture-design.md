# Terminal Pan Gesture Arbitration Design

## Context

Conn uses SwiftTerm's `TerminalView`, which is a `UIScrollView`, for both ordinary PTY and tmux terminals. After text selection is activated, SwiftTerm adds a second `UIPanGestureRecognizer` to the same view. That recognizer treats every drag as selection extension, so a vertical swipe selects text instead of scrolling terminal history.

The fix must preserve terminal text selection while restoring one-finger vertical scrollback in every backend.

## Considered approaches

1. **Arbitrate SwiftTerm auxiliary pans in `KeybarTerminalView` (recommended).** Use UIView's `gestureRecognizerShouldBegin` hook for every non-native pan recognizer SwiftTerm installs, without guessing whether it is currently a selection or mouse recognizer and without replacing any recognizer delegate. When remote mouse reporting is off, vertical-dominant drags fail the auxiliary recognizer and fall through to the native `UIScrollView` pan; horizontal-dominant drags continue to extend the selection. When remote mouse reporting is on, Conn does not alter SwiftTerm's begin decision. Once a selection drag begins horizontally it may continue in any direction, preserving multi-line selection. This is a small, backend-independent compatibility layer and does not modify ephemeral SPM checkout files.
2. **Vendor and patch SwiftTerm.** Patch SwiftTerm's internal selection recognizer to start only near selection endpoints. This can offer finer endpoint semantics but would vendor roughly 1.5 MB of third-party source for one fix and make dependency upgrades more expensive.
3. **Disable selection dragging.** Native scrolling would work, but users could no longer extend copied text. This is an unacceptable capability regression.

## Design

`KeybarTerminalView` will own a small auxiliary-pan arbitration policy:

- Its normal `UIScrollView.panGestureRecognizer` is never modified.
- UIView calls the overridden `gestureRecognizerShouldBegin` for recognizers attached to the terminal view. Conn does not assign or replace recognizer delegates and does not identify recognizers by installation order, selection state, private target/action inspection, or other fragile implementation details.
- If `terminal.mouseMode != .off`, Conn accepts the auxiliary recognizer unchanged so vim, htop, tmux mouse mode, and other TUI mouse input remain owned by SwiftTerm/the remote application.
- If remote mouse reporting is off, a vertical-dominant velocity rejects the auxiliary recognizer. UIKit can then recognize the native scroll pan.
- If remote mouse reporting is off, a horizontal-dominant or exactly balanced velocity accepts the auxiliary recognizer. Direction is evaluated only at gesture start, so an accepted selection drag may subsequently move vertically to select multiple lines.
- PTY and tmux use the same policy without backend-specific branches.

The policy will be isolated as a small value-level direction decision so it can be tested deterministically without synthesizing private UIKit touch events.

## Tests

Regression tests will verify:

- activating SwiftTerm selection causes its dynamically installed pan recognizer to be routed through Conn's arbiter;
- vertical-dominant input resolves to terminal scrolling;
- horizontal-dominant and balanced input remain available for selection extension;
- after a selection drag begins horizontally, no later direction decision interrupts vertical multi-line extension;
- remote mouse reporting bypasses Conn's direction policy, including when a local selection is active;
- the existing programmatic scrollback and live-output-following tests continue to pass.

The relevant package tests and application build must pass. Simulator UI acceptance will only use an already booted simulator; if the configured simulator service remains unavailable, no simulator will be started or replaced, and that limitation will be reported.

## Non-goals

- Changing tmux control mode, PTY transport, transcript storage, or scrollback limits.
- Replacing SwiftTerm's selection UI.
- Modifying generated files under `.build/checkouts`.
