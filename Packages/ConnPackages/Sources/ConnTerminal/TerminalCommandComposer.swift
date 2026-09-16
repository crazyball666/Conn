import ConnMultiplexer
import Foundation

/// 终端命令编辑器的短生命周期状态。
///
/// 草稿只属于当前终端页面，不写入数据库。提交成功才清空，目标失效或入队失败时
/// 保留原文，方便用户重新选择会话后重试。
public struct TerminalCommandComposerState: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var isSubmitting = false

    public init() {}

    public var canSubmit: Bool {
        !isSubmitting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func updateText(_ text: String) {
        guard !isSubmitting else { return }
        self.text = text
    }

    /// 锁定当前草稿，返回需要插入终端的原文；重复点击返回 nil。
    public mutating func beginSubmission() -> String? {
        guard canSubmit else { return nil }
        isSubmitting = true
        return text
    }

    public mutating func finishSubmission(accepted: Bool) {
        if accepted {
            text = ""
        }
        isSubmitting = false
    }

    public mutating func reset() {
        text = ""
        isSubmitting = false
    }
}

/// 多行内容只有在目标终端声明 bracketed paste 时才允许注入。
///
/// 普通 shell 会把裸换行当作回车；没有 bracketed paste 保护时无法同时保证
/// 保留换行和不触发执行，因此这里选择保留草稿并让用户重试，而不是冒险发送。
public enum TerminalCommandComposerSubmissionPolicy {
    public static func allows(_ text: String, bracketedPasteEnabled: Bool) -> Bool {
        !text.contains(where: \.isNewline) || bracketedPasteEnabled
    }
}

/// 提交时捕获的终端身份。提交动作只接受仍属于当前会话的 target。
public struct TerminalComposerTarget: Equatable, Sendable {
    public let tabID: String
    public let generation: UInt64
    public let persistentTarget: PersistentTerminalInteractionTarget?

    public init(
        tabID: String,
        generation: UInt64,
        persistentTarget: PersistentTerminalInteractionTarget? = nil
    ) {
        self.tabID = tabID
        self.generation = generation
        self.persistentTarget = persistentTarget
    }
}

#if canImport(UIKit)
import SwiftUI
import ConnUI

/// 终端底部的待发送内容编辑器。
///
/// Return 仅插入换行。发送按钮把整个草稿作为一次 paste 插入当前终端，不追加
/// 回车，因此不会触发远端命令执行。
public struct TerminalCommandComposer: View {
    @Binding private var text: String
    @Binding private var isSubmitting: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var speechPulse = false
    private let speechState: TerminalSpeechComposerState
    private let onSubmit: (String) -> Void
    private let onToggleSpeech: () -> Void

    public init(
        text: Binding<String>,
        isSubmitting: Binding<Bool>,
        speechState: TerminalSpeechComposerState = .unavailable,
        onSubmit: @escaping (String) -> Void,
        onToggleSpeech: @escaping () -> Void = {}
    ) {
        _text = text
        _isSubmitting = isSubmitting
        self.speechState = speechState
        self.onSubmit = onSubmit
        self.onToggleSpeech = onToggleSpeech
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: ConnSpacing.xs) {
            TextField(
                "",
                text: $text,
                prompt: Text(L("待发送内容")),
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .font(.connBody)
            .foregroundStyle(.connInk)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(speechState == .listening || speechState == .stopping)
            .accessibilityLabel(L("待发送内容"))
            .accessibilityIdentifier("terminal.composer.input")

            speechButton

            Button {
                guard !isSubmitting,
                      speechState == .idle,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return }
                onSubmit(text)
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: ConnSize.minTouchTarget, height: ConnSize.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                speechState != .idle
                    || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Color.connDim
                    : Color.connAccent
            )
            .disabled(
                isSubmitting
                    || speechState != .idle
                    || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityLabel(L("发送"))
            .accessibilityIdentifier("terminal.composer.send")
        }
        .padding(.leading, ConnSpacing.sm)
        .padding(.trailing, ConnSpacing.xxs)
        .frame(minHeight: ConnSize.minTouchTarget)
        .background(Color.connSurface, in: .rect(cornerRadius: ConnRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 1)
        }
        .padding(.horizontal, ConnSpacing.sm)
        .padding(.vertical, ConnSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.composer")
    }

    private var speechButton: some View {
        Button(action: onToggleSpeech) {
            ZStack {
                if speechState == .listening {
                    Circle()
                        .fill(Color.connWarnFill)

                    if !accessibilityReduceMotion {
                        Circle()
                            .stroke(Color.connWarn.opacity(0.72), lineWidth: 1.5)
                            .scaleEffect(speechPulse ? 1.42 : 0.9)
                            .opacity(speechPulse ? 0 : 0.7)
                            .animation(
                                .easeOut(duration: 1.1).repeatForever(autoreverses: false),
                                value: speechPulse
                            )
                            .allowsHitTesting(false)
                    }
                }

                Image(
                    systemName: speechState == .listening || speechState == .stopping
                        ? "stop.fill"
                        : "mic.fill"
                )
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(width: ConnSize.minTouchTarget, height: ConnSize.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            speechState == .unavailable
                ? Color.connDim
                : speechState == .listening || speechState == .stopping
                    ? Color.connWarn
                    : Color.connAccent
        )
        .disabled(
            isSubmitting
                || speechState == .unavailable
                || speechState == .stopping
        )
        .accessibilityLabel(
            L(
                speechState == .listening || speechState == .stopping
                    ? "停止语音输入"
                    : "语音输入"
            )
        )
        .accessibilityIdentifier("terminal.composer.voice")
        .onAppear {
            updateSpeechPulse(for: speechState)
        }
        .onChange(of: speechState) { _, newState in
            updateSpeechPulse(for: newState)
        }
    }

    private func updateSpeechPulse(for state: TerminalSpeechComposerState) {
        withAnimation(.easeOut(duration: 0.18)) {
            speechPulse = state == .listening && !accessibilityReduceMotion
        }
    }
}
#endif
