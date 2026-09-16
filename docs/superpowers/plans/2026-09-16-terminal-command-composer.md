# Terminal Command Composer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-terminal-page command composer that lets users prepare multiline text and insert it into the active terminal without automatically executing it.

**Architecture:** Keep the composer as a presentation-layer feature in `ConnTerminal`. A pure state model owns draft/submission semantics, while `TerminalHostContent` supplies an immutable tab/session target to `TerminalInputController`. The existing serialized outbound queue remains the single write path; composer paste is marked separately so a failed or stale target cannot clear the draft.

**Tech Stack:** Swift 5, SwiftUI, SwiftTerm, Swift Package Testing, XCUITest, existing ConnUI localization and design tokens.

---

## Task 1: Add failing tests for composer state and submission semantics

**Files:**
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalCommandComposerTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionTests.swift`

- [x] Add pure tests for an empty/whitespace-only draft, raw whitespace and newlines preservation, begin/finish submission, and rejection of a second submission while one is in flight.
- [x] Add a queue regression test proving `enqueue` is accepted only while the outbound queue is alive and is rejected after termination.
- [x] Run the focused package tests and confirm they fail because the new state API and Boolean enqueue contract do not exist yet.

## Task 2: Implement the pure composer model and reusable SwiftUI composer

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnTerminal/TerminalCommandComposer.swift`

- [x] Add `TerminalCommandComposerState` with draft text, submission guard, success-only clearing, and reset semantics. Preserve the exact draft bytes represented by the String; only whitespace-only validation is applied to the send decision.
- [x] Add immutable `TerminalComposerTarget` containing tab ID, terminal generation, and optional persistent-terminal target.
- [x] Add `TerminalCommandComposer` with a one-line default editor, multiline growth capped at four lines, internal scrolling beyond the cap, a 44pt send target, and stable accessibility identifiers. Return inserts a newline; no submit-on-return behavior is added.
- [x] Use existing ConnUI design tokens and `L()` localization; do not add terminal-specific ad hoc colors or user-visible literals.
- [x] Run the focused package tests and the package build.

## Task 3: Connect the composer to the existing serialized terminal write path

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSession.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`

- [x] Change the outbound queue and `TerminalSession.enqueue` to return whether the request was registered under the queue lock. A true result means accepted by the queue, not that the transport has already written the bytes.
- [x] Add immutable target capture and synchronous validation against the current tab, generation, attach state, and provider-owned target before submitting composer text.
- [x] Route composer insertion through `terminalView.paste(text:)` so bracketed-paste handling and existing terminal encoding remain authoritative; do not append CR/LF. Reject unsafe multiline input when bracketed paste is not enabled.
- [x] Keep direct keyboard input, shortcut keys, command picker, and attachment insertion behavior unchanged.
- [x] Preserve drafts per tab while the terminal page remains alive; reject and retain the draft on stale generation, closed session, detached session, or provider target mismatch. Close/reconnect replacement terminates the old session and invalidates pending submissions.
- [x] Add package-level coverage for exact submitted bytes, safe multiline policy, target identity, and close/enqueue race linearization; existing SwiftTerm tests cover bracketed-paste markers.

## Task 4: Add localized strings and UI regression coverage

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`
- Modify: `Conn/ConnUITests/ConnUITests.swift`

- [x] Add `待发送内容` and `发送` translations for zh-Hans, zh-Hant, en, ja, and ko.
- [x] Add an XCUITest using existing terminal demo/fixture entry points to verify the composer is visible, accepts multiline input, keeps Return as draft input, and exposes a send control without introducing a test-only transport seam.
- [x] Run localization/source checks and the focused UI test on the currently available device; record any device or signing limitation as a test limitation.

## Task 5: Verify and review the complete change

**Files:**
- No additional files expected.

- [ ] Run `swift test --package-path Packages/ConnPackages`.
- [x] Run the relevant `xcodebuild` build/tests on the currently available device or simulator with parallel testing disabled.
- [x] Run `git diff --check`, inspect the complete diff, and confirm no generated files or unrelated changes were added.
- [x] Request a focused code review for correctness, lifecycle behavior, accessibility, and scope; address actionable findings within the confirmed design.

Verification note: the full package suite was attempted and the Swift Testing runner exited with signal 10 in the existing large-suite run; the focused ConnTerminal suite passed 15/15 tests. The app unit suite ran 310 tests with one unrelated pre-existing ordering assertion failure in `AppWideUIConsistencyTests.swift:722`.
