#if canImport(UIKit)
import ConnUI
import SwiftUI
import UIKit

/// Both presentations retain native multiline storage. UITextField normalizes
/// newlines to spaces; a one-line UITextView viewport does not alter the draft.
struct TerminalComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var isReadOnly: Bool
    var fontSize: CGFloat
    var compact = false
    var onSubmit: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalComposerFocusHandoff) private var focusHandoff

    func makeUIView(context: Context) -> UITextView {
        let editor = TerminalComposerNativeTextView()
        editor.backgroundColor = .clear
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        editor.keyboardDismissMode = .none
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.showsVerticalScrollIndicator = !compact
        editor.returnKeyType = compact ? .send : .default
        editor.enablesReturnKeyAutomatically = compact
        editor.delegate = context.coordinator
        editor.pasteDelegate = context.coordinator
        editor.accessibilityIdentifier = compact ? "terminal.composer.input" : "terminal.composer.expanded-input"
        editor.accessibilityLabel = L("待发送内容")
        editor.text = text
        editor.selectedRange = NSRange(location: text.utf16.count, length: 0)
        editor.onWindowAttachment = { [weak editor, weak coordinator = context.coordinator] in
            guard let editor else { return }
            coordinator?.updateFocus(of: editor)
        }
        focusHandoff?.register(editor, compact: compact)
        return editor
    }

    func updateUIView(_ editor: UITextView, context: Context) {
        context.coordinator.parent = self
        editor.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        editor.font = compact ? .systemFont(ofSize: fontSize) : .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editor.textColor = UIColor(Color.connInk)
        editor.tintColor = UIColor(Color.connAccent)
        // Normal IME updates already match the binding and stay marked. Settle
        // composition only at capture/external-update boundaries; never resign
        // the responder, and do not write stale composition back over a transcript.
        context.coordinator.isApplyingDraft = true
        defer { context.coordinator.isApplyingDraft = false }
        if editor.markedTextRange != nil, isReadOnly || editor.text != text {
            editor.unmarkText()
        }
        if editor.text != text {
            let selection = editor.selectedRange
            editor.text = text
            let start = min(selection.location, text.utf16.count)
            editor.selectedRange = isReadOnly ? NSRange(location: text.utf16.count, length: 0)
                : NSRange(location: start, length: min(selection.length, text.utf16.count - start))
            editor.scrollRangeToVisible(editor.selectedRange)
        }
        // Defer until UIKit has installed the view, then recheck the latest
        // binding so an old focus request cannot steal focus from fullscreen.
        if editor.isFirstResponder != isFocused {
            context.coordinator.updateFocus(of: editor)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: TerminalComposerTextEditor
        var isApplyingDraft = false
        private var isApplyingPaste = false
        init(_ parent: TerminalComposerTextEditor) { self.parent = parent }
        func updateFocus(of editor: UITextView) {
            DispatchQueue.main.async { [weak editor, weak self] in
                guard let editor, let self, editor.window != nil else { return }
                if parent.isFocused { editor.becomeFirstResponder() }
                else if editor.isFirstResponder { editor.resignFirstResponder() }
            }
        }
        func textViewDidChange(_ editor: UITextView) {
            guard !isApplyingDraft, !parent.isReadOnly else { return }
            parent.text = editor.text
        }
        func textViewDidBeginEditing(_ editor: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ editor: UITextView) { parent.isFocused = false }
        func textView(_ editor: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !parent.isReadOnly else { return false }
            if parent.compact, !isApplyingPaste, text == "\n", editor.markedTextRange == nil {
                if !editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parent.text = editor.text
                    parent.onSubmit()
                }
                return false
            }
            return true
        }

        // UIKit invokes this after asynchronous item loading, for both paste and
        // drop. A pasted lone newline is editing, never the keyboard send action.
        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            performPasteOf attributedString: NSAttributedString,
            to textRange: UITextRange
        ) -> UITextRange {
            guard let editor = textPasteConfigurationSupporting as? UITextView,
                  !parent.isReadOnly else { return textRange }
            isApplyingPaste = true
            defer { isApplyingPaste = false }
            let start = editor.offset(from: editor.beginningOfDocument, to: textRange.start)
            editor.replace(textRange, withText: attributedString.string)
            textViewDidChange(editor)
            guard let insertedStart = editor.position(from: editor.beginningOfDocument, offset: start),
                  let insertedEnd = editor.position(from: insertedStart, offset: attributedString.length),
                  let insertedRange = editor.textRange(from: insertedStart, to: insertedEnd)
            else { return textRange }
            return insertedRange
        }
    }
}

/// SwiftUI may update before attaching the UIKit client to its window. Retry at
/// attachment rather than losing the initial fullscreen focus request.
private final class TerminalComposerNativeTextView: UITextView {
    var onWindowAttachment: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onWindowAttachment?() }
    }
}
#endif
