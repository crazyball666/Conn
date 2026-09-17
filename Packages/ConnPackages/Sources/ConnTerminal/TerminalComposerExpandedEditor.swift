#if canImport(UIKit)
import ConnUI
import SwiftUI

/// In-place presentation: the terminal stays mounted and connected underneath.
struct TerminalComposerExpandedEditor: View {
    @Binding var text: String
    var isSubmitting: Bool
    var speechState: TerminalSpeechComposerState
    var onSubmit: (String) -> Void
    var onToggleSpeech: () -> Void
    var onDone: () -> Void
    @State private var isFocused = true
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("编辑内容")).font(.headline).foregroundStyle(Color.connInk)
                Spacer()
                Button(action: onDone) {
                    Text(L("完成"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.connAccent)
                        .padding(.horizontal, ConnSpacing.md)
                        .padding(.vertical, ConnSpacing.xs)
                        .background(Color.connKey, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.composer.done")
            }
            .padding(ConnSpacing.md)
            Rectangle().fill(Color.connLine).frame(height: 0.5)
            TerminalComposerTextEditor(
                text: $text, isFocused: $isFocused,
                isReadOnly: speechState.isCapturing || isSubmitting, fontSize: fontSize
            )
            .padding(ConnSpacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: ConnSpacing.md) {
                Text(L("仅填入终端，不自动执行"))
                    .font(.footnote).foregroundStyle(Color.connMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TerminalComposerVoiceButton(
                    state: speechState, isSubmitting: isSubmitting, action: onToggleSpeech
                )
                TerminalComposerSendButton(canSend: canSend) {
                    guard canSend else { return }
                    onSubmit(text)
                }
            }
            .padding(.horizontal, ConnSpacing.md)
            .padding(.vertical, ConnSpacing.xs)
            .background(Color.connBar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.connBg.ignoresSafeArea(.container))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.composer.expanded")
    }

    private var canSend: Bool {
        !isSubmitting && !speechState.isCapturing
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
#endif
