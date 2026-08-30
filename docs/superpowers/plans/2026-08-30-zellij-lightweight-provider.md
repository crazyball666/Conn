# Zellij Lightweight Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a version-unrestricted Zellij persistent-terminal provider with Session discovery/create/attach/resume and Zellij-native key-macro quick actions.

**Architecture:** Implement Zellij behind the existing `PersistentTerminalProvider` and `PersistentTerminalInteractionFacet` boundaries. Keep the PTY as the source of truth, represent the remote Session name as the durable workspace identity, and send provider-owned default key sequences through the attachment channel without introducing topology state or a control plane.

**Tech Stack:** Swift 6 language mode, Swift Package Manager, Swift Testing, SwiftUI, XCUITest, ConnSSH `RemoteProcessChannel`, existing ConnMultiplexer provider abstractions.

---

### Task 1: Complete provider lifecycle and PTY attachment

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/ZellijProvider.swift`
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/ZellijAttachment.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProviderRegistry.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/ZellijProviderTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/PersistentTerminalProviderRegistryTests.swift`

- [ ] Write failing tests proving default registration includes tmux and Zellij, probing only checks executable presence, Session names parse deterministically, create/destroy render safe commands, rename reports unsupported, and no version comparison occurs.
- [ ] Run `swift test --package-path Packages/ConnPackages --filter ZellijProviderTests` and the registry test filter; confirm failures are caused by the missing provider.
- [ ] Extend the failing tests for PTY allocation, attach command quoting, private handshake removal, output forwarding, resize/write forwarding, idempotent close, reconnect routing, and missing Session classification.
- [ ] Implement configuration, runtime discovery cache, Session name validation, list/create/destroy methods, opaque workspace payloads, registry registration, attach startup script, readiness gate, process-backed `ShellChannel`, and attachment lifecycle.
- [ ] Re-run the focused tests and confirm they pass.

### Task 2: Zellij-native quick actions and serialized PTY writes

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/ZellijInteraction.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/ZellijAttachment.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/ZellijInteractionTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/ZellijProviderTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`
- Modify: `Conn/ConnTests/LocalizationCoverageTests.swift`

- [ ] Write failing tests for Zellij-specific sections, exact default key bytes, target/generation/revision validation, explicit unsupported history/scroll behavior, destructive confirmation, repeat handling, and no swipe descriptors.
- [ ] Add a concurrency regression test proving one macro write cannot interleave with ordinary `ShellChannel.write` calls.
- [ ] Add Session-close tests proving `.workspaceClosed` is returned only after the attach process exits; timeout/mode mismatch must preserve the workspace.
- [ ] Run the focused interaction tests and verify the expected failures.
- [ ] Implement typed Zellij actions/key macros, attachment-level serialized writer, and the lightweight interaction facet; do not add topology state, swipe descriptors, or tmux operations.
- [ ] Add five-language localized labels for every new section/action.
- [ ] Extend localization source scanning to include Zellij descriptors, then re-run interaction and localization coverage tests.

### Task 3: Provider-neutral new-terminal UI

**Files:**
- Modify: `Conn/Conn/Terminal/NewTerminalSheet.swift`
- Modify: `Conn/Conn/Terminal/NewTerminalSheetSmokeView.swift`
- Modify: `Conn/Conn/Localizable.xcstrings`
- Modify: `Packages/ConnPackages/Tests/ConnTerminalTests/NewTerminalFlowModelTests.swift`
- Modify: `Conn/ConnUITests/NewTerminalSessionPickerUITests.swift`

- [ ] Add a failing `NewTerminalFlowModelTests` case proving selecting Zellij invokes only its option and returns a Zellij descriptor, never tmux configuration.
- [ ] Run `swift test --package-path Packages/ConnPackages --filter NewTerminalFlowModelTests` and confirm the new case fails for the intended provider-routing assertion.
- [ ] Update the UI test first to require a generic persistent-terminal entry, explicit tmux/Zellij provider selection, and Zellij Session loading.
- [ ] Run the focused XCUITest and confirm it fails against the hard-coded tmux UI.
- [ ] Replace hard-coded tmux loading/title/empty labels with provider-neutral localized copy and update the deterministic smoke fixture to publish both providers.
- [ ] Add five-language localizations, re-run the focused `NewTerminalFlowModelTests`, then re-run the focused XCUITest.

### Task 4: Zellij quick-panel UI acceptance

**Files:**
- Modify: `Conn/Conn/Terminal/TerminalTmuxQuickActionSmokeSupport.swift`
- Modify: `Conn/Conn/Terminal/TerminalSmokeLaunchView.swift`
- Modify: `Conn/ConnUITests/TerminalKeybarLayoutUITests.swift`

- [ ] Add a failing XCUITest that launches a Zellij smoke attachment, opens the Zellij provider tab, verifies native sections/actions, and verifies close-pane uses the system Alert.
- [ ] Run the focused test and confirm it fails before smoke support exists.
- [ ] Extend the provider-neutral smoke path to install the real Zellij quick-action descriptors/facet without changing production UI rendering.
- [ ] Re-run the focused XCUITest and confirm the App remains foreground and the panel is usable.

### Task 5: Regression verification

**Files:**
- Modify only files required by failures attributable to this feature.

- [ ] Run `swift test --package-path Packages/ConnPackages --filter ZellijProviderTests`, `swift test --package-path Packages/ConnPackages --filter ZellijInteractionTests`, and `swift test --package-path Packages/ConnPackages --filter NewTerminalFlowModelTests` for fast focused feedback.
- [ ] Reconfirm the current device with `xcrun simctl list devices booted`; abort rather than substitute a different UDID if `DDACC334-4130-4FA3-AC0A-A28B62F71FC1` is no longer the sole booted device.
- [ ] Run `xcodebuild test -project Conn/Conn.xcodeproj -scheme Conn -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -only-testing:ConnTests/LocalizationCoverageTests` for localization catalog and placeholder coverage.
- [ ] Run `xcodebuild test -project Conn/Conn.xcodeproj -scheme ConnMultiplexer -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`.
- [ ] Run `xcodebuild test -project Conn/Conn.xcodeproj -scheme ConnTerminal -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`.
- [ ] Run `xcodebuild test -project Conn/Conn.xcodeproj -scheme Conn -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -only-testing:ConnUITests/NewTerminalSessionPickerUITests -only-testing:ConnUITests/TerminalKeybarLayoutUITests/testExpandedZellijPanelShowsNativeActionsAndConfirmation`.
- [ ] Review `git diff --check`, `git status --short`, and the complete diff while preserving unrelated Citadel/JumpChain changes.
