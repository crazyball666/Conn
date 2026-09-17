import Testing
import ConnMultiplexer
@testable import ConnTerminal

@Suite("TerminalCommandComposer")
struct TerminalCommandComposerTests {
    @Test("空白草稿不可提交")
    func whitespaceOnlyDraftCannotSubmit() {
        var state = TerminalCommandComposerState()
        state.updateText("  \n\t")

        #expect(state.text == "  \n\t")
        #expect(state.canSubmit == false)
        #expect(state.beginSubmission() == nil)
        #expect(state.isSubmitting == false)
    }

    @Test("保留原始空格与换行，成功后清空")
    func preservesRawTextAndClearsAfterAcceptedSubmission() {
        var state = TerminalCommandComposerState()
        let draft = "  echo one  \n\necho two  "
        state.updateText(draft)

        #expect(state.beginSubmission() == draft)
        #expect(state.isSubmitting)
        #expect(state.beginSubmission() == nil)

        state.finishSubmission(accepted: true)

        #expect(state.text.isEmpty)
        #expect(state.isSubmitting == false)
    }

    @Test("提交失败时保留草稿并允许重试")
    func failedSubmissionKeepsDraft() {
        var state = TerminalCommandComposerState()
        state.updateText("echo retry")

        #expect(state.beginSubmission() == "echo retry")
        state.finishSubmission(accepted: false)

        #expect(state.text == "echo retry")
        #expect(state.canSubmit)
        #expect(state.beginSubmission() == "echo retry")
    }

    @Test("重置会取消进行中的提交并清空草稿")
    func resetClearsDraftAndSubmissionState() {
        var state = TerminalCommandComposerState()
        state.updateText("echo reset")
        _ = state.beginSubmission()

        state.reset()

        #expect(state == TerminalCommandComposerState())
    }

    @Test("目标身份变化时不会误认为仍是同一终端")
    func targetIdentityIncludesTabGenerationAndPersistentTarget() {
        let plain = TerminalComposerTarget(tabID: "tab-1", generation: 1)
        let nextGeneration = TerminalComposerTarget(tabID: "tab-1", generation: 2)
        let otherTab = TerminalComposerTarget(tabID: "tab-2", generation: 1)
        let persistent = TerminalComposerTarget(
            tabID: "tab-1",
            generation: 1,
            persistentTarget: PersistentTerminalInteractionTarget(
                providerID: "tmux",
                workspaceID: "workspace-1",
                targetID: "pane-1"
            )
        )

        #expect(plain != nextGeneration)
        #expect(plain != otherTab)
        #expect(plain != persistent)
    }

    @Test("没有 bracketed paste 时拒绝可能触发执行的多行内容")
    func rejectsUnsafeMultilinePaste() {
        #expect(TerminalCommandComposerSubmissionPolicy.allows("echo one", bracketedPasteEnabled: false))
        #expect(TerminalCommandComposerSubmissionPolicy.allows("echo one\necho two", bracketedPasteEnabled: true))
        #expect(TerminalCommandComposerSubmissionPolicy.allows("echo one\necho two", bracketedPasteEnabled: false) == false)
    }

    @Test("执行意图或明确确认后，多行内容不再被粘贴保护永久阻断")
    func permitsMultilineExecutionAndConfirmedInsertion() {
        for draft in ["one\ntwo", "one\r\ntwo", "one\rtwo"] {
            for bracketed in [false, true] {
                #expect(TerminalCommandComposerSubmissionPolicy.allows(
                    draft, bracketedPasteEnabled: bracketed, intent: .execute
                ))
                #expect(TerminalCommandComposerSubmissionPolicy.allows(
                    draft, bracketedPasteEnabled: bracketed, confirmsUnsafeMultiline: true
                ))
            }
        }
    }

    @Test("待确认期间锁定原文，取消后保留原文并可重试")
    func pendingConfirmationKeepsOriginalDraft() {
        var state = TerminalCommandComposerState()
        state.updateText("one\ntwo")
        #expect(state.beginSubmission() == "one\ntwo")
        state.updateText("other text")
        #expect(state.beginSubmission() == nil)
        #expect(state.text == "one\ntwo")
        state.finishSubmission(accepted: false)
        #expect(state.canSubmit)
        #expect(state.text == "one\ntwo")
    }

    @Test("语音临时结果替换而不是重复追加")
    func speechDraftReplacesPartialTranscript() {
        var draft = TerminalSpeechDraft(baseText: "echo")

        #expect(draft.update(transcript: "hello") == "echo hello")
        #expect(draft.update(transcript: "hello world") == "echo hello world")
        #expect(draft.renderedText == "echo hello world")
    }

    @Test("语音草稿保留已有行尾空白")
    func speechDraftDoesNotAddUnexpectedSeparator() {
        var draft = TerminalSpeechDraft(baseText: "printf ")

        #expect(draft.update(transcript: "hello") == "printf hello")
    }

    @Test("语音服务状态能表达停止中的收尾阶段")
    func speechComposerStateDistinguishesStopping() {
        #expect(TerminalSpeechComposerState.listening != .stopping)
        #expect(TerminalSpeechComposerState.idle != .unavailable)
    }

    @Test("语音不可用时仍可手动发送，仅活动语音会话锁定草稿")
    func unavailableSpeechDoesNotDisableManualInput() {
        #expect(!TerminalSpeechComposerState.unavailable.isCapturing)
        #expect(!TerminalSpeechComposerState.idle.isCapturing)
        #expect(TerminalSpeechComposerState.listening.isCapturing)
        #expect(TerminalSpeechComposerState.stopping.isCapturing)
    }
}
