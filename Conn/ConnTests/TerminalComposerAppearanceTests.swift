import ConnUI
import ConnSSH
import ConnMultiplexer
import SwiftUI
import SwiftTerm
import UIKit
import XCTest
@testable import ConnTerminal

/// Render the production accessory itself, with no SSH accounts or test routes in the app.
@MainActor
final class TerminalComposerAppearanceTests: XCTestCase {
    func testExpandedSendMatchesVoiceSizeWithoutChangingCompactSend() {
        func measure<V: View>(_ view: V, typeSize: DynamicTypeSize) -> CGSize {
            let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, typeSize))
            host.safeAreaRegions = []
            return host.sizeThatFits(in: CGSize(width: 400, height: 200))
        }
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let voice = measure(TerminalComposerVoiceButton(
                state: .idle, isSubmitting: false, action: {}
            ), typeSize: typeSize)
            for canSend in [false, true] {
                let expanded = measure(TerminalComposerSendButton(
                    canSend: canSend, isExpanded: true, action: {}
                ), typeSize: typeSize)
                let compact = measure(TerminalComposerSendButton(
                    canSend: canSend, action: {}
                ), typeSize: typeSize)
                XCTAssertEqual(expanded.width, voice.width, accuracy: 0.5)
                XCTAssertEqual(expanded.height, voice.height, accuracy: 0.5)
                XCTAssertLessThan(compact.width, expanded.width)
                if typeSize == .large {
                    XCTAssertEqual(expanded.width, 36, accuracy: 0.5)
                    XCTAssertEqual(compact.width, 26, accuracy: 0.5)
                }
            }
        }
    }

    func testExpandedEditorFocusesWhenAttachedToWindow() async throws {
        let host = UIHostingController(rootView: TerminalComposerExpandedEditor(
            text: .constant("draft"), isSubmitting: false, speechState: .idle,
            onSubmit: { _ in }, onToggleSpeech: {}, onDone: {}
        ))
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 800)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = host.view.frame
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        host.view.layoutIfNeeded()
        let input = try XCTUnwrap(findTextInput(in: host.view))
        for _ in 0..<100 where !input.isFirstResponder {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(input.isFirstResponder, "A pre-mount focus request must not be lost")
    }

    func testProductionEditorsRoundTripWithoutKeyboardHide() async throws {
        let state = ComposerPresentationFixture()
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: ComposerPresentationFixtureView(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 800)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        host.view.layoutIfNeeded()
        state.focusRequest += 1
        let compact = try XCTUnwrap(findTextInput(in: host.view) as? UITextView)
        for _ in 0..<100 where !compact.isFirstResponder {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(compact.isFirstResponder)
        let events = KeyboardHideEvents()
        let observation = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { events.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observation) }
        func editor(_ identifier: String, in view: UIView) -> UITextView? {
            if let input = view as? UITextView, input.accessibilityIdentifier == identifier { return input }
            return view.subviews.lazy.compactMap { editor(identifier, in: $0) }.first
        }
        for _ in 0..<2 {
            state.expanded = true
            for _ in 0..<100 where editor("terminal.composer.expanded-input", in: host.view)?.isFirstResponder != true {
                try await Task.sleep(for: .milliseconds(10))
                host.view.layoutIfNeeded()
            }
            let expanded = try XCTUnwrap(editor("terminal.composer.expanded-input", in: host.view))
            XCTAssertFalse(compact.isFirstResponder, "The full editor must take focus")
            XCTAssertTrue(expanded.isFirstResponder, "The expanded client must actually own focus")
            XCTAssertEqual(events.count, 0, "Opening must not hide the keyboard")
            XCTAssertNotNil(compact.window, "The original compact client must remain mounted")
            XCTAssertTrue(state.handoff.returnToCompact(), "The real hidden compact editor must accept focus")
            XCTAssertTrue(compact.isFirstResponder, "Focus transfers before the full editor is removed")
            state.expanded = false
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            XCTAssertTrue(compact.isFirstResponder, "Stale full-editor callbacks must not steal focus")
        }
        XCTAssertEqual(events.count, 0, "Expand/collapse must not hide the keyboard between native clients")
        XCTAssertEqual(state.text, "draft\n第二行")
    }

    func testFullscreenHandsResponderBackBeforeRemovingEditor() async throws {
        let handoff = TerminalComposerFocusHandoff()
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        let compact = UITextView(frame: CGRect(x: 0, y: 400, width: 300, height: 36))
        let expanded = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        host.view.addSubview(compact)
        host.view.addSubview(expanded)
        handoff.register(compact, compact: true)
        handoff.register(expanded, compact: false)
        XCTAssertTrue(compact.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(100))
        let events = KeyboardHideEvents()
        let observation = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { events.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observation) }

        // Opening hands off without resigning compact. Closing must move focus
        // back while fullscreen still belongs to the window, not after teardown.
        XCTAssertTrue(expanded.becomeFirstResponder())
        handoff.returnToCompact()
        XCTAssertTrue(compact.isFirstResponder, "Done must transfer before removing fullscreen")
        expanded.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(compact.isFirstResponder)
        XCTAssertEqual(events.count, 0, "A successful focus handoff must never hide the keyboard")
    }

    func testFullscreenDismissalDoesNotOpenAnAlreadyHiddenKeyboard() {
        let handoff = TerminalComposerFocusHandoff()
        let compact = UITextView()
        let expanded = UITextView()
        handoff.register(compact, compact: true)
        handoff.register(expanded, compact: false)
        handoff.returnToCompact()
        XCTAssertFalse(compact.isFirstResponder)
        XCTAssertFalse(expanded.isFirstResponder)
    }
    func testComposerSubmissionUsesOnePacketAndOnlyKeyboardExecutionAddsReturn() async throws {
        let draft = "  printf one\n第二行\r\nlast  "
        for bracketed in [false, true] {
            let fixture = await makeSubmissionFixture(bracketed: bracketed)
            defer { fixture.controller.detach() }
            let target = try XCTUnwrap(fixture.controller.currentComposerTarget())
            fixture.controller.ctrlActive = true
            let insertion = fixture.controller.submitComposerText(draft, target: target)
            if bracketed {
                XCTAssertEqual(insertion, .accepted)
            } else {
                XCTAssertEqual(insertion, .requiresConfirmation)
                XCTAssertTrue(fixture.channel.writes.isEmpty)
                XCTAssertEqual(fixture.controller.submitComposerText(
                    draft, target: target, confirmsUnsafeMultiline: true
                ), .accepted)
            }
            XCTAssertEqual(fixture.controller.submitComposerText(draft, target: target, intent: .execute), .accepted)
            for _ in 0..<100 where fixture.channel.writes.count < 2 {
                try await Task.sleep(for: .milliseconds(10))
            }
            let paste = bracketed ? "\u{1B}[200~" + draft + "\u{1B}[201~" : draft
            XCTAssertEqual(fixture.channel.writes, [Data(paste.utf8), Data((paste + "\r").utf8)])
            XCTAssertTrue(fixture.controller.ctrlActive, "Composer must bypass sticky Ctrl")
            await fixture.session.close()
            XCTAssertEqual(fixture.controller.submitComposerText("after close", target: target, intent: .execute), .unavailable)
            XCTAssertEqual(fixture.channel.writes.count, 2)
            _ = fixture.view // Keep the weakly attached emulator alive throughout the test.
        }
    }

    func testComposerRejectsStaleConfirmationTargetAndDetachedView() async throws {
        let fixture = await makeSubmissionFixture(bracketed: false)
        defer { fixture.controller.detach() }
        let target = try XCTUnwrap(fixture.controller.currentComposerTarget())
        XCTAssertEqual(fixture.controller.submitComposerText("one\ntwo", target: target), .requiresConfirmation)
        let staleTargets = [
            TerminalComposerTarget(tabID: "other", generation: 1),
            TerminalComposerTarget(tabID: "composer-test", generation: 2),
            TerminalComposerTarget(tabID: "composer-test", generation: 1, persistentTarget: .init(
                providerID: "tmux", workspaceID: "workspace", targetID: "pane"
            )),
            TerminalComposerTarget(tabID: "composer-test", generation: 1, persistentTarget: .init(
                providerID: "zellij", workspaceID: "workspace", targetID: "pane"
            ))
        ]
        for stale in staleTargets {
            XCTAssertEqual(fixture.controller.submitComposerText("one\ntwo", target: stale, confirmsUnsafeMultiline: true), .unavailable)
        }
        fixture.controller.detach()
        XCTAssertEqual(fixture.controller.submitComposerText("one\ntwo", target: target, intent: .execute), .unavailable)
        XCTAssertTrue(fixture.channel.writes.isEmpty)
        await fixture.session.close()
        _ = fixture.view
    }

    private func makeSubmissionFixture(bracketed: Bool) async -> (
        controller: TerminalInputController, view: KeybarTerminalView,
        session: TerminalSession, channel: ComposerRecordingChannel
    ) {
        let channel = ComposerRecordingChannel()
        let transcript = TerminalTranscript()
        await transcript.activateGeneration(1)
        let session = TerminalSession(channel: channel, transcript: transcript, generation: 1)
        let controller = TerminalInputController(
            session: session, transcript: transcript, persistentAttachment: nil, persistentInteraction: nil,
            tabID: "composer-test", terminalGeneration: 1,
            onPersistentWorkspaceRenamed: { _ in }, onPersistentWorkspaceChanged: { _, _ in },
            onPersistentWorkspaceClosed: {}, onPersistentWorkingDirectoryChanged: { _ in },
            onTerminalWorkingDirectoryChanged: { _, _, _ in }
        )
        let view = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: 393, height: 500))
        view.terminalDelegate = controller
        controller.attach(view)
        for _ in 0..<100 where controller.currentComposerTarget() == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(controller.currentComposerTarget(), "Fixture must finish replay before input")
        view.feed(byteArray: Array((bracketed ? "\u{1B}[?2004h" : "\u{1B}[?2004l").utf8)[...])
        return (controller, view, session, channel)
    }
    func testRecordingTransitionsKeepTheSameKeyboardResponder() async throws {
        let state = ComposerFocusFixture()
        // Rebuild through an observable fixture so updates reach the production view.
        let fixtureHost = UIHostingController(rootView: ComposerFocusFixtureView(state: state))
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 700))
        window.rootViewController = fixtureHost
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        fixtureHost.view.layoutIfNeeded()
        state.focusRequest += 1
        try await Task.sleep(for: .milliseconds(200))
        let field = try XCTUnwrap(findTextInput(in: fixtureHost.view))
        XCTAssertTrue(field.isFirstResponder)
        for speech in [TerminalSpeechComposerState.listening, .stopping, .idle] {
            state.speech = speech
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(field.isFirstResponder, "Recording state \(speech) must not dismiss the keyboard")
            if speech.isCapturing {
                if let field = field as? UITextField {
                    XCTAssertEqual(field.delegate?.textField?(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "x"), false)
                } else if let editor = field as? UITextView {
                    XCTAssertEqual(editor.delegate?.textView?(editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "x"), false)
                }
            }
        }
    }

    private func findTextInput(in view: UIView) -> UIView? {
        if view is UITextField || view is UITextView { return view }
        return view.subviews.lazy.compactMap { self.findTextInput(in: $0) }.first
    }

    func testCompactReturnSubmitsWithoutAddingNewline() throws {
        var draft = "echo 👋\n第二行"
        var submitted: [String] = []
        let input = TerminalComposerTextEditor(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(true), isReadOnly: false, fontSize: 16, compact: true,
            onSubmit: { submitted.append(draft) }
        )
        let coordinator = input.makeCoordinator()
        let field = UITextView()
        field.delegate = coordinator
        field.text = draft
        field.selectedRange = NSRange(location: draft.utf16.count, length: 0)
        // insertText is a programmatic edit and bypasses shouldChangeTextIn,
        // even for a first responder. Exercise the keyboard's delegate gate;
        // XCUITest separately types Return through the actual system keyboard.
        XCTAssertFalse(coordinator.textView(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n"))
        XCTAssertEqual(submitted, ["echo 👋\n第二行"])
        XCTAssertEqual(draft, "echo 👋\n第二行")
        XCTAssertEqual(field.text, draft)

        coordinator.parent.isReadOnly = true
        XCTAssertFalse(coordinator.textView(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n"))
        XCTAssertEqual(submitted.count, 1, "Readonly recording/submission must not send again")
        coordinator.parent.isReadOnly = false
        field.text = ""
        draft = ""
        XCTAssertFalse(coordinator.textView(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n"))
        XCTAssertEqual(submitted.count, 1, "Empty Return must not execute anything in the terminal")
    }

    func testCompactMultilinePasteDoesNotSubmit() throws {
        var draft = ""
        var submissions = 0
        let input = TerminalComposerTextEditor(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(true), isReadOnly: false, fontSize: 16, compact: true,
            onSubmit: { submissions += 1 }
        )
        let coordinator = input.makeCoordinator()
        let field = UITextView()
        field.delegate = coordinator
        field.insertText("echo 👋\n第二行\r\n第三行")
        XCTAssertEqual(draft, "echo 👋\n第二行\r\n第三行")
        XCTAssertEqual(submissions, 0)
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(field.markedTextRange)
        _ = coordinator.textView(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n")
        XCTAssertEqual(submissions, 0, "Confirming IME candidates must not submit")
    }

    func testPastingASingleNewlineNeverExecutesTheDraft() throws {
        var draft = "printf hello"
        var submissions = 0
        let input = TerminalComposerTextEditor(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(true), isReadOnly: false, fontSize: 16, compact: true,
            onSubmit: { submissions += 1 }
        )
        let coordinator = input.makeCoordinator()
        let field = UITextView()
        field.delegate = coordinator
        field.text = draft
        let end = try XCTUnwrap(field.textRange(from: field.endOfDocument, to: field.endOfDocument))
        _ = coordinator.textPasteConfigurationSupporting(
            field, performPasteOf: NSAttributedString(string: "\n"), to: end
        )
        XCTAssertEqual(draft, "printf hello\n")
        XCTAssertEqual(submissions, 0)
        coordinator.parent.isReadOnly = true
        _ = coordinator.textPasteConfigurationSupporting(
            field, performPasteOf: NSAttributedString(string: "replacement"), to: end
        )
        XCTAssertEqual(draft, "printf hello\n", "An asynchronously loaded paste must respect the latest readonly state")
    }

    func testCompactAndExpandedKeyboardReturnTypes() async throws {
        for expanded in [false, true] {
            let state = ComposerFocusFixture()
            state.expanded = expanded
            let host = UIHostingController(rootView: ComposerFocusFixtureView(state: state))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            let editor = try XCTUnwrap(findTextInput(in: host.view) as? UITextView)
            XCTAssertEqual(editor.returnKeyType, expanded ? .default : .send)
            XCTAssertEqual(editor.enablesReturnKeyAutomatically, !expanded)
        }
    }

    func testExpandedReturnAndPastePreserveExactDraft() throws {
        var draft = "echo 👋"
        let input = TerminalComposerTextEditor(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(true), isReadOnly: false, fontSize: 16
        )
        let coordinator = input.makeCoordinator()
        let field = UITextView()
        field.delegate = coordinator
        field.text = draft
        field.selectedRange = NSRange(location: draft.utf16.count, length: 0)
        field.insertText("\n")
        XCTAssertEqual(draft, "echo 👋\n", "Return appends a draft newline without submitting")
        field.insertText("第二行\r\n第三行")
        XCTAssertEqual(draft, "echo 👋\n第二行\r\n第三行")
        XCTAssertEqual(field.text, draft)
        coordinator.parent.isReadOnly = true
        XCTAssertFalse(coordinator.textView(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n"))
        XCTAssertFalse(coordinator.textView(field, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementText: ""))
        XCTAssertEqual(draft, "echo 👋\n第二行\r\n第三行", "Capture must reject deletion and Return")
    }

    func testExpandedRecordingKeepsFocusAndAcceptsTranscriptUpdates() async throws {
        let state = ComposerFocusFixture()
        state.expanded = true
        let host = UIHostingController(rootView: ComposerFocusFixtureView(state: state))
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let editor = try XCTUnwrap(findTextInput(in: host.view) as? UITextView)
        XCTAssertTrue(editor.isFirstResponder)
        for speech in [TerminalSpeechComposerState.listening, .stopping, .idle, .unavailable] {
            state.speech = speech
            state.text = speech.isCapturing ? "draft\n转写内容 👋" : "draft"
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(editor.isFirstResponder, "Stopping/error recovery must retain the keyboard")
            XCTAssertEqual(editor.text, state.text, "Programmatic transcript updates must still apply")
            XCTAssertEqual(editor.delegate?.textView?(editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "x"), !speech.isCapturing)
        }
    }

    func testRecordingWithKeyboardHiddenDoesNotOpenIt() async throws {
        let state = ComposerFocusFixture()
        let host = UIHostingController(rootView: ComposerFocusFixtureView(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 700))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let field = try XCTUnwrap(findTextInput(in: host.view))
        for speech in [TerminalSpeechComposerState.listening, .stopping, .idle] {
            state.speech = speech
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(field.isFirstResponder)
        }
    }

    func testMarkedTextDoesNotBlockRecordingTranscriptOrDraftClear() async throws {
        for expanded in [false, true] {
            let state = ComposerFocusFixture()
            state.expanded = expanded
            let host = UIHostingController(rootView: ComposerFocusFixtureView(state: state))
            let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previousWindow?.makeKey() }
            host.view.layoutIfNeeded()
            state.focusRequest += 1
            try await Task.sleep(for: .milliseconds(200))
            let view = try XCTUnwrap(findTextInput(in: host.view))
            let input = try XCTUnwrap(view as? any UITextInput)
            XCTAssertTrue(view.isFirstResponder)
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertNotNil(input.markedTextRange, "Fixture must establish active IME composition")
            let composingDraft = state.text
            state.speech = .unavailable // An unrelated presentation update must not commit IME.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNotNil(input.markedTextRange, "Normal composition must survive view updates")
            XCTAssertEqual(state.text, composingDraft)
            state.speech = .listening
            state.text = "draft ni 转写内容"
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNil(input.markedTextRange, "Capture should settle composition without resigning")
            XCTAssertEqual(input.text(in: input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)!), state.text)
            XCTAssertTrue(view.isFirstResponder)
            state.speech = .idle
            try await Task.sleep(for: .milliseconds(100))
            input.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0))
            XCTAssertNotNil(input.markedTextRange)
            state.text = "" // Successful submission clears the authoritative draft.
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(input.text(in: input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)!), "")
            XCTAssertTrue(view.isFirstResponder)
        }
    }

    func testCompactAccessoryAndSpeechStates() async {
        for scheme in [ColorScheme.dark, .light] {
            for state in [TerminalSpeechComposerState.idle, .unavailable, .listening, .stopping] {
                for text in ["", "列出当前目录的文件"] {
                    let height = await capture(
                        name: "composer-\(scheme)-\(state)-\(text.isEmpty ? "empty" : "draft")",
                        text: text,
                        speechState: state,
                        colorScheme: scheme,
                        width: 393
                    )
                    XCTAssertEqual(height, 90, accuracy: 0.5, "Speech state must not change accessory height")
                }
            }
        }
    }

    func testMultilineIsBoundedOnNarrowAndWideScreens() async {
        let text = "printf one\nprintf two\nprintf three\nprintf four\nprintf five\nprintf six"
        for width in [CGFloat(320), 700] {
            let height = await capture(
                name: "composer-multiline-\(Int(width))",
                text: text, speechState: .idle, colorScheme: .dark, width: width
            )
            XCTAssertEqual(height, 90, accuracy: 0.5, "Multiline drafts must scroll without growing the editor")
        }
    }

    func testLargeTypeFitsAndExpandedKeysStayInsideAccessory() async {
        let height = await capture(
            name: "composer-large-type-idle", text: "查看运行状态", speechState: .idle,
            colorScheme: .light, width: 320, typeSize: .accessibility3
        )
        XCTAssertGreaterThan(height, 94, "The fixed viewport must still accommodate Dynamic Type")
        XCTAssertLessThan(height, 180)
        for state in [TerminalSpeechComposerState.listening, .stopping, .unavailable] {
            let activeHeight = await capture(
                name: "composer-large-type-\(state)", text: "查看运行状态", speechState: state,
                colorScheme: .light, width: 320, typeSize: .accessibility3
            )
            XCTAssertEqual(activeHeight, height, accuracy: 0.5)
        }
        let expanded = await capture(
            name: "composer-expanded", text: "", speechState: .idle,
            colorScheme: .dark, width: 393, expanded: true
        )
        XCTAssertLessThanOrEqual(expanded, 350)
    }

    func testTouchGlowCrossesRowBoundaryButNotOuterSurface() throws {
        for scheme in [ColorScheme.dark, .light] {
            func render(opacity: CGFloat) throws -> CGImage {
                let renderer = ImageRenderer(content:
                    TerminalInputBarBackground(
                        touchLocation: CGPoint(x: 196, y: 70), scale: 1.08, opacity: opacity
                    )
                    .frame(width: 393, height: 90)
                    .padding(12)
                    .background(Color.pink)
                    .environment(\.colorScheme, scheme)
                )
                renderer.scale = 1
                return try XCTUnwrap(renderer.cgImage)
            }
            let plain = try render(opacity: 0)
            let pressed = try render(opacity: 1)
            // The two rows meet at y=44. Sample either side of that seam,
            // away from control backgrounds, in the production shared surface.
            let above = try brightness(pressed, x: 208, y: 54) - brightness(plain, x: 208, y: 54)
            let below = try brightness(pressed, x: 208, y: 58) - brightness(plain, x: 208, y: 58)
            XCTAssertGreaterThan(abs(above), 0.05, "Glow must reach the composer row")
            XCTAssertGreaterThan(abs(below), 0.05, "Glow must reach the shortcut row")
            XCTAssertEqual(above, below, accuracy: 0.03, "No hard cutoff at the row boundary")
            XCTAssertEqual(
                try brightness(pressed, x: 208, y: 6), try brightness(plain, x: 208, y: 6),
                accuracy: 0.001, "Glow must not spill over terminal content"
            )
            let attachment = XCTAttachment(image: UIImage(cgImage: pressed))
            attachment.name = "composer-shared-glow-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func brightness(_ image: CGImage, x: Int, y: Int) throws -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }

    @discardableResult
    private func capture(
        name: String,
        text: String,
        speechState: TerminalSpeechComposerState,
        colorScheme: ColorScheme,
        width: CGFloat,
        typeSize: DynamicTypeSize = .large,
        expanded: Bool = false
    ) async -> CGFloat {
        let view = TerminalInputBar {
            TerminalCommandComposer(
                text: .constant(text), isSubmitting: .constant(false),
                speechState: speechState, onSubmit: { _ in }
            )
            TerminalKeybar(
                ctrlActive: false, isExpanded: expanded, onKey: { _ in },
                onPaste: { _ in }, onInsertToolCommand: { _ in },
                onCloseTerminal: {}, onSwitchTerminal: {}, onOpenFileBrowser: {},
                onChooseCommand: {}, onReconnect: {}, pointerAvailable: false,
                pointerActive: false, onTogglePointer: {}, providerQuickActionGroup: nil,
                performingProviderQuickActionID: nil, onProviderQuickAction: { _ in },
                keyboardVisible: false,
                onToggleKeyboard: {}, onExpansionChange: { _ in },
                attachmentState: .idle, onAttachmentAction: { _ in }
            )
            .frame(height: expanded ? TerminalKeybarMetrics.expandedHeight : TerminalKeybarMetrics.compactHeight)
        }
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, typeSize)

        let measuringHost = UIHostingController(rootView: view)
        measuringHost.safeAreaRegions = []
        let size = measuringHost.sizeThatFits(in: CGSize(width: width, height: 600))
        XCTAssertEqual(size.width, width, accuracy: 1)
        // Use a full-height key window: UIKit's native text editor needs a real
        // viewport, not an accessory-height/offscreen window, to draw its content.
        let host = UIHostingController(rootView:
            view.frame(width: width, height: size.height)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
        host.safeAreaRegions = []
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: max(600, size.height)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Let the native multiline field settle its scroll viewport after sizeThatFits.
        try? await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.translateBy(x: 0, y: -(window.bounds.height - size.height))
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        if typeSize == .accessibility3, speechState.isCapturing, !text.isEmpty {
            // A measured frame is not enough: the light large-type transcript
            // must also paint visible text inside the fixed viewport.
            if let cgImage = image.cgImage {
                let scale = CGFloat(cgImage.width) / width
                var darkSamples = 0
                for x in stride(from: 28, to: 128, by: 4) {
                    for y in stride(from: 12, to: Int(size.height - 46 - 12), by: 4) {
                        if let level = try? brightness(cgImage, x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale)),
                           level < 0.35 { darkSamples += 1 }
                    }
                }
                XCTAssertGreaterThan(darkSamples, 10, "Large-type recording text must remain visible")
            } else {
                XCTFail("Missing rendered transcript image")
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        previousKeyWindow?.makeKey()
        return size.height
    }
}

private final class ComposerRecordingChannel: ShellChannel, @unchecked Sendable {
    let output = AsyncThrowingStream<Data, Error> { _ in }
    private let lock = NSLock()
    private var recorded: [Data] = []
    var writes: [Data] { lock.withLock { recorded } }
    func write(_ bytes: Data) async throws { lock.withLock { recorded.append(bytes) } }
    func resize(_ size: TermSize) async throws {}
    func close() async {}
}

@MainActor
private final class KeyboardHideEvents {
    var count = 0
}

@MainActor @Observable
private final class ComposerFocusFixture {
    var text = "draft"
    var speech = TerminalSpeechComposerState.idle
    var focusRequest: UInt = 0
    var expanded = false
}

private struct ComposerFocusFixtureView: View {
    let state: ComposerFocusFixture
    var body: some View {
        if state.expanded {
            TerminalComposerExpandedEditor(
                text: Binding(get: { state.text }, set: { state.text = $0 }),
                isSubmitting: false, speechState: state.speech,
                onSubmit: { _ in }, onToggleSpeech: {}, onDone: {}
            )
        } else {
            TerminalCommandComposer(
                text: Binding(get: { state.text }, set: { state.text = $0 }),
                isSubmitting: .constant(false), speechState: state.speech,
                onSubmit: { _ in }, focusKeyboardRequest: state.focusRequest
            )
        }
    }
}

@MainActor @Observable
private final class ComposerPresentationFixture {
    var text = "draft\n第二行"
    var expanded = false
    var focusRequest: UInt = 0
    let handoff = TerminalComposerFocusHandoff()
}

private struct ComposerPresentationFixtureView: View {
    let state: ComposerPresentationFixture
    var body: some View {
        VStack {
            Spacer()
            TerminalCommandComposer(
                text: Binding(get: { state.text }, set: { state.text = $0 }),
                isSubmitting: .constant(false), onSubmit: { _ in },
                focusKeyboardRequest: state.focusRequest
            )
        }
        .accessibilityElement(children: state.expanded ? .ignore : .contain)
        .accessibilityHidden(state.expanded)
        .overlay {
            if state.expanded {
                TerminalComposerExpandedEditor(
                    text: Binding(get: { state.text }, set: { state.text = $0 }),
                    isSubmitting: false, speechState: .idle,
                    onSubmit: { _ in }, onToggleSpeech: {}, onDone: {}
                )
            }
        }
        .environment(\.terminalComposerFocusHandoff, state.handoff)
    }
}
