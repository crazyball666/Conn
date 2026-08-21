# Terminal Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upload local images and files from the terminal keybar over SFTP and insert their remote paths into the active TUI without submitting the prompt.

**Architecture:** Extract a reusable, atomic streaming uploader into `ConnSSH`; keep iOS resource picking and transfer orchestration in the app feature layer; deliver completed paths to `ConnTerminal` through a generation-tagged insertion request consumed by the existing bracketed-paste path. Provider working-directory metadata is optional, so PTY and tmux share the same upload flow.

**Tech Stack:** Swift 5.10, SwiftUI, UIKit/PhotosUI, Swift Concurrency, Citadel SFTP through `RemoteFileSystem`, SwiftTerm, Swift Testing, XCTest/XCUITest.

---

### Task 1: Shared atomic remote upload engine

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnSSH/RemoteUploadService.swift`
- Test: `Packages/ConnPackages/Tests/ConnSSHTests/RemoteUploadServiceTests.swift`

- [ ] Write failing tests for deterministic safe naming, byte integrity, monotonic progress, private permissions, cancellation cleanup and atomic publication.
- [ ] Run `xcodebuild test -scheme ConnPackages-Package -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -only-testing:ConnSSHTests/RemoteUploadServiceTests` and confirm failure.
- [ ] Implement value types plus `RemoteUploadService` over `RemoteFileSystem`, using bounded reads and a unique sibling partial file.
- [ ] Run the focused tests and confirm they pass.

### Task 2: Reuse the uploader from file management

**Files:**
- Modify: `Conn/Conn/Files/FileBrowserViewModel.swift`
- Modify: `Conn/Conn/Files/FileBrowserViewModel+Transfer.swift`
- Modify: `Conn/Conn/ConnApp.swift`
- Test: `Conn/ConnTests/RemoteFileIntegrityTests.swift`

- [ ] Add a regression test proving interrupted upload preserves an existing destination and leaves no published partial content.
- [ ] Inject the shared uploader into `FileBrowserViewModel` and remove its duplicate write loop.
- [ ] Run file integrity and file-browser tests on the simulator.

### Task 3: Generation-safe terminal text insertion

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalTextInsertion.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalTextInsertionTests.swift`
- Test: `Conn/ConnUITests/ConnUITests.swift`

- [ ] Write failing tests for one-shot consumption, tab/generation mismatch rejection and ordered multi-path formatting.
- [ ] Add an observable insertion broker and consume accepted requests with `TerminalInputController.handlePaste`.
- [ ] Route command-picker insertion through the same broker without sending Return.
- [ ] Run focused package and UI regression tests.

### Task 4: Terminal attachment coordinator and destination resolver

**Files:**
- Create: `Conn/Conn/Terminal/TerminalAttachmentCoordinator.swift`
- Create: `Conn/Conn/Terminal/TerminalAttachmentDestination.swift`
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Test: `Conn/ConnTests/TerminalAttachmentCoordinatorTests.swift`

- [ ] Write failing tests for home fallback, safe remote reference paths, serial ordering, retry state and generation-safe completion.
- [ ] Implement file URL staging, SFTP home resolution, the per-host serial transfer task and bounded recent receipts.
- [ ] Keep picker cancellation silent and map failures to localized presentation state.
- [ ] Run the focused tests on the simulator.

### Task 5: Upload keybar section and system pickers

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalAttachmentPanel.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalKeybar.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalKeybarMetrics.swift`
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Test: `Conn/ConnTests/TerminalLayoutTests.swift`
- Test: `Conn/ConnUITests/TerminalKeybarLayoutUITests.swift`

- [ ] Write layout/source-contract tests requiring the permanent Upload tab, compact buttons, progress state and unchanged direction-pad footprint.
- [ ] Add PhotosPicker and fileImporter presentation to stable `TerminalScreen`.
- [ ] Add image/file/clipboard actions, progress, cancellation, retry and manual insertion to the upload panel.
- [ ] Ensure keybar visibility and keyboard focus survive picker presentation.
- [ ] Run layout and XCUITests on the booted simulator.

### Task 6: Localization and deterministic smoke workflow

**Files:**
- Modify: `Conn/Conn/Localizable.xcstrings`
- Modify: `Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`
- Modify: `Conn/Conn/Terminal/TerminalSmokeLaunchView.swift`
- Test: `Conn/ConnTests/LocalizationCoverageTests.swift`
- Test: `Conn/ConnUITests/TerminalKeybarLayoutUITests.swift`

- [ ] Add professional Simplified Chinese, Traditional Chinese, English, Japanese and Korean labels for upload states and errors.
- [ ] Add a launch-argument smoke attachment source that avoids automating the system photo library.
- [ ] Add an end-to-end UI test: open Upload, select smoke image, observe progress, verify inserted path and verify no newline submission.
- [ ] Run localization and focused XCUITests on UDID `DDACC334-4130-4FA3-AC0A-A28B62F71FC1` with `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`.

### Task 7: Full regression and visual QA

**Files:**
- Modify only files required by discovered regressions.

- [ ] Run selected package suites for ConnSSH and ConnTerminal on UDID `DDACC334-4130-4FA3-AC0A-A28B62F71FC1` with `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`.
- [ ] Run affected app unit tests and terminal XCUITests on the same simulator.
- [ ] Install and launch the test build, capture screenshots of compact keybar, Upload panel, progress and completed insertion, and visually inspect safe areas and button density.
- [ ] Run `swiftformat --lint`, `swiftlint`, `git diff --check` and review the final diff for unrelated changes.
