#if canImport(UIKit)
import ConnUI
import SwiftUI

/// In-place presentation: the terminal stays mounted and connected underneath.
struct TerminalComposerExpandedEditor: View {
    @Binding var text: String
    var isSubmitting: Bool
    var speechState: TerminalSpeechComposerState
    var backgroundColor: Color = Color.connBg
    var borderColor: Color = Color.connKeyline
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
                        .background(backgroundColor, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(borderColor, lineWidth: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.composer.done")
            }
            .padding(ConnSpacing.md)
            Rectangle().fill(borderColor).frame(height: 0.5)
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
                    state: speechState,
                    backgroundColor: backgroundColor,
                    borderColor: borderColor,
                    isSubmitting: isSubmitting,
                    action: onToggleSpeech
                )
                TerminalComposerSendButton(
                    canSend: canSend,
                    backgroundColor: backgroundColor,
                    borderColor: borderColor,
                    isExpanded: true
                ) {
                    guard canSend else { return }
                    onSubmit(text)
                }
            }
            .padding(.horizontal, ConnSpacing.md)
            .padding(.vertical, ConnSpacing.xs)
            .background(backgroundColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor.ignoresSafeArea(.container))
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
