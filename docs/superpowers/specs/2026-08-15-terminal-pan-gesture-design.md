# Terminal Pan Gesture Arbitration Design

## Context

Conn uses SwiftTerm's `TerminalView`, which is a `UIScrollView`, for both ordinary PTY and tmux terminals. After text selection is activated, SwiftTerm adds a second `UIPanGestureRecognizer` to the same view. That recognizer treats every drag as selection extension, so a vertical swipe selects text instead of scrolling terminal history.

The fix must make one-finger scrollback reliable in every backend. Text can still be selected through long press, double tap, triple tap, and Select All, but drag-to-extend selection and remote mouse drag are intentionally secondary to native scrolling.

## Considered approaches

1. **Disable SwiftTerm auxiliary pans in `KeybarTerminalView` (recommended).** Use UIView's `gestureRecognizerShouldBegin` hook for every non-native pan recognizer SwiftTerm installs, without replacing recognizer delegates. Only the native `UIScrollView` pan may begin. This is a small, backend-independent compatibility layer and does not modify ephemeral SPM checkout files.
2. **Vendor and patch SwiftTerm.** Patch SwiftTerm's internal selection recognizer to start only near selection endpoints. This can offer finer endpoint semantics but would vendor roughly 1.5 MB of third-party source for one fix and make dependency upgrades more expensive.
3. **Direction-based arbitration.** Preserve horizontal selection dragging and remote mouse dragging while rejecting vertical auxiliary pans. In practice, small horizontal movement at gesture start still activates selection and blocks scrolling, so this does not provide reliable touch behavior.

## Design

`KeybarTerminalView` will own a small auxiliary-pan arbitration policy:

- Its normal `UIScrollView.panGestureRecognizer` is never modified.
- UIView calls the overridden `gestureRecognizerShouldBegin` for recognizers attached to the terminal view. Conn does not assign or replace recognizer delegates and does not identify recognizers by installation order, selection state, private target/action inspection, or other fragile implementation details.
- Every non-native pan is rejected, including SwiftTerm's selection-extension pan and remote mouse-drag pan.
- Tap gestures remain unchanged, so terminal focus, local selection entry points, context menus, and remote mouse clicks continue to work.
- The trade-off is explicit: drag-to-extend selection and remote drag gestures are removed so one-finger scrollback is deterministic.
- PTY and tmux use the same policy without backend-specific branches.

The policy will be isolated as a small value-level pan-ownership decision so it can be tested deterministically without synthesizing private UIKit touch events.

## Tests

Regression tests will verify:

- activating SwiftTerm selection causes its dynamically installed pan recognizer to be rejected;
- remote mouse reporting's dynamically installed pan recognizer is also rejected;
- the native `UIScrollView` pan remains available;
- the existing programmatic scrollback and live-output-following tests continue to pass.

The relevant package tests and application build must pass. Simulator UI acceptance will only use an already booted simulator; if the configured simulator service remains unavailable, no simulator will be started or replaced, and that limitation will be reported.

## Non-goals

- Changing tmux control mode, PTY transport, transcript storage, or scrollback limits.
- Replacing SwiftTerm's selection UI.
- Modifying generated files under `.build/checkouts`.
