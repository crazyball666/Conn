import ConnKit
import ConnTerminal
import SwiftUI
import UIKit
import XCTest
@testable import Conn

@MainActor
final class TerminalConnectionOverlayTests: XCTestCase {
    func testShortConnectionFitsWithoutScrolling() async throws {
        let activity = makeActivity(steps: [
            TerminalConnectionStep(id: .network, state: .active),
            TerminalConnectionStep(id: .authentication),
            TerminalConnectionStep(id: .shell),
            TerminalConnectionStep(id: .ready),
        ])
        try await render(activity, typeSize: .large, colorScheme: .dark) { view in
            XCTAssertTrue(scrollViews(in: view).isEmpty)
            attach(view, named: "Terminal connection · direct · dark")
        }
    }

    func testOverflowScrollsStagesWithRoomForActions() async throws {
        let steps = TerminalConnectionStepID.allCases.map { id in
            switch id {
            case .shell:
                TerminalConnectionStep(id: id, state: .failed, detail: "PTY allocation failed")
            case .ready:
                TerminalConnectionStep(id: id)
            default:
                TerminalConnectionStep(id: id, state: .completed, durationMs: 120)
            }
        }
        let activity = makeActivity(steps: steps, failed: true)
        try await render(activity, typeSize: .accessibility3, colorScheme: .light) { view in
            let scrolls = scrollViews(in: view)
            XCTAssertEqual(scrolls.count, 1, "Stages and details should share one scroll view")
            let scroll = try XCTUnwrap(scrolls.first)
            let viewport = scroll.convert(scroll.bounds, to: view)
            XCTAssertGreaterThan(scroll.contentSize.height, viewport.height)
            XCTAssertGreaterThanOrEqual(
                view.bounds.maxY - viewport.maxY, 44,
                "The scroll viewport must leave room for the action footer"
            )
            XCTAssertGreaterThan(scroll.contentOffset.y, 0, "The late failed stage should scroll into view")
            attach(view, named: "Terminal connection · nine stages · large text · light")
        }
    }

    func testPrivateNetworkStagesScrollWithinOriginalHeightLimit() async throws {
        let steps = TerminalConnectionStepID.allCases.map { id in
            switch id {
            case .profile, .credential, .state, .route, .socks:
                TerminalConnectionStep(id: id, state: .completed, durationMs: 120)
            case .network:
                TerminalConnectionStep(id: id, state: .active)
            default:
                TerminalConnectionStep(id: id)
            }
        }
        try await render(makeActivity(steps: steps),
                         size: CGSize(width: 393, height: 744),
                         typeSize: .large, colorScheme: .dark) { view in
            let scrolls = scrollViews(in: view)
            XCTAssertEqual(scrolls.count, 1)
            let stages = try XCTUnwrap(scrolls.first)
            XCTAssertLessThanOrEqual(stages.bounds.height, 242)
            XCTAssertGreaterThan(stages.contentSize.height, stages.bounds.height)
            XCTAssertGreaterThan(stages.contentOffset.y, 0, "The active stage should be visible")
            attach(view, named: "Terminal connection · nine stages · dark")
        }
    }

    private let fixtureHost = Host(
        id: "connection-overlay-test",
        name: "A long fixture name for the connection progress card",
        address: "terminal.example.invalid",
        username: "fixture"
    )

    private func makeActivity(
        steps: [TerminalConnectionStep],
        failed: Bool = false
    ) -> TerminalConnectionActivity {
        TerminalConnectionActivity(
            id: fixtureHost.id,
            hostID: fixtureHost.id,
            hostName: fixtureHost.name,
            hostAddress: fixtureHost.address,
            kind: .connect,
            endedAt: failed ? .now : nil,
            state: failed ? .failed : .connecting,
            steps: steps,
            logs: [TerminalConnectionLogEntry(message: "Connection layout fixture")],
            errorMessage: failed ? "Connection could not allocate a terminal for the fixture." : nil
        )
    }

    private func render(
        _ activity: TerminalConnectionActivity,
        size: CGSize = CGSize(width: 320, height: 568),
        typeSize: DynamicTypeSize,
        colorScheme: ColorScheme,
        assertions: (UIView) throws -> Void
    ) async throws {
        let host = UIHostingController(rootView: TerminalConnectionOverlay(
            activity: activity, host: fixtureHost, onCancel: {}, onRetry: {}
        )
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.colorScheme, colorScheme)
        .transaction { $0.disablesAnimations = true })
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.size, size)
        try assertions(host.view)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let scroll = (view as? UIScrollView).map { [$0] } ?? []
        return scroll + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func attach(_ view: UIView, named name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
