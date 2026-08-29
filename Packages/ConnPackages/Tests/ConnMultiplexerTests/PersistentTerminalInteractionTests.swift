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

    @Test("catalog state stream retains only the newest unconsumed snapshot")
    func boundedCatalogStateStream() async throws {
        let pair = PersistentTerminalCatalogStreams.makeStateStream(of: Int.self)
        pair.continuation.yield(1)
        pair.continuation.yield(2)
        pair.continuation.yield(3)

        var iterator = pair.stream.makeAsyncIterator()
        #expect(try #require(await iterator.next()) == 3)
        pair.continuation.finish()
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

        let action = PersistentTerminalQuickActionRequest(
            actionID: "provider.action",
            target: target,
            attachmentGeneration: 7,
            expectedStateRevision: 9,
            argument: "value",
            repeatCount: 4
        )
        #expect(action.target == target)
        #expect(action.actionID == "provider.action")
        #expect(action.attachmentGeneration == 7)
        #expect(action.expectedStateRevision == 9)
        #expect(action.argument == "value")
        #expect(action.repeatCount == 4)
    }

    @Test("quick actions are independently optional")
    func optionalQuickActions() async {
        let facet = FakeFacet()
        #expect(await facet.quickActionGroup == nil)
        await #expect(throws: PersistentTerminalInteractionError.unsupportedQuickAction("x")) {
            try await facet.performQuickAction(PersistentTerminalQuickActionRequest(
                actionID: "x",
                target: target,
                attachmentGeneration: 7,
                expectedStateRevision: 9
            ))
        }
    }

    @Test("provider swipe bindings reuse typed quick action IDs without exposing commands")
    func providerSwipeBindings() {
        let group = PersistentTerminalQuickActionGroup(
            id: "provider",
            title: "Provider",
            sections: [
                .init(id: "navigation", titleKey: "Navigation", actions: [
                    .init(id: "provider.next", titleKey: "Next", systemImageName: "arrow.right"),
                ]),
            ],
            swipeActions: [
                .init(
                    direction: .left,
                    actionID: "provider.next",
                    successNoticeKey: "Switched",
                    unavailableNoticeKey: "Nothing to switch"
                ),
            ]
        )

        #expect(group.swipeAction(for: .left)?.actionID == "provider.next")
        #expect(group.swipeAction(for: .right) == nil)
        #expect(group.swipeAction(for: .left)?.successNoticeKey == "Switched")
        #expect(group.swipeAction(for: .left)?.unavailableNoticeKey == "Nothing to switch")
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
            maxLines: maxLines,
            maxBytes: maxBytes
        )
    }

    private func scrollRequest(rows: Int) throws -> PersistentTerminalModeScrollRequest {
        try PersistentTerminalModeScrollRequest(
            target: target,
            attachmentGeneration: 7,
            direction: .up,
            rows: rows
        )
    }
}

private class BaseAttachment: PersistentTerminalAttachment, @unchecked Sendable {
    let descriptor = PersistentAttachmentDescriptor(
        providerID: "fake",
        configuration: PersistentTerminalConfiguration(
            providerID: "fake",
            configurationKey: "default",
            payloadVersion: 1,
            providerPayload: Data()
        ),
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
