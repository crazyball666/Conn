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

/// 纸飞机只填入；收起状态的键盘发送键额外向终端发送回车。
public enum TerminalComposerSubmissionIntent: Equatable, Sendable {
    case insert
    case execute
}

public enum TerminalCommandComposerSubmissionPolicy {
    public static func allows(
        _ text: String,
        bracketedPasteEnabled: Bool,
        intent: TerminalComposerSubmissionIntent = .insert,
        confirmsUnsafeMultiline: Bool = false
    ) -> Bool {
        intent == .execute || confirmsUnsafeMultiline
            || !text.contains(where: \.isNewline) || bracketedPasteEnabled
    }
}

enum TerminalComposerSubmissionResult: Equatable {
    case accepted
    case requiresConfirmation
    case unavailable
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
/// 键盘 Return 提交并执行；纸飞机仅填入，展开编辑器的 Return 保留换行。
public struct TerminalCommandComposer: View {
    @Binding private var text: String
    @Binding private var isSubmitting: Bool
    @State private var isFocused = false
    @ScaledMetric(relativeTo: .callout) private var visualHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var sendDiameter: CGFloat = 26
    private let speechState: TerminalSpeechComposerState
    private let onSubmit: (String) -> Void
    private let onExecute: (String) -> Void
    private let onToggleSpeech: () -> Void
    private let onExpand: () -> Void
    private let dismissKeyboardRequest: UInt
    private let focusKeyboardRequest: UInt
    private let onFocusChange: (Bool) -> Void

    public init(
        text: Binding<String>,
        isSubmitting: Binding<Bool>,
        speechState: TerminalSpeechComposerState = .unavailable,
        onSubmit: @escaping (String) -> Void,
        onExecute: @escaping (String) -> Void = { _ in },
        onToggleSpeech: @escaping () -> Void = {},
        onExpand: @escaping () -> Void = {},
        dismissKeyboardRequest: UInt = 0,
        focusKeyboardRequest: UInt = 0,
        onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) {
        _text = text
        _isSubmitting = isSubmitting
        self.speechState = speechState
        self.onSubmit = onSubmit
        self.onExecute = onExecute
        self.onToggleSpeech = onToggleSpeech
        self.onExpand = onExpand
        self.dismissKeyboardRequest = dismissKeyboardRequest
        self.focusKeyboardRequest = focusKeyboardRequest
        self.onFocusChange = onFocusChange
    }

