import Foundation

/// 语音输入引擎的可用性。
///
/// 终端模块只关心能力是否可用，不依赖 Apple Speech、WhisperKit 或其它具体引擎。
public enum TerminalSpeechInputAvailability: Equatable, Sendable {
    case available
    case unavailable
}

/// 一次语音输入会话产生的转写事件。
///
/// `partial` 和 `final` 都是当前会话截至此刻的完整转写，而不是增量片段，
/// 这样系统 Speech、WhisperKit 和其它引擎可以用同一套草稿合并逻辑。
public enum TerminalSpeechInputEvent: Equatable, Sendable {
    case partial(String)
    case final(String)
}

/// 语音输入失败原因。错误不携带 UI 文案，展示层负责本地化。
public enum TerminalSpeechInputError: Error, Equatable, Sendable {
    case permissionDenied
    case unavailable
    case microphoneUnavailable
    case recognitionFailed
    case interrupted
    case cancelled
}

/// 编辑器中语音按钮的展示状态。识别失败通过 toast 展示，不把错误文案塞进领域状态。
public enum TerminalSpeechComposerState: Equatable, Sendable {
    case idle
    case listening
    case stopping
    case unavailable
}

/// 终端语音输入服务抽象。
///
/// 实现可以是系统 Speech、WhisperKit、whisper.cpp 或远端识别服务。服务只负责
/// 采集和转写，不负责修改终端、不执行命令，也不持久化录音或转写结果。
@MainActor
public protocol TerminalSpeechInputService: AnyObject {
    func availability(for locale: Locale) -> TerminalSpeechInputAvailability

    func start(
        locale: Locale,
        onEvent: @escaping @MainActor @Sendable (TerminalSpeechInputEvent) -> Void,
        onError: @escaping @MainActor @Sendable (TerminalSpeechInputError) -> Void
    )

    /// 停止采集并尽可能交付当前识别结果；不会触发终端提交。
    func stop()
}

/// 将一次语音会话的转写合并到现有终端草稿。
///
/// 语音识别结果通常会反复返回完整的临时转写，因此不能直接 append 每次结果，
/// 否则会得到重复文本。这个值对象保存会话开始时的草稿，并用最新转写替换预览。
public struct TerminalSpeechDraft: Equatable, Sendable {
    public private(set) var baseText: String
    public private(set) var transcript = ""

    public init(baseText: String = "") {
        self.baseText = baseText
    }

    public var renderedText: String {
        guard !transcript.isEmpty else { return baseText }
        guard !baseText.isEmpty else { return transcript }
        guard baseText.last?.isWhitespace == false else {
            return baseText + transcript
        }
        return baseText + " " + transcript
    }

    @discardableResult
    public mutating func update(transcript: String) -> String {
        self.transcript = transcript
        return renderedText
    }

    public mutating func reset() {
        baseText = ""
        transcript = ""
    }
}
