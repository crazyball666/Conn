import Testing
@testable import ConnTerminal

@Suite("TerminalTranscript — 回放与实时输出")
struct TerminalTranscriptTests {
    @Test("回放完整结束后才接收实时输出")
    func attachmentOrdersReplayBeforeLiveOutput() async {
        let transcript = TerminalTranscript()
        await transcript.activateGeneration(1)
        await transcript.append(Array("old\n".utf8), generation: 1)

        let attachment = await transcript.attach()
        await transcript.append(Array("new\n".utf8), generation: 1)

        var iterator = attachment.events.makeAsyncIterator()
        let events = await [
            iterator.next(), iterator.next(), iterator.next(), iterator.next()
        ]
        #expect(events == [
            .replayStarted(requiresReset: false),
            .replayBytes(Array("old\n".utf8)),
            .replayFinished(.default),
            .liveBytes(Array("new\n".utf8)),
        ])
    }

    @Test("丢弃旧 generation 迟到的输出")
    func ignoresStaleGenerationOutput() async {
        let transcript = TerminalTranscript()
        await transcript.activateGeneration(1)
        await transcript.append(Array("old\n".utf8), generation: 1)
        await transcript.activateGeneration(2)
        await transcript.append(Array("stale\n".utf8), generation: 1)
        await transcript.append(Array("new\n".utf8), generation: 2)

        let attachment = await transcript.attach()
        var iterator = attachment.events.makeAsyncIterator()
        _ = await iterator.next()
        let replay = await iterator.next()

        #expect(replay == .replayBytes(Array("old\nnew\n".utf8)))
    }

    @Test("旧 attachment 不能解除新的订阅")
    func staleDetachDoesNotRemoveNewAttachment() async {
        let transcript = TerminalTranscript()
        await transcript.activateGeneration(1)
        let first = await transcript.attach()
        let second = await transcript.attach()
        await transcript.detach(first.id)
        await transcript.append(Array("still-here\n".utf8), generation: 1)

        var iterator = second.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        #expect(await iterator.next() == .liveBytes(Array("still-here\n".utf8)))
    }

    @Test("generation 边界先于新 generation 的实时输出")
    func boundaryPrecedesNewGenerationLiveOutput() async {
        let transcript = TerminalTranscript()
        await transcript.activateGeneration(1)
        let attachment = await transcript.attach()
        var iterator = attachment.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        await transcript.appendGenerationBoundary(1)
        await transcript.activateGeneration(2)
        await transcript.append(Array("next\n".utf8), generation: 2)

        #expect(await iterator.next() == .generationBoundary)
        #expect(await iterator.next() == .liveBytes(Array("next\n".utf8)))
    }

    @Test("渲染繁忙时相邻实时帧按顺序合并")
    func coalescesAdjacentLiveFrames() async {
        let transcript = TerminalTranscript(maxPendingLiveBytes: 1024)
        await transcript.activateGeneration(1)
        let attachment = await transcript.attach()
        var iterator = attachment.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        await transcript.append(Array("one".utf8), generation: 1)
        await transcript.append(Array("-two".utf8), generation: 1)
        await transcript.append(Array("-three".utf8), generation: 1)

        #expect(await iterator.next() == .liveBytes(Array("one-two-three".utf8)))
    }

    @Test("慢消费者积压超过上限时重置并回放最新有界快照")
    func slowConsumerResynchronizesFromBoundedReplay() async {
        let transcript = TerminalTranscript(
            maxLines: 100,
            maxBytes: 12,
            maxPendingLiveBytes: 3
        )
        await transcript.activateGeneration(1)
        let attachment = await transcript.attach()

        await transcript.append(Array("1234".utf8), generation: 1)
        await transcript.append(Array("5678".utf8), generation: 1)
        await transcript.append(Array("90ab".utf8), generation: 1)

        var iterator = attachment.events.makeAsyncIterator()
        #expect(await iterator.next() == .replayStarted(requiresReset: true))
        #expect(await iterator.next() == .replayBytes(Array("1234567890ab".utf8)))
        #expect(await iterator.next() == .replayFinished(TerminalViewportState.default))
    }
}
