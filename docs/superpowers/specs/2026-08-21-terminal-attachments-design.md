# Terminal Attachments Design

**Date:** 2026-08-21

**Status:** Approved for implementation

## 1. Goal

Add a mobile-native terminal attachment workflow for Claude Code, Codex, Hermes and other
interactive TUIs. A user can choose or paste local images and files, upload them over the
host's SSH/SFTP connection, and insert the resulting remote paths into the current terminal
input without submitting it.

The workflow must behave identically for ordinary PTY tabs and persistent-terminal providers
such as tmux. Upload is a host transport capability, not a tmux capability.

## 2. Product behaviour

The expanded terminal keybar contains a permanent **Upload** section alongside **Common** and
the optional provider section. The section exposes compact actions for photos, videos, camera,
files, clipboard resources and uploaded-file browsing. The first implementation ships the
system photo/file pickers and explicit clipboard image/file-URL upload; camera/video/browsing use the
same action contract and may be enabled when their picker surfaces are present.

An upload:

1. starts only from an explicit user action;
2. keeps transfer progress visible in the terminal;
3. uploads resources in selection order;
4. inserts all completed remote reference paths in one bracketed-paste operation;
5. never sends Return/Enter;
6. never inserts into a different tab or a rebuilt terminal generation;
7. leaves a completed receipt available for explicit insertion when automatic insertion is no
   longer safe.

The Upload panel is reserved for source actions, in-flight progress, cancellation, retry and the
exceptional manual path-insertion action. Completion, informational notices and error messages use
the app-wide toast presentation instead of adding persistent result copy to the panel.

The compact text-paste action keeps its current behaviour. Clipboard images are uploaded only
from the explicit upload panel so text paste never changes meaning unexpectedly.

## 3. Architecture

### 3.1 Shared upload engine

`ConnSSH` owns a transport-neutral `RemoteUploadService` built on `RemoteFileSystem`. It accepts
local byte streams, a resolved remote destination and metadata, and reports progress plus a
receipt. The service writes to a unique sibling partial file, applies private permissions, and
publishes with rename only after the complete payload has been written.

Creation permissions are included in the SFTP open request when supported. The compatibility
fallback applies mode `0600` before returning the new handle and fails closed if that cannot be
done, so payload bytes are not intentionally written to a broadly readable file.

The existing file-browser upload path is migrated to this service so terminal and file manager
do not maintain separate upload implementations.

### 3.2 App orchestration

`TerminalAttachmentCoordinator` lives at the app feature boundary. It owns picker presentation,
local-resource preparation, the per-host serial queue, destination selection, transfer state and
completed receipts. It receives `Host` and `ConnectionManager` through existing dependency
injection.

Picker and alert state is hosted by stable `TerminalScreen`, not by `TerminalKeybar`, because the
keybar can be rebuilt when terminal focus or keyboard state changes.

### 3.3 Terminal insertion

`ConnTerminal` exposes a generation-tagged text insertion request. `TerminalHostingView` consumes
each request exactly once through `TerminalInputController.handlePaste`, preserving the emulator's
active bracketed-paste framing. App code must not inject uploaded paths by writing raw bytes to the
SSH session.

The same insertion contract can replace the command picker's current raw send path, keeping all
programmatic terminal text insertion consistent.

### 3.4 Provider working-directory facet

A provider may expose an optional, read-only working-directory snapshot for the currently attached
target. tmux derives this from the active pane's control-mode topology. Future Zellij or Screen
adapters can expose the same facet. Ordinary PTY tabs do not execute `pwd` behind a running TUI.

Destination resolution uses this order:

1. fresh provider working directory;
2. a future fresh OSC 7 shell-integration directory;
3. the SFTP account home under `.conn/uploads/YYYY-MM-DD`.

This feature does not add fields to `Host`, change `ConnStore`, or introduce a database-backed
upload preference.

An upload receipt carries both its SFTP path and terminal-reference path so future Windows
OpenSSH/PowerShell path translation does not leak into terminal UI code.

## 4. Data model

The upload domain uses value types:

- `RemoteUploadItem`: stable ID, display name, byte count and async byte source;
- `RemoteUploadDestination`: filesystem directory and terminal path dialect;
- `RemoteUploadProgress`: item ID, completed bytes and total bytes;
- `RemoteUploadedResource`: original name, remote filesystem path, terminal reference path and
  byte count;
- `TerminalTextInsertionRequest`: request ID, tab ID, terminal generation, input epoch,
  provider target identity and text.

No upload content or upload receipt is stored in SQLite. Active and recently completed transfers
are bounded in memory. The **View** action reads the remote upload directory when implemented.

## 5. File handling and privacy

- Files are streamed in bounded chunks; the complete file is never retained in memory.
- Security-scoped file URLs remain scoped only for the transfer lifetime.
- Clipboard and photo resources are read only after an explicit button action.
- Generated remote names use a timestamp, short random suffix, sanitized readable stem and the
  original extension.
- The upload directory is mode `0700` when the server supports permissions and uploaded files are
  mode `0600`.
- Partial files are best-effort removed after failure or cancellation.
- No content, path or terminal text is written to analytics or diagnostic logs.
- Image preparation converts unsupported photo formats to a broadly supported PNG/JPEG payload
  and strips metadata such as GPS before upload.

## 6. Concurrency and recovery

Uploads are serialized per host to preserve terminal responsiveness on the shared SSH connection.
The SFTP channel is reused while healthy and discarded after transport failure. A safe upload may
retry once because the final destination is not published until completion.

Every request captures host ID, tab ID, terminal generation, input epoch and provider target
identity. Completion auto-inserts only when all still match. Typing, switching tmux panes,
reconnect, tab closure or tab replacement invalidates the capture and turns
the receipt into a manual **Insert path** action instead of sending text to the wrong process.

## 7. UI and localization

All user-visible labels are added to both app and package string catalogs in Simplified Chinese,
Traditional Chinese, English, Japanese and Korean. Controls keep a 44-point effective hit target even when their
visible key caps are compact. Upload progress does not cover the terminal viewport and picker
dismissal restores the previous terminal keyboard intent.

## 8. Failure handling

- Picker cancellation is silent.
- Unsupported clipboard content produces a professional informational toast.
- Transfer errors use the global error toast, keep the terminal usable and leave retry in the panel.
- A missing or disconnected tab never receives insertion bytes.
- If only some selected items succeed, the global error toast reports partial completion and the
  panel offers retry; nothing is inserted automatically until the successful subset is complete.

## 9. Verification

Unit tests cover path generation, private permissions, byte integrity, progress, cancellation,
safe publication, destination fallback, generation guards and one-shot bracketed insertion.

XCUITests on the user's already-booted simulator cover opening the upload section, selecting a
deterministic smoke attachment, observing completion, verifying the inserted path and confirming
that no Enter key was sent. Existing keybar, keyboard, terminal selection and tmux tests remain
green.
