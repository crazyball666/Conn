#if canImport(UIKit)
import SwiftUI
import UIKit

/// Both editor presentations remain native inputs. Transfer directly while both
/// are still in the window; removing the focused editor first hides the keyboard.
@MainActor
final class TerminalComposerFocusHandoff {
    private weak var compactEditor: UITextView?
    private weak var expandedEditor: UITextView?

    func register(_ editor: UITextView, compact: Bool) {
        if compact { compactEditor = editor }
        else { expandedEditor = editor }
    }

    @discardableResult
    func returnToCompact() -> Bool {
        // Do not open a keyboard that the user had already hidden.
        guard expandedEditor?.isFirstResponder == true else { return true }
        guard let compactEditor, compactEditor.window != nil else { return false }
        return compactEditor.becomeFirstResponder() && compactEditor.isFirstResponder
    }
}

private struct TerminalComposerFocusHandoffKey: EnvironmentKey {
    static let defaultValue: TerminalComposerFocusHandoff? = nil
}

extension EnvironmentValues {
    var terminalComposerFocusHandoff: TerminalComposerFocusHandoff? {
        get { self[TerminalComposerFocusHandoffKey.self] }
        set { self[TerminalComposerFocusHandoffKey.self] = newValue }
    }
}
#endif
