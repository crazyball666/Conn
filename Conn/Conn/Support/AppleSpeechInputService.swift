import AVFAudio
import ConnTerminal
import Foundation
import Speech

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
    private var lastTranscript = ""
    private var onEvent: (@MainActor @Sendable (TerminalSpeechInputEvent) -> Void)?
    private var onError: (@MainActor @Sendable (TerminalSpeechInputError) -> Void)?

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
        self.onEvent = onEvent
        self.onError = onError
        lastTranscript = ""

        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.prepareAndStart(locale: locale)
            } catch let error as TerminalSpeechInputError {
                guard !Task.isCancelled else { return }
                self.finishWithError(error)
            } catch {
                guard !Task.isCancelled else { return }
                self.finishWithError(.recognitionFailed)
            }
        }
    }

    func stop() {
        setupTask?.cancel()
        setupTask = nil

        guard audioEngine != nil || audioRequest != nil || recognitionTask != nil else {
            onEvent = nil
            onError = nil
            return
        }

        // 先交付最近一次完整转写，再释放录音和识别资源。转写只会填入草稿，
        // 不会触发终端提交。
        onEvent?(.final(lastTranscript))
        cleanup()
    }

    private func prepareAndStart(locale: Locale) async throws {
        let speechStatus = await requestSpeechAuthorization()
        guard !Task.isCancelled else { throw TerminalSpeechInputError.cancelled }
        guard speechStatus == .authorized else {
            throw TerminalSpeechInputError.permissionDenied
        }

        let microphoneGranted = await requestMicrophonePermission()
        guard !Task.isCancelled else { throw TerminalSpeechInputError.cancelled }
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
                guard let self else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    self.lastTranscript = transcript
                    if result.isFinal {
                        if !transcript.isEmpty {
                            self.onEvent?(.final(transcript))
                        }
                        self.cleanup()
                    } else {
                        self.onEvent?(.partial(transcript))
                    }
                }
                if error != nil {
                    self.finishWithError(.recognitionFailed)
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
            cleanup()
            throw TerminalSpeechInputError.microphoneUnavailable
        }
    }

    private func finishWithError(_ error: TerminalSpeechInputError) {
        let handler = onError
        cleanup()
        handler?(error)
    }

    private func cleanup() {
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        recognitionTask?.cancel()
        recognitionTask = nil
        audioRequest = nil
        audioEngine = nil
        lastTranscript = ""
        onEvent = nil
        onError = nil
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
