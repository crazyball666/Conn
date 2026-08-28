import ConnUI
import SwiftUI

/// Shared loading content for every terminal-creation entry point.
struct TerminalCreationLoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: ConnSpacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(.connAccent)
            Text(title)
                .foregroundStyle(.connMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.creation.loading")
    }
}
