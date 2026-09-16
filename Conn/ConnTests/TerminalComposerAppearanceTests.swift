import ConnUI
import SwiftUI
import UIKit
import XCTest
@testable import ConnTerminal

/// Render the production accessory itself, with no SSH accounts or test routes in the app.
@MainActor
final class TerminalComposerAppearanceTests: XCTestCase {
    func testCompactAccessoryAndSpeechStates() async {
        for scheme in [ColorScheme.dark, .light] {
            for state in [TerminalSpeechComposerState.idle, .unavailable, .listening, .stopping] {
                let height = await capture(
                    name: "composer-\(scheme)-\(state)",
                    text: state.isCapturing ? "列出当前目录的文件" : "",
                    speechState: state,
                    colorScheme: scheme,
                    width: 393
                )
                XCTAssertLessThanOrEqual(height, state.isCapturing ? 140 : 110)
                XCTAssertGreaterThanOrEqual(height, 100)
            }
        }
    }

    func testMultilineIsBoundedOnNarrowAndWideScreens() async {
        let text = "printf one\nprintf two\nprintf three\nprintf four\nprintf five\nprintf six"
        for width in [CGFloat(320), 700] {
            let height = await capture(
                name: "composer-multiline-\(Int(width))",
                text: text, speechState: .idle, colorScheme: .dark, width: width
            )
            XCTAssertGreaterThan(height, 110)
            XCTAssertLessThanOrEqual(height, 185, "Editor must stop growing at four lines")
        }
    }

    func testLargeTypeFitsAndExpandedKeysStayInsideAccessory() async {
        let height = await capture(
            name: "composer-large-type", text: "查看运行状态", speechState: .listening,
            colorScheme: .light, width: 320, typeSize: .accessibility3
        )
        XCTAssertGreaterThan(height, 130)
        XCTAssertLessThan(height, 370)
        let expanded = await capture(
            name: "composer-expanded", text: "", speechState: .idle,
            colorScheme: .dark, width: 393, expanded: true
        )
        XCTAssertLessThanOrEqual(expanded, 350)
    }

    @discardableResult
    private func capture(
        name: String,
        text: String,
        speechState: TerminalSpeechComposerState,
        colorScheme: ColorScheme,
        width: CGFloat,
        typeSize: DynamicTypeSize = .large,
        expanded: Bool = false
    ) async -> CGFloat {
        let view = TerminalInputBar {
            TerminalCommandComposer(
                text: .constant(text), isSubmitting: .constant(false),
                speechState: speechState, onSubmit: { _ in }
            )
            TerminalKeybar(
                ctrlActive: false, isExpanded: expanded, onKey: { _ in },
                onPaste: { _ in }, onInsertToolCommand: { _ in },
                onCloseTerminal: {}, onSwitchTerminal: {}, onOpenFileBrowser: {},
                onChooseCommand: {}, onReconnect: {}, pointerAvailable: false,
                pointerActive: false, onTogglePointer: {}, providerQuickActionGroup: nil,
                performingProviderQuickActionID: nil, onProviderQuickAction: { _ in },
                keyboardVisible: false, keyboardToggleEnabled: !speechState.isCapturing,
                onToggleKeyboard: {}, onExpansionChange: { _ in },
                attachmentState: .idle, onAttachmentAction: { _ in }
            )
            .frame(height: expanded ? TerminalKeybarMetrics.expandedHeight : TerminalKeybarMetrics.compactHeight)
        }
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, typeSize)

        let measuringHost = UIHostingController(rootView: view)
        measuringHost.safeAreaRegions = []
        let size = measuringHost.sizeThatFits(in: CGSize(width: width, height: 600))
        XCTAssertEqual(size.width, width, accuracy: 1)
        // Mount a fresh native editor at its final size. Reusing the sizing host
        // leaves UITextField's scroll viewport at the old 600pt proposal.
        let host = UIHostingController(rootView: view.frame(width: width, height: size.height))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Let the native multiline field settle its scroll viewport after sizeThatFits.
        try? await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        return size.height
    }
}
