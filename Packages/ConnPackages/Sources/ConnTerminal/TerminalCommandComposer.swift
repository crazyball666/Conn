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
    @FocusState private var isFocused: Bool
    private let speechState: TerminalSpeechComposerState
    private let onSubmit: (String) -> Void
    private let onToggleSpeech: () -> Void
    private let dismissKeyboardRequest: UInt
    private let focusKeyboardRequest: UInt
    private let onFocusChange: (Bool) -> Void

    public init(
        text: Binding<String>,
        isSubmitting: Binding<Bool>,
        speechState: TerminalSpeechComposerState = .unavailable,
        onSubmit: @escaping (String) -> Void,
        onToggleSpeech: @escaping () -> Void = {},
        dismissKeyboardRequest: UInt = 0,
        focusKeyboardRequest: UInt = 0,
        onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) {
        _text = text
        _isSubmitting = isSubmitting
        self.speechState = speechState
        self.onSubmit = onSubmit
        self.onToggleSpeech = onToggleSpeech
        self.dismissKeyboardRequest = dismissKeyboardRequest
        self.focusKeyboardRequest = focusKeyboardRequest
        self.onFocusChange = onFocusChange
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: ConnSpacing.xs) {
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: ConnSpacing.xxs) {
                    if speechState.isCapturing {
                        Label(
                            speechState == .stopping ? L("正在结束语音输入…") : L("正在聆听…"),
                            systemImage: "waveform"
                        )
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color.connAccent)
                        .accessibilityIdentifier("terminal.composer.speech-status")
                    }

                    TextField(
                        "",
                        text: $text,
                        prompt: Text(L("待发送内容")).foregroundColor(.connMuted),
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(.connInk)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    // Submission is synchronous. Disabling the native field during it
                    // makes UIKit resign first responder, breaking continuous editing.
                    .disabled(speechState.isCapturing)
                    .accessibilityLabel(L("待发送内容"))
                    .accessibilityIdentifier("terminal.composer.input")
                }
                .padding(.leading, ConnSpacing.md)
                .padding(.vertical, ConnSpacing.xs)
                .frame(minHeight: ConnSize.minTouchTarget)

                sendButton
            }
            .background(Color.connKey, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        speechState.isCapturing ? Color.connAccent.opacity(0.5) : .clear,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal.composer.field")
            speechButton
        }
        .padding(.horizontal, ConnSpacing.sm)
        .padding(.top, ConnSpacing.xs)
        .padding(.bottom, ConnSpacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.composer")
        .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
        .onChange(of: dismissKeyboardRequest) { _, _ in isFocused = false }
        .onChange(of: focusKeyboardRequest) { _, _ in
            if !speechState.isCapturing { isFocused = true }
        }
        .onChange(of: speechState) { _, state in
            if state.isCapturing { isFocused = false }
        }
        .onDisappear { onFocusChange(false) }
    }

    private var canSend: Bool {
        !isSubmitting && !speechState.isCapturing
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButton: some View {
        Button {
            guard canSend else { return }
            let restoreFocus = isFocused
            onSubmit(text)
            // Keep continuous editing after the multiline draft is cleared.
            // Restore focus after the update, not before clearing the field.
            if restoreFocus {
                DispatchQueue.main.async { isFocused = true }
            }
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(canSend ? Color.connInk : Color.connMuted)
                .frame(width: 32, height: 32)
                .background(canSend ? Color.connAccentFill : Color.connTrack, in: Circle())
                .frame(width: ConnSize.minTouchTarget, height: ConnSize.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(L("发送"))
        .accessibilityIdentifier("terminal.composer.send")
    }

    private var speechButton: some View {
        Button {
            isFocused = false
            onToggleSpeech()
        } label: {
            ZStack {
                Circle().fill(speechState.isCapturing ? Color.connAccentFill : Color.connKey)
                if speechState == .stopping {
                    ProgressView().tint(.connAccent)
                } else {
                    Image(systemName: speechState == .listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: ConnSize.minTouchTarget, height: ConnSize.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            speechState == .unavailable
                ? Color.connDim
                : speechState.isCapturing ? Color.connAccent : Color.connInk
        )
        .disabled(
            isSubmitting
                || speechState == .unavailable
                || speechState == .stopping
        )
        .accessibilityLabel(
            L(
                speechState.isCapturing
                    ? "停止语音输入"
                    : "语音输入"
            )
        )
        .accessibilityValue(speechState == .unavailable ? L("当前设备不支持离线语音输入") : "")
        .accessibilityIdentifier("terminal.composer.voice")
    }
}

/// 输入区与快捷键共用一张贴底表面；背景延续到 Home Indicator，但不覆盖键盘。
struct TerminalInputBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(
                Color.connBar.ignoresSafeArea(.container, edges: .bottom)
                    .accessibilityHidden(true)
            )
            .overlay(alignment: .top) {
                Rectangle().fill(Color.connLine).frame(height: 0.5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal.input-bar")
    }
}
#endif
