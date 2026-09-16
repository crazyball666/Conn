import ConnTerminal
import Foundation
import Testing
@testable import Conn

/// 只测试服务的会话回调状态，不创建识别器、请求权限或访问音频设备。
@MainActor
@Suite("AppleSpeechInputService — 会话完成与过期回调")
struct AppleSpeechInputServiceTests {
    @MainActor
    private final class Recorder {
        var events: [TerminalSpeechInputEvent] = []
        var errors: [TerminalSpeechInputError] = []

        func begin(_ callbacks: AppleSpeechInputCallbacks) -> UUID {
            callbacks.begin(
                onEvent: { [self] in events.append($0) },
                onError: { [self] in errors.append($0) }
            )
        }
    }

    @Test("权限准备期间停止：没有音频资源或转写也完成，重复停止不重复通知")
    func setupCancellationCompletesEmptySessionOnce() throws {
        let callbacks = AppleSpeechInputCallbacks()
        let recorder = Recorder()
        let sessionID = recorder.begin(callbacks)

        let completion = try #require(callbacks.takeCompletion(for: sessionID))
        #expect(!callbacks.isCurrent(sessionID))
        #expect(callbacks.sessionID == nil)
        #expect(recorder.events.isEmpty)
        completion()

        #expect(recorder.events == [.final("")])
        #expect(recorder.errors.isEmpty)
        #expect(callbacks.takeCompletion(for: sessionID) == nil)
    }

    @Test("停止时交付最新完整转写，完成后忽略迟到的临时结果")
    func stopKeepsLatestTranscript() throws {
        let callbacks = AppleSpeechInputCallbacks()
        let recorder = Recorder()
        let sessionID = recorder.begin(callbacks)
        callbacks.receivePartial("hello", for: sessionID)
        callbacks.receivePartial("hello world", for: sessionID)

        let completion = try #require(callbacks.takeCompletion(for: sessionID))
        completion()
        callbacks.receivePartial("late result", for: sessionID)

        #expect(recorder.events == [.partial("hello"), .partial("hello world"), .final("hello world")])
        #expect(recorder.errors.isEmpty)
    }

    @Test("空的最终结果仍完成会话，不被旧的临时结果替代")
    func emptyFinalStillCompletes() throws {
        let callbacks = AppleSpeechInputCallbacks()
        let recorder = Recorder()
        let sessionID = recorder.begin(callbacks)
        callbacks.receivePartial("temporary", for: sessionID)

        let completion = try #require(callbacks.takeCompletion(for: sessionID, transcript: ""))
        completion()

        #expect(recorder.events == [.partial("temporary"), .final("")])
        #expect(callbacks.sessionID == nil)
        #expect(callbacks.takeCompletion(for: sessionID, error: .recognitionFailed) == nil)
    }

    @Test("清理回调所有权后仍能交付权限、录音启动和识别错误", arguments: [
        TerminalSpeechInputError.permissionDenied, .microphoneUnavailable, .recognitionFailed
    ])
    func errorsSurviveCallbackRelease(_ error: TerminalSpeechInputError) throws {
        let callbacks = AppleSpeechInputCallbacks()
        let recorder = Recorder()
        let sessionID = recorder.begin(callbacks)

        let completion = try #require(callbacks.takeCompletion(for: sessionID, error: error))
        #expect(callbacks.sessionID == nil)
        #expect(recorder.errors.isEmpty)
        completion()

        #expect(recorder.errors == [error])
        #expect(recorder.events.isEmpty)
        #expect(callbacks.takeCompletion(for: sessionID, error: error) == nil)
    }

    @Test("旧会话迟到的临时、最终和错误回调不能修改或结束新会话")
    func lateCallbacksCannotAffectReplacementSession() throws {
        let callbacks = AppleSpeechInputCallbacks()
        let oldRecorder = Recorder()
        let oldID = oldRecorder.begin(callbacks)
        let oldCompletion = try #require(callbacks.takeCompletion(for: oldID))
        oldCompletion()

        let recorder = Recorder()
        let sessionID = recorder.begin(callbacks)
        callbacks.receivePartial("stale", for: oldID)
        #expect(callbacks.takeCompletion(for: oldID, transcript: "stale final") == nil)
        #expect(callbacks.takeCompletion(for: oldID, error: .recognitionFailed) == nil)
        #expect(callbacks.isCurrent(sessionID))
        #expect(recorder.events.isEmpty)
        #expect(recorder.errors.isEmpty)

        callbacks.receivePartial("current", for: sessionID)
        let completion = try #require(callbacks.takeCompletion(for: sessionID))
        completion()

        #expect(recorder.events == [.partial("current"), .final("current")])
        #expect(oldRecorder.events == [.final("")])
    }

    @Test("完成回调中开始新会话后，旧会话不能再次清理它")
    func completionCanStartReplacementSession() throws {
        let callbacks = AppleSpeechInputCallbacks()
        let recorder = Recorder()
        let oldID = callbacks.begin(
            onEvent: { _ in _ = recorder.begin(callbacks) },
            onError: { _ in }
        )

        let completion = try #require(callbacks.takeCompletion(for: oldID))
        completion()
        let sessionID = try #require(callbacks.sessionID)

        #expect(sessionID != oldID)
        #expect(callbacks.takeCompletion(for: oldID) == nil)
        #expect(callbacks.isCurrent(sessionID))
        callbacks.receivePartial("new session", for: sessionID)
        #expect(recorder.events == [.partial("new session")])
    }
}
