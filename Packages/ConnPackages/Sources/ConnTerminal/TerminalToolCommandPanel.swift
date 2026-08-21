import Foundation

struct TerminalToolCommandDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let command: String
    let systemImageName: String
}

struct TerminalToolCommandSection: Identifiable, Sendable, Equatable {
    let id: String
    let titleKey: String
    let actions: [TerminalToolCommandDescriptor]
}

/// A provider-neutral catalog of commands that can be inserted into a terminal prompt.
///
/// The catalog deliberately stores insertion-only text. Executing a command remains an
/// explicit user action, so selecting an item can never submit or interrupt a TUI session.
struct TerminalToolCommandCatalog: Sendable, Equatable {
    let id: String
    let sections: [TerminalToolCommandSection]

    static let claudeCode = TerminalToolCommandCatalog(
        id: "claude-code",
        sections: [
            .init(
                id: "session",
                titleKey: "会话与上下文",
                actions: [
                    .init(id: "clear", command: "/clear", systemImageName: "trash"),
                    .init(id: "compact", command: "/compact", systemImageName: "rectangle.compress.vertical"),
                    .init(id: "context", command: "/context", systemImageName: "chart.pie"),
                    .init(id: "resume", command: "/resume", systemImageName: "clock.arrow.circlepath"),
                    .init(id: "rewind", command: "/rewind", systemImageName: "arrow.uturn.backward"),
                    .init(id: "status", command: "/status", systemImageName: "info.circle")
                ]
            ),
            .init(
                id: "workflow",
                titleKey: "开发工作流",
                actions: [
                    .init(id: "plan", command: "/plan", systemImageName: "list.bullet.clipboard"),
                    .init(id: "diff", command: "/diff", systemImageName: "plus.forwardslash.minus"),
                    .init(id: "review", command: "/review", systemImageName: "checkmark.seal"),
                    .init(id: "tasks", command: "/tasks", systemImageName: "list.bullet.rectangle"),
                    .init(id: "memory", command: "/memory", systemImageName: "brain"),
                    .init(id: "mcp", command: "/mcp", systemImageName: "server.rack")
                ]
            ),
            .init(
                id: "configuration",
                titleKey: "配置与诊断",
                actions: [
                    .init(id: "model", command: "/model", systemImageName: "cpu"),
                    .init(id: "permissions", command: "/permissions", systemImageName: "lock.shield"),
                    .init(id: "usage", command: "/usage", systemImageName: "chart.bar"),
                    .init(id: "config", command: "/config", systemImageName: "gearshape"),
                    .init(id: "doctor", command: "/doctor", systemImageName: "stethoscope"),
                    .init(id: "help", command: "/help", systemImageName: "questionmark.circle")
                ]
            )
        ]
    )
}

#if canImport(UIKit)
    import ConnUI
    import SwiftUI

    struct TerminalToolCommandPanelView: View {
        let catalog: TerminalToolCommandCatalog
        let onCommand: (String) -> Void

        var body: some View {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: TerminalKeybarMetrics.gridSpacing) {
                    ForEach(catalog.sections) { section in
                        Text(L(section.titleKey))
                            .font(.connData(.caption2))
                            .foregroundStyle(Color.connMuted)
                            .padding(.leading, 2)

                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(
                                    .flexible(),
                                    spacing: TerminalKeybarMetrics.gridSpacing
                                ),
                                count: TerminalKeybarMetrics.providerColumnCount
                            ),
                            spacing: TerminalKeybarMetrics.gridSpacing
                        ) {
                            ForEach(section.actions) { action in
                                commandCap(action)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
        }

        private func commandCap(_ action: TerminalToolCommandDescriptor) -> some View {
            Button {
                onCommand(action.command)
            } label: {
                VStack(spacing: TerminalKeybarMetrics.providerContentSpacing) {
                    Image(systemName: action.systemImageName)
                        .font(
                            .system(
                                size: TerminalKeybarMetrics.providerIconSize,
                                weight: .medium
                            )
                        )
                        .frame(height: TerminalKeybarMetrics.providerIconSize)
                    Text(action.command)
                        .font(
                            .system(
                                size: TerminalKeybarMetrics.providerLabelSize,
                                weight: .regular,
                                design: .monospaced
                            )
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .allowsTightening(true)
                }
                .foregroundStyle(Color.connInk)
                .padding(.horizontal, TerminalKeybarMetrics.providerContentHorizontalPadding)
                .padding(.vertical, TerminalKeybarMetrics.providerContentVerticalPadding)
                .frame(maxWidth: .infinity)
                .frame(height: TerminalKeybarMetrics.capVisualHeight)
                .background(
                    Color.connKey,
                    in: .rect(cornerRadius: ConnRadius.key, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                        .strokeBorder(Color.connKeyline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(action.command))
            .accessibilityIdentifier("terminal.keybar.tool.\(catalog.id).\(action.id)")
            .frame(height: TerminalKeybarMetrics.hitTargetHeight)
        }
    }
#endif