    public var body: some View {
        HStack(spacing: ConnSpacing.xs) {
            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: iconSize))
                            .foregroundStyle(speechState.isCapturing ? Color.connAccent : Color.connMuted)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TerminalComposerTextEditor(
                        text: $text, isFocused: $isFocused,
                        isReadOnly: speechState.isCapturing || isSubmitting,
                        fontSize: iconSize, compact: true,
                        onSubmit: {
                            guard canSend else { return }
                            onExecute(text)
                        }
                    )
                    .frame(height: UIFont.systemFont(ofSize: iconSize).lineHeight)
                }
                .frame(height: visualHeight)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { isFocused = true })
                .padding(.leading, ConnSpacing.md)
                HStack(spacing: ConnSpacing.xs) {
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: iconSize - 2, weight: .semibold))
                            .foregroundStyle(Color.connInk)
                            .frame(width: sendDiameter, height: sendDiameter)
                            .background(Color.connTrack, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("全屏编辑"))
                    .accessibilityIdentifier("terminal.composer.expand")
                    sendButton
                }
                .padding(.leading, ConnSpacing.xs)
                .padding(.trailing, (visualHeight - sendDiameter) / 2)
            }
            .frame(height: visualHeight)
            .background {
                Capsule()
                    .fill(Color.connKey)
                    .overlay {
                        Capsule().strokeBorder(
                            speechState.isCapturing ? Color.connAccent.opacity(0.5) : .clear,
                            lineWidth: 1
                        )
                    }
                    .frame(height: visualHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal.composer.field")
            TerminalComposerVoiceButton(state: speechState, isSubmitting: isSubmitting, action: onToggleSpeech)
        }
        .padding(.horizontal, ConnSpacing.sm)
        .padding(.top, ConnSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.composer")
        .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
        .onChange(of: dismissKeyboardRequest) { _, _ in isFocused = false }
        .onChange(of: focusKeyboardRequest) { _, _ in isFocused = true }
        .onDisappear { onFocusChange(false) }
    }

    private var placeholder: String {
        switch speechState {
        case .listening: L("正在聆听…")
        case .stopping: L("正在结束语音输入…")
        default: L("待发送内容")
        }
    }

    private var canSend: Bool {
        !isSubmitting && !speechState.isCapturing
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButton: some View {
        TerminalComposerSendButton(canSend: canSend) {
            guard canSend else { return }
            let restoreFocus = isFocused
            onSubmit(text)
            // Keep continuous editing after the multiline draft is cleared.
            // Restore focus after the update, not before clearing the field.
            if restoreFocus {
                DispatchQueue.main.async { isFocused = true }
            }
        }
    }
}

struct TerminalComposerSendButton: View {
    var canSend: Bool
    var action: () -> Void
    @ScaledMetric private var diameter: CGFloat
    @ScaledMetric private var iconSize: CGFloat

    init(canSend: Bool, isExpanded: Bool = false, action: @escaping () -> Void) {
        self.canSend = canSend
        self.action = action
        _diameter = ScaledMetric(wrappedValue: isExpanded ? 36 : 26, relativeTo: .callout)
        _iconSize = ScaledMetric(wrappedValue: isExpanded ? 16 : 14, relativeTo: .callout)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(canSend ? Color.connInk : Color.connMuted)
                .frame(width: diameter, height: diameter)
                .background(canSend ? Color.connAccentFill : Color.connTrack, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(L("发送"))
        .accessibilityIdentifier("terminal.composer.send")
    }

}

struct TerminalComposerVoiceButton: View {
    var state: TerminalSpeechComposerState
    var isSubmitting: Bool
    var action: () -> Void
    @ScaledMetric(relativeTo: .callout) private var diameter: CGFloat = 36
    @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 16

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(state.isCapturing ? Color.connAccentFill : Color.connKey)
                if state == .stopping {
                    ProgressView().tint(.connAccent)
                } else {
                    Image(systemName: state == .listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            state == .unavailable
                ? Color.connDim
                : state.isCapturing ? Color.connAccent : Color.connInk
        )
        .disabled(
            isSubmitting
                || state == .unavailable
                || state == .stopping
        )
        .accessibilityLabel(
            L(
                state.isCapturing
                    ? "停止语音输入"
                    : "语音输入"
            )
        )
        .accessibilityValue(
            state == .unavailable ? L("当前设备不支持离线语音输入")
                : state == .listening ? L("正在聆听…")
                : state == .stopping ? L("正在结束语音输入…") : ""
        )
        .accessibilityIdentifier("terminal.composer.voice")
    }
}

/// 输入区与快捷键共用一张贴底表面；背景延续到 Home Indicator，但不覆盖键盘。
struct TerminalInputBar<Content: View>: View {
    var backgroundColor: Color = Color.connBar
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touchLocation: CGPoint?
    @State private var touchGlowScale: CGFloat = 0.22
    @State private var touchGlowOpacity: CGFloat = 0
    @State private var isTouchTracking = false

    var body: some View {
        VStack(spacing: 0, content: content)
            .background {
                TerminalInputBarBackground(
                    backgroundColor: backgroundColor,
                    touchLocation: touchLocation, scale: touchGlowScale, opacity: touchGlowOpacity
                )
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color.connLine).frame(height: 0.5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal.input-bar")
            // Track in the shared surface's coordinates. Individual fields and
            // buttons retain their native taps, scrolling and selection gestures.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if isTouchTracking {
                            touchLocation = value.location
                            return
                        }
                        isTouchTracking = true
                        withTransaction(Transaction(animation: nil)) {
                            touchLocation = value.location
                            touchGlowScale = 0.22
                            touchGlowOpacity = 0
                        }
                        if reduceMotion {
                            touchGlowScale = 1.08
                            touchGlowOpacity = 1
                        } else {
                            withAnimation(.easeOut(duration: 0.34)) {
                                touchGlowScale = 1.08
                                touchGlowOpacity = 1
                            }
                        }
                    }
                    .onEnded { _ in
                        isTouchTracking = false
                        if reduceMotion {
                            touchGlowOpacity = 0
                        } else {
                            withAnimation(.easeOut(duration: 0.28)) {
                                touchGlowScale = 1.18
                                touchGlowOpacity = 0
                            }
                        }
                    }
            )
    }
}

/// One continuous background for both rows; only the outer surface clips the glow.
struct TerminalInputBarBackground: View {
    var backgroundColor: Color = Color.connBar
    var touchLocation: CGPoint?
    var scale: CGFloat
    var opacity: CGFloat

    var body: some View {
        backgroundColor.ignoresSafeArea(.container, edges: .bottom)
            .overlay {
                GeometryReader { _ in
                    if let touchLocation {
                        RadialGradient(
                            colors: [Color.connInk.opacity(0.32), Color.connInk.opacity(0.14), .clear],
                            center: .center, startRadius: 0, endRadius: 168
                        )
                        .frame(width: 336, height: 336)
                        .scaleEffect(scale)
                        .opacity(opacity)
                        .position(touchLocation)
                    }
                }
                .clipped()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif
