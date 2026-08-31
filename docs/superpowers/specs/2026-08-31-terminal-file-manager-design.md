# Terminal File Manager Design

**Date:** 2026-08-31  
**Status:** Approved by user

## Goal

Add a file-management entry to the terminal session actions sheet. The entry reuses the
existing remote file browser, opens at the terminal's known working directory when possible,
and keeps file-browser state independent for each terminal session while the terminal page is
alive.

## Existing context

- `TerminalSessionActionsSheet` currently exposes terminal switching and page closing.
- `HostDetailView` owns a host-scoped `FileBrowserViewModel` whose initial path is `/`.
- `FileBrowserView` already implements SFTP browsing and file operations and expects its own
  `FileBrowserViewModel`.
- tmux provider interaction state already exposes a live working directory.
- SwiftTerm parses OSC 7 current-directory reports, but `TerminalInputController` currently
  discards the `hostCurrentDirectoryUpdate` callback.
- Zellij has no provider-specific working-directory field. Its attached shell can still supply
  OSC 7 when configured to do so.

## User-visible behavior

1. Add a localized `文件管理` action to the terminal session actions sheet.
2. The action remains visible to all users. Free users receive the existing file-management
   paywall; Pro users open the file browser.
3. The file browser is presented in a navigation stack sheet so its existing navigation to
   editors and log views continues to work.
4. The file browser starts at the current terminal directory when a trustworthy path is known.
   If not, it starts at `/`.
5. Dismissing the file browser and opening it again from the same terminal session restores the
   previous file-browser directory and loaded view-model state. Transient presentation state
   such as search text, sorting, active prompts, and editor/log navigation is reset.
6. Different terminal session IDs receive different file-browser state, even when they belong
   to the same host.
7. The host-detail file browser remains independent and keeps its existing state.
8. This feature does not persist file-browser state after the terminal page itself is destroyed.

## Working-directory sources and precedence

The terminal page keeps separate per-tab observations and derives an effective path for the
file-browser launch. The existing attachment destination flow continues to use the provider
directory behavior already established for uploads.

1. A live provider-reported directory (for example, tmux pane metadata) takes precedence for
   the file-browser path.
2. SwiftTerm OSC 7 reports provide the directory for ordinary SSH shells and can provide it for
   Zellij when the remote shell emits OSC 7.
3. Provider and OSC 7 observations are stored independently per `tabID` and terminal
   `generation`; an OSC 7 callback from one terminal or an old connection cannot update another
   terminal's path.
4. The effective-path rule is explicit: use a valid live provider path first, otherwise use the
   latest valid OSC 7 path. A stale/unavailable provider observation is cleared from the
   effective value, so it does not mask a newer OSC 7 path; a later live provider observation
   replaces it. A generation change clears both observations before the new generation reports
   state.
5. OSC 7 input is parsed as a URL only: the scheme must be `file` (case-insensitive), the URL
   path must be absolute, and host/query/fragment do not change the resulting path. Provider
   input is already a POSIX path and is validated separately as an absolute path. Both paths
   reject malformed percent escapes, control/NUL characters, empty or relative components, and
   `.`/`..` traversal components; trailing separators are normalized except for `/`.
6. If no valid value is available on first open, the file browser uses `/`.

The file-browser directory observation is separate from the existing attachment-upload
directory state. OSC 7 must never change the upload destination; provider state may continue to
feed the existing attachment fallback exactly as it does today.

Terminal source semantics are explicit: `.shell`, `.script`, and `.persistent` sessions may use
the effective path above; `.docker` sessions always open at `/` because their OSC 7 path may be
inside a container while this file manager operates on the host SFTP filesystem. Supporting
container-file browsing is out of scope.

The implementation must not inject `pwd` into the interactive terminal to discover the path.
When the file browser is reopened after it has loaded once, its own current path wins over any
newly observed terminal directory so user navigation is preserved.

## Architecture

### Terminal action routing

Extend the existing deferred session-action enum with a file-browser action. The action sheet
dismisses first, then `TerminalScreen` checks the subscription gate and presents the file browser.
This preserves the existing sheet sequencing and prevents stacked action sheets.

### Per-terminal file-browser state

`TerminalScreen` owns a small in-memory map keyed by `tabID` that creates and retains one
`FileBrowserViewModel` per terminal session. On first creation it receives the effective path
for that tab as its initial path. Reopening uses the retained view model; switching to a
different terminal selects another map entry and cannot reuse the previous tab's path.

The host-detail `fileVM` is not passed into the terminal route and is not changed to accommodate
this feature.

### Working-directory propagation

Keep the existing provider-only callback named `onPersistentWorkingDirectoryChanged` for the
attachment-upload destination. Add a separate terminal-working-directory callback carrying the
source, `tabID`-captured generation, and normalized path. `TerminalInputController` will handle
`hostCurrentDirectoryUpdate`, normalize the OSC 7 payload, and send only the new terminal-path
callback. Provider state updates send the provider path to both the existing provider-only
callback and the new terminal-path callback; stale/unavailable provider state sends nil to the
provider path and removes the provider candidate from the terminal-path resolver.

### File-browser initial path

Extend `FileBrowserViewModel` with an initial-path setup operation that can run before its first
load. It must only change the path while `hasLoaded` is false. The first load tries that path;
if a non-root path is syntactically valid but cannot be listed (for example, it was deleted or
is inaccessible), it retries `/` once and keeps `/` as the current path after success. If `/`
also fails, the existing file-browser error state is shown. This ensures the terminal path is
useful without making a stale working directory prevent the file manager from opening.

## Testing

- Add unit tests for OSC 7 URL normalization (standard file URL, host-bearing file URL,
  percent-encoded path, and rejected relative/invalid input) and separate provider absolute-path
  validation (including raw absolute paths). Test control/NUL and traversal rejection, provider-
  vs-OSC 7 precedence, generation invalidation, and per-tab isolation as pure state-resolution
  behavior.
- Add unit tests for `FileBrowserViewModel` initial-path setup and its no-overwrite-after-load
  behavior, including non-root load failure falling back to `/`.
- Update terminal action source/consistency tests for the new deferred action and file-manager
  presentation.
- Add an XCUITest that opens file management from terminal session actions, navigates to a
  subdirectory, dismisses it, reopens it, and verifies the same directory remains selected;
  also exercise two terminal sessions to verify their paths do not cross, and confirm the
  Docker-console source starts at `/`.
- Add an XCUITest for the Pro terminal-entry success path and a separate free-state test that
  confirms loading/unavailable/non-Pro entitlement uses the existing paywall (the existing gate
  is fail-closed because `gate.allowed` only returns true for Pro). If entitlement changes after
  the file page is already open, leave that page active; access is checked at entry and existing
  file operations are not interrupted by this feature.
- Add focused UI/source coverage for the host-detail and terminal file-browser owners remaining
  separate, transient file-view controls resetting on reopen, and the terminal page destruction
  boundary (no cross-page persistence).
- Keep the existing full localization directory and placeholder-consistency tests green; the
  new action must use the existing fully translated `文件管理` key.
- Run package tests, `ConnTests`, and the relevant terminal UI tests on the already booted
  simulator using its exact UDID and with parallel testing disabled.

## Out of scope

- Persisting file-browser state across destruction of the terminal page or app restart.
- Adding a provider-specific Zellij working-directory protocol.
- Browsing files inside Docker containers from this host SFTP file manager.
- Executing `pwd` or modifying shell startup files.
- Changing the host-detail file browser's ownership or behavior.
