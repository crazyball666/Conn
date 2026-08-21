import Foundation
#if canImport(UIKit)
    import ConnUI
    import SwiftUI
#endif

public enum TerminalAttachmentAction: String, Sendable, CaseIterable {
    case photos
    case files
    case clipboard
    case retry
    case insertPaths
    case cancel
}

public struct TerminalAttachmentPanelState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case preparing
        case uploading(name: String, progress: Double)
        case completed(count: Int, requiresManualInsertion: Bool)
        case notice(message: String)
        case failed(message: String)
    }

    public var phase: Phase

    public init(phase: Phase = .idle) {
        self.phase = phase
    }

    public static let idle = Self()
}

#if canImport(UIKit)
    struct TerminalAttachmentPanelView: View {
        let state: TerminalAttachmentPanelState
        let onAction: (TerminalAttachmentAction) -> Void

        var body: some View {
            VStack(spacing: TerminalKeybarMetrics.gridSpacing) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: TerminalKeybarMetrics.gridSpacing),
                        count: 3
                    ),
                    spacing: TerminalKeybarMetrics.gridSpacing
                ) {
                    attachmentCap(.photos, title: L("图片"), systemName: "photo.on.rectangle")
                    attachmentCap(.files, title: L("文件"), systemName: "doc")
                    attachmentCap(.clipboard, title: L("剪贴板"), systemName: "doc.on.clipboard")
                }

                attachmentStatus
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }

        @ViewBuilder
        private var attachmentStatus: some View {
            switch state.phase {
            case .idle:
                EmptyView()
            case .preparing:
                attachmentProgress(title: L("正在准备附件…"), progress: nil, action: .cancel)
            case let .uploading(name, progress):
                attachmentProgress(
                    title: String(format: L("正在上传：%@"), name),
                    progress: progress,
                    action: .cancel
                )
            case let .completed(count, requiresManualInsertion):
                if requiresManualInsertion {
                    HStack(spacing: TerminalKeybarMetrics.gridSpacing) {
                        Text(String(format: L("%d 个远端路径待插入"), count))
                            .font(.connData(.caption2))
                            .foregroundStyle(Color.connMuted)
                        Spacer(minLength: 0)
                        statusAction(L("插入路径"), action: .insertPaths)
                    }
                }
            case .notice:
                EmptyView()
            case .failed:
                HStack(spacing: TerminalKeybarMetrics.gridSpacing) {
                    Spacer(minLength: 0)
                    statusAction(L("重试"), action: .retry)
                }
            }
        }

        private func attachmentProgress(
            title: String,
            progress: Double?,
            action: TerminalAttachmentAction
        ) -> some View {
            HStack(spacing: TerminalKeybarMetrics.gridSpacing) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 110)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(title)
                    .font(.connData(.caption2))
                    .foregroundStyle(Color.connMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                statusAction(L("取消"), action: action)
            }
        }

        private func statusAction(
            _ title: String,
            action: TerminalAttachmentAction
        ) -> some View {
            Button(title) { onAction(action) }
                .font(.connData(.caption2))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("terminal.keybar.upload.\(action.rawValue)")
        }

        private func attachmentCap(
            _ action: TerminalAttachmentAction,
            title: String,
            systemName: String
        ) -> some View {
            Button { onAction(action) } label: {
                HStack(spacing: 5) {
                    Image(systemName: systemName)
                        .font(.system(size: 13, weight: .medium))
                    Text(title)
                        .font(.connData(.caption))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.connInk)
                .frame(maxWidth: .infinity)
                .frame(height: TerminalKeybarMetrics.capVisualHeight)
                .background(Color.connKey, in: .rect(cornerRadius: ConnRadius.key, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                        .strokeBorder(Color.connKeyline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(title)
            .accessibilityIdentifier("terminal.keybar.upload.\(action.rawValue)")
            .frame(height: TerminalKeybarMetrics.hitTargetHeight)
        }

        private var isBusy: Bool {
            switch state.phase {
            case .preparing, .uploading: true
            default: false
            }
        }
    }
#endif
