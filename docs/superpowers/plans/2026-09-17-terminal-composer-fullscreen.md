# Terminal Composer Fullscreen Implementation Plan

> Execute inline in the current user workspace; preserve all existing changes. No commit or push requested.

**Goal:** Fixed one-line compact input, a right-side fullscreen editor sharing the draft, closer shortcut spacing, and no keyboard dismissal when recording starts/stops.

**Architecture:** ConnTerminal owns presentation only. Use one shared native UITextView adapter: the compact presentation exposes exactly one font line inside the 36pt capsule; fullscreen exposes the multiline viewport. The initial UITextField approach was rejected after tests proved it normalizes newlines to spaces. The delegate rejects user edits while recording without disabling the responder. The host overlays the editor in place: do not present a modal that triggers terminal detachment. Submission continues through the existing target-validated paste path.

**Tech Stack:** SwiftUI, UIKit, ConnUI localization/design tokens, XCTest/XCUITest; iOS 17+.

## Design

- Compact row retains 36pt visuals. Per the user's explicit follow-up, hit bounds equal visible button bounds (36pt voice, 26pt expand/send), overriding the repository's usual 44pt minimum. Both expand and send sit inside the input capsule, with expand immediately left of send; microphone stays outside. Removing oversized targets brings the two visible rows 4pt closer. The latest follow-up increases only the top inset from 4pt to 8pt, so the final compact accessory is 90pt tall; inter-row spacing is unchanged.
- Fullscreen editor fills the current terminal area, respects safe areas/keyboard, and shares the exact draft binding. Header has title and Done; footer has recording and paste controls. Done preserves text and restores compact focus. No implicit send on Return or dismissal.
- Follow-up: compact Return now sends and executes per the later submit plan; expanded Return still edits. Opening must not dismiss first. Done hands the responder to the mounted compact editor before removing the overlay; a hidden keyboard stays hidden.
- Recording retains the current keyboard state. Block text changes through native delegates during listening/stopping, but keep the same enabled first responder. Explicit keyboard dismissal remains available.
- Only new package-localized keys are added; preserve the unrelated pre-existing App localization changes.

## Keyboard regression correction

The original component-state tests did not exercise the App's global blank-tap recognizer, which could dismiss the keyboard after a voice button action. The original fullscreen UI check also typed a probe after closing, potentially reopening the keyboard before asserting visibility. These are verification gaps, not evidence that the reported behavior was acceptable.

- Protect both exact composer input IDs in the global gesture's initial decision and delayed dismissal; protect composer/input-bar button ancestry. Ordinary form behavior remains unchanged.
- Remove the explicit dismiss token on expansion and unconditional focus token on collapse. Share weak native input references via a per-host environment handoff and transfer focus before overlay removal.
- Production-composition tests additionally exposed early resignation from `allowsHitTesting(false)` and focus requests lost before window attachment. Keep the base interactive under the opaque fullscreen overlay (accessibility remains hidden), and recheck the latest focus binding when the native input attaches to a window. Assert actual expanded focus and zero hide notifications across repeated round trips.
- Add keyboard-hide notification coverage and assert UI keyboard visibility before any tap or typing. Record actual device and skips separately; do not reuse the prior iPhone 17 Pro result as proof of this fix.

## Tasks

- [x] Add failing production-hosted tests in `Conn/ConnTests/TerminalComposerAppearanceTests.swift` for responder retention through listening/stopping/idle and read-only editing during capture; add fullscreen round-trip to the existing XCUITest.
- [x] Add native input adapter in `Packages/ConnPackages/Sources/ConnTerminal/TerminalComposerTextInput.swift`; cover Return/newline preservation, selection, recording lock, programmatic transcript updates, and marked-text synchronization.
- [x] Update `TerminalCommandComposer.swift` with compact input/expand control and reusable action controls; add `TerminalComposerExpandedEditor.swift`. Overlay it from `TerminalHostingView.swift` without removing the live terminal or changing network/database behavior.
- [x] Add five-language strings in `Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`; update design/acceptance documentation.
- [x] Run targeted package tests, App rendering/focus/localization/layout tests and the expanded XCUITest on iPhone 17 Pro (`DDACC334-4130-4FA3-AC0A-A28B62F71FC1`), with parallel testing disabled. Inspect screenshots, review changes, and run `git diff --check`. Latest top-inset follow-up: 9 production component tests + full UI flow passed in `/tmp/conn-composer-top-inset-verified.xcresult`.

## Verification commands

```bash
swift test --package-path Packages/ConnPackages --filter 'TerminalCommandComposerTests|TerminalSessionTests|TerminalSpeech|TerminalTextInsertion'
xcodebuild test -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  -only-testing:ConnTests/LocalizationCoverageTests \
  -only-testing:ConnTests/TerminalLayoutTests \
  -only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend
```
