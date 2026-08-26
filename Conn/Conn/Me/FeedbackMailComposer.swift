import Darwin
import Foundation
import MessageUI
import SwiftUI
import UIKit

struct FeedbackMailContent: Identifiable {
    let subject: String
    let body: String

    var id: String { subject }
}

enum FeedbackMailTemplate {
    /// 支持邮箱集中配置，正式发布前只需在此处替换。
    static let recipient = "support@crazyball.cc"

    static func make() -> FeedbackMailContent {
        let model = FeedbackDeviceInfo.model
        let systemVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let appVersion = FeedbackDeviceInfo.appVersion
        let body = [
            "",
            "",
            "",
            "",
            "",
            "Device: \(model)",
            "OS: \(systemVersion)",
            "App Version: \(appVersion)",
        ].joined(separator: "\n")

        return FeedbackMailContent(
            subject: L("ConnTerm 问题反馈"),
            body: body
        )
    }
}

private enum FeedbackDeviceInfo {
    static var model: String {
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            ?? machineIdentifier
        let baseModel = UIDevice.current.localizedModel
        return identifier.isEmpty || identifier == baseModel
            ? baseModel
            : "\(baseModel) (\(identifier))"
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String
        if let build, !build.isEmpty, build != version {
            return "\(version) (\(build))"
        }
        return version
    }

    private static var machineIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
    }
}

struct FeedbackMailComposer: UIViewControllerRepresentable {
    let content: FeedbackMailContent
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([FeedbackMailTemplate.recipient])
        controller.setSubject(content.subject)
        controller.setMessageBody(content.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true, completion: onFinish)
        }
    }
}
