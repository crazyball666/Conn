import AVFAudio
import ConnTerminal
import Foundation
import Speech

/// 一次会话的回调所有权与转写状态；不依赖权限或音频资源是否已建立。
@MainActor
final class AppleSpeechInputCallbacks {
    private(set) var sessionID: UUID?
    private var lastTranscript = ""
    private var onEvent: (@MainActor @Sendable (TerminalSpeechInputEvent) -> Void)?
    private var onError: (@MainActor @Sendable (TerminalSpeechInputError) -> Void)?

    func begin(
        onEvent: @escaping @MainActor @Sendable (TerminalSpeechInputEvent) -> Void,
        onError: @escaping @MainActor @Sendable (TerminalSpeechInputError) -> Void
    ) -> UUID {
        let sessionID = UUID()
        self.sessionID = sessionID
        self.onEvent = onEvent
        self.onError = onError
        lastTranscript = ""
        return sessionID
    }

    func isCurrent(_ sessionID: UUID) -> Bool {
        self.sessionID == sessionID
    }

    func receivePartial(_ transcript: String, for sessionID: UUID) {
        guard isCurrent(sessionID) else { return }
        lastTranscript = transcript
        onEvent?(.partial(transcript))
    }

    /// 先使旧回调失效，调用方释放资源后再交付完成，允许完成回调重入 start。
    func takeCompletion(
        for sessionID: UUID,
        transcript: String? = nil,
        error: TerminalSpeechInputError? = nil
    ) -> (@MainActor @Sendable () -> Void)? {
        guard isCurrent(sessionID) else { return nil }
        let eventHandler = onEvent
        let errorHandler = onError
        let finalTranscript = transcript ?? lastTranscript
        self.sessionID = nil
        lastTranscript = ""
        onEvent = nil
        onError = nil
        return {
            if let error {
                errorHandler?(error)
            } else {
                eventHandler?(.final(finalTranscript))
            }
        }
    }
}

/// Conn 的系统语音输入适配器。
///
/// 这里使用 iOS 17+ 的 SFSpeechRecognizer，并强制要求识别器支持本地识别。
/// 因此当前实现不会把录音发送到 Apple 服务器；不支持本地模型的设备或语言会
/// 明确返回不可用，后续可以在同一协议下接入 WhisperKit 等本地引擎。
@MainActor
final class AppleSpeechInputService: TerminalSpeechInputService {
    static let shared = AppleSpeechInputService()

    private var setupTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?
    private var audioRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let callbacks = AppleSpeechInputCallbacks()

    private init() {}

    func availability(for locale: Locale) -> TerminalSpeechInputAvailability {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            return .unavailable
        }
        return .available
    }

    func start(
        locale: Locale,
        onEvent: @escaping @MainActor @Sendable (TerminalSpeechInputEvent) -> Void,
        onError: @escaping @MainActor @Sendable (TerminalSpeechInputError) -> Void
    ) {
        stop()
        let sessionID = callbacks.begin(onEvent: onEvent, onError: onError)

        setupTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.callbacks.isCurrent(sessionID) else { return }
            do {
                try await self.prepareAndStart(locale: locale, sessionID: sessionID)
            } catch let error as TerminalSpeechInputError {
                guard !Task.isCancelled else { return }
                self.finish(sessionID: sessionID, error: error)
            } catch {
                guard !Task.isCancelled else { return }
                self.finish(sessionID: sessionID, error: .recognitionFailed)
            }
        }
    }

    func stop() {
        guard let sessionID = callbacks.sessionID else { return }
        // 权限准备期间也必须交付完成，让编辑器退出 stopping。
        finish(sessionID: sessionID)
    }

    private func prepareAndStart(locale: Locale, sessionID: UUID) async throws {
        let speechStatus = await requestSpeechAuthorization()
        guard !Task.isCancelled, callbacks.isCurrent(sessionID) else {
            throw TerminalSpeechInputError.cancelled
        }
        guard speechStatus == .authorized else {
            throw TerminalSpeechInputError.permissionDenied
        }

        let microphoneGranted = await requestMicrophonePermission()
        guard !Task.isCancelled, callbacks.isCurrent(sessionID) else {
            throw TerminalSpeechInputError.cancelled
        }
        guard microphoneGranted else {
            throw TerminalSpeechInputError.permissionDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            throw TerminalSpeechInputError.unavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw TerminalSpeechInputError.microphoneUnavailable
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .record,
                mode: .measurement,
                options: [.duckOthers, .allowBluetoothHFP]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw TerminalSpeechInputError.microphoneUnavailable
        }

        audioRequest = request
        audioEngine = engine
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.callbacks.isCurrent(sessionID) else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finish(sessionID: sessionID, transcript: transcript)
                        return
                    } else {
                        self.callbacks.receivePartial(transcript, for: sessionID)
                    }
                }
                if error != nil {
                    self.finish(sessionID: sessionID, error: .recognitionFailed)
                }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()

        do {
            try engine.start()
        } catch {
            throw TerminalSpeechInputError.microphoneUnavailable
        }
    }

    private func finish(
        sessionID: UUID,
        transcript: String? = nil,
        error: TerminalSpeechInputError? = nil
    ) {
        guard let completion = callbacks.takeCompletion(
            for: sessionID,
            transcript: transcript,
            error: error
        ) else { return }
        cleanup()
        completion()
    }

    private func cleanup() {
        setupTask?.cancel()
        setupTask = nil
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        audioRequest = nil
        audioEngine = nil
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
