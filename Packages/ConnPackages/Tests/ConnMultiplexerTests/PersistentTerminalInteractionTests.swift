import ConnSSH
import Foundation
import Testing
@testable import ConnMultiplexer

@Suite("Persistent terminal interaction facet")
struct PersistentTerminalInteractionTests {
    @Test("base attachments need not expose interaction")
    func optionalFacet() {
        let attachment: any PersistentTerminalAttachment = BaseAttachment()
        #expect((attachment as? any PersistentTerminalInteractiveAttachment) == nil)
    }

    @Test("interactive attachment exposes exactly its owned facet")
    func interactiveFacet() throws {
        let attachment: any PersistentTerminalAttachment = InteractiveAttachment()
        let interactive = try #require(attachment as? any PersistentTerminalInteractiveAttachment)
        #expect(interactive.interaction === (attachment as! InteractiveAttachment).facet)
    }

    @Test("state stream retains only the newest unconsumed value")
    func boundedStateStream() async throws {
        let facet = FakeFacet()
        facet.publish(state(revision: 1))
        facet.publish(state(revision: 2))
        facet.publish(state(revision: 3))

        var iterator = facet.states.makeAsyncIterator()
        let latest = try #require(await iterator.next())
        #expect(latest.revision == 3)
    }

    @Test("history request rejects non-positive and excessive limits")
    func historyValidation() {
        #expect(throws: PersistentTerminalInteractionError.invalidHistoryLineLimit(0)) {
            try historyRequest(maxLines: 0, maxBytes: 1)
        }
        #expect(throws: PersistentTerminalInteractionError.invalidHistoryByteLimit(0)) {
            try historyRequest(maxLines: 1, maxBytes: 0)
        }
        #expect(throws: PersistentTerminalInteractionError.invalidHistoryLineLimit(100_001)) {
            try historyRequest(maxLines: 100_001, maxBytes: 1)
        }
        #expect(throws: PersistentTerminalInteractionError.invalidHistoryByteLimit(4_194_305)) {
            try historyRequest(maxLines: 1, maxBytes: 4_194_305)
        }
    }

    @Test("mode scroll rejects zero and excessive row counts")
    func scrollValidation() {
        #expect(throws: PersistentTerminalInteractionError.invalidScrollRows(0)) {
            try scrollRequest(rows: 0)
        }
        #expect(throws: PersistentTerminalInteractionError.invalidScrollRows(65)) {
            try scrollRequest(rows: 65)
        }
    }

    @Test("state and requests retain explicit target and attachment generation")
    func explicitIdentity() throws {
        let request = try historyRequest(maxLines: 50, maxBytes: 4_096)
        #expect(request.target == target)
        #expect(request.attachmentGeneration == 7)
        #expect(request.expectedStateRevision == 9)
    }

    private var target: PersistentTerminalInteractionTarget {
        PersistentTerminalInteractionTarget(
            providerID: "fake",
            workspaceID: "workspace",
            targetID: "pane"
        )
    }

    private func state(revision: UInt64) -> PersistentTerminalInteractionState {
        PersistentTerminalInteractionState(
            target: target,
            attachmentGeneration: 7,
            revision: revision,
            freshness: .live,
            isAlternateBuffer: false,
            modeCapability: .none,
            historyAvailable: true,
            observedAt: Date(timeIntervalSince1970: TimeInterval(revision))
        )
    }

    private func historyRequest(maxLines: Int, maxBytes: Int) throws -> PersistentTerminalHistoryRequest {
        try PersistentTerminalHistoryRequest(
            target: target,
            attachmentGeneration: 7,
            expectedStateRevision: 9,
            maxLines: maxLines,
            maxBytes: maxBytes
        )
    }

    private func scrollRequest(rows: Int) throws -> PersistentTerminalModeScrollRequest {
        try PersistentTerminalModeScrollRequest(
            target: target,
            attachmentGeneration: 7,
            expectedStateRevision: 9,
            direction: .up,
            rows: rows
        )
    }
}

private class BaseAttachment: PersistentTerminalAttachment, @unchecked Sendable {
    let descriptor = PersistentAttachmentDescriptor(
        providerID: "fake",
        profileID: "profile",
        workspace: RemoteWorkspaceRef(
            workspaceID: "workspace",
            instancePayloadVersion: 1,
            providerInstancePayload: Data()
        ),
        payloadVersion: 1,
        providerPayload: Data()
    )
    let presentation: PersistentAttachmentPresentation = .byteTerminal(FakeInteractionShellChannel())
    func close() async {}
}

private final class InteractiveAttachment: BaseAttachment, PersistentTerminalInteractiveAttachment, @unchecked Sendable {
    let facet = FakeFacet()
    var interaction: any PersistentTerminalInteractionFacet { facet }
}

private final class FakeFacet: PersistentTerminalInteractionFacet, @unchecked Sendable {
    let states: AsyncStream<PersistentTerminalInteractionState>
    private let continuation: AsyncStream<PersistentTerminalInteractionState>.Continuation

    init() {
        (states, continuation) = PersistentTerminalInteractionStreams.makeStateStream()
    }

    func publish(_ state: PersistentTerminalInteractionState) {
        continuation.yield(state)
    }

    func resolveState() async throws -> PersistentTerminalInteractionState {
        throw PersistentTerminalInteractionError.unavailable
    }

    func captureHistory(
        _ request: PersistentTerminalHistoryRequest
    ) async throws -> PersistentTerminalHistorySnapshot {
        throw PersistentTerminalInteractionError.unavailable
    }

    func scrollProviderMode(_ request: PersistentTerminalModeScrollRequest) async throws {
        throw PersistentTerminalInteractionError.unavailable
    }
}

private final class FakeInteractionShellChannel: ShellChannel, @unchecked Sendable {
    let output = AsyncThrowingStream<Data, Error> { $0.finish() }
    func write(_ bytes: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func close() async {}
}
