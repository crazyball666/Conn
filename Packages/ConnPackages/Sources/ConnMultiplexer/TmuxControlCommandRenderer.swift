import Foundation

package struct TmuxRenderedControlCommand: Sendable, Equatable {
    package let value: String

    package init(value: String) {
        self.value = value
    }

    /// Control Mode consumes one command per line. Values accepted by the operation layer
    /// cannot contain control characters, so appending exactly one LF is unambiguous.
    package var wireData: Data {
        Data((value + "\n").utf8)
    }
}

/// A targeted data-client configuration change. This stays separate from user-visible
/// workspace operations: it is runtime policy, but still goes through typed rendering and
/// the correlated Control Mode command pipeline.
package struct TmuxClientFlagUpdate: Sendable, Equatable {
    package let client: TmuxClientTarget
    package let flag: TmuxClientFlag
    package let enabled: Bool

    package init(client: TmuxClientTarget, flag: TmuxClientFlag, enabled: Bool) {
        self.client = client
        self.flag = flag
        self.enabled = enabled
    }
}

/// Renders only tmux command language for an existing Control Mode client.
/// It never includes a tmux executable, server locator, or POSIX shell wrapper.
package struct TmuxControlCommandRenderer: Sendable {
    package init() {}

    package func render(_ operation: TmuxOperation) -> TmuxRenderedControlCommand {
        let command: String
        switch operation {
        case let .createSession(name):
            var arguments = ["new-session", "-d", "-P", "-F", encode("#{session_id}")]
            if let name {
                arguments += ["-s", encode(name.value)]
            }
            command = arguments.joined(separator: " ")

        case let .renameSession(sessionID, name):
            command = join("rename-session", "-t", encode(sessionID.rawValue), encode(name.value))

        case let .detachClient(client):
            command = join("detach-client", "-t", encode(client.value))

        case let .killSession(sessionID):
            command = join("kill-session", "-t", encode(sessionID.rawValue))

        case let .selectWindow(windowID, client):
            command = join(
                "switch-client",
                "-c", encode(client.value),
                "-t", encode(windowID.rawValue)
            )

        case let .createWindow(sessionID, name):
            var arguments = [
                "new-window", "-d", "-P", "-F", encode("#{window_id}"),
                "-t", encode(sessionID.rawValue + ":"),
            ]
            if let name {
                arguments += ["-n", encode(name.value)]
            }
            command = arguments.joined(separator: " ")

        case let .renameWindow(windowID, name):
            command = join("rename-window", "-t", encode(windowID.rawValue), encode(name.value))

        case let .killWindow(windowID):
            command = join("kill-window", "-t", encode(windowID.rawValue))

        case let .selectPane(paneID, client):
            command = join(
                "switch-client",
                "-c", encode(client.value),
                "-t", encode(paneID.rawValue)
            )

        case let .splitPane(paneID, orientation):
            let direction = orientation == .horizontal ? "-h" : "-v"
            command = join(
                "split-window", "-d", "-P", "-F", encode("#{pane_id}"),
                direction, "-t", encode(paneID.rawValue)
            )

        case let .setPaneZoom(paneID, zoomed):
            let condition = zoomed
                ? "#{==:#{window_zoomed_flag},0}"
                : "#{window_zoomed_flag}"
            let toggle = join("resize-pane", "-Z", "-t", paneID.rawValue)
            command = join(
                "if-shell", "-F", "-t", encode(paneID.rawValue),
                encode(condition), encode(toggle), encode("")
            )

        case let .killPane(paneID):
            command = join("kill-pane", "-t", encode(paneID.rawValue))
        }
        return TmuxRenderedControlCommand(value: command)
    }

    package func render(_ update: TmuxClientFlagUpdate) -> TmuxRenderedControlCommand {
        let flag = update.enabled ? update.flag.rawValue : "!\(update.flag.rawValue)"
        return TmuxRenderedControlCommand(value: join(
            "refresh-client",
            "-t", encode(update.client.value),
            "-f", encode(flag)
        ))
    }

    private func join(_ arguments: String...) -> String {
        arguments.joined(separator: " ")
    }

    /// tmux expands backslashes, variables, and tildes outside single quotes. Inside single
    /// quotes it treats bytes literally; a literal quote is represented by closing the quote,
    /// escaping one quote outside it, then reopening it (`'\''`).
    private func encode(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
