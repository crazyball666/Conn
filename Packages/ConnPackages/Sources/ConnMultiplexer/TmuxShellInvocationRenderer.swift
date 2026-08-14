import ConnSSH
import Foundation

package enum TmuxShellInvocationError: Error, Sendable, Equatable {
    case invalidExecutablePath
    case invalidNonce
    case locatorInstanceMismatch
}

package struct TmuxExecutablePath: Sendable, Equatable, Hashable {
    package let value: String

    package init(_ value: String) throws {
        guard value.hasPrefix("/"), !Self.containsControlCharacter(value) else {
            throw TmuxShellInvocationError.invalidExecutablePath
        }

        var components: [Substring] = []
        for component in value.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                throw TmuxShellInvocationError.invalidExecutablePath
            default:
                components.append(component)
            }
        }
        guard !components.isEmpty else {
            throw TmuxShellInvocationError.invalidExecutablePath
        }
        self.value = "/" + components.joined(separator: "/")
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
        }
    }
}

package struct TmuxInvocationNonce: Sendable, Equatable, Hashable {
    package let value: String

    package init(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
                      || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
                      || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                      || byte == UInt8(ascii: "-")
                      || byte == UInt8(ascii: "_")
              })
        else {
            throw TmuxShellInvocationError.invalidNonce
        }
        self.value = value
    }
}

package struct TmuxShellInvocation: Sendable, Equatable {
    package let executable: TmuxExecutablePath
    package let arguments: [String]
    package let script: String
    package let guardAcceptedMarker: String
    package let instanceChangedMarker: String
}

/// Renders a one-shot operation as one POSIX invocation of a pinned tmux executable.
///
/// The server PID/start-time check and operation are queued by the same tmux client process.
/// The selected socket is part of that same process's argv, removing the check/use gap that
/// would exist if identity were queried by an earlier SSH command.
package struct TmuxShellInvocationRenderer: Sendable {
    package init() {}

    package func render(
        _ operation: TmuxOperation,
        executable: TmuxExecutablePath,
        locator: TmuxServerLocator,
        expectedInstance: TmuxServerInstanceToken,
        nonce: TmuxInvocationNonce
    ) throws -> TmuxShellInvocation {
        if locator.kind == .socketPath,
           locator.value != expectedInstance.resolvedSocketPath {
            throw TmuxShellInvocationError.locatorInstanceMismatch
        }

        let guardAcceptedMarker = "__CONN_TMUX_GUARD_ACCEPTED_\(nonce.value)__"
        let instanceChangedMarker = "__CONN_TMUX_INSTANCE_CHANGED_\(nonce.value)__"
        let condition = "#{&&:#{==:#{pid},\(expectedInstance.serverPID)},"
            + "#{==:#{start_time},\(expectedInstance.serverStartTime)}}"

        let guardedCommand = join(
            "display-message", "-p", encodeTmux(guardAcceptedMarker),
            ";", renderNested(operation)
        )
        let rejectedCommand = join(
            "display-message", "-p", encodeTmux(instanceChangedMarker)
        )
        let arguments = locator.arguments + [
            "if-shell", "-F", condition, guardedCommand, rejectedCommand,
        ]
        let script = (["exec", executable.value] + arguments)
            .map(encodePOSIX)
            .joined(separator: " ")

        return TmuxShellInvocation(
            executable: executable,
            arguments: arguments,
            script: script,
            guardAcceptedMarker: guardAcceptedMarker,
            instanceChangedMarker: instanceChangedMarker
        )
    }

    /// This renderer intentionally owns its tmux-language rendering. It does not reuse the
    /// Control Mode renderer's final string because this command is nested inside `if-shell`
    /// and is then independently encoded as one POSIX argv element.
    private func renderNested(_ operation: TmuxOperation) -> String {
        switch operation {
        case let .createSession(name):
            var arguments = ["new-session", "-d", "-P", "-F", encodeTmux("#{session_id}")]
            if let name {
                arguments += ["-s", encodeTmux(name.value)]
            }
            return arguments.joined(separator: " ")

        case let .renameSession(sessionID, name):
            return join(
                "rename-session", "-t", encodeTmux(sessionID.rawValue), encodeTmux(name.value)
            )

        case let .detachClient(client):
            return join("detach-client", "-t", encodeTmux(client.value))

        case let .killSession(sessionID):
            return join("kill-session", "-t", encodeTmux(sessionID.rawValue))

        case let .selectWindow(windowID, client):
            return join(
                "switch-client", "-c", encodeTmux(client.value),
                "-t", encodeTmux(windowID.rawValue)
            )

        case let .createWindow(sessionID, name):
            var arguments = [
                "new-window", "-d", "-P", "-F", encodeTmux("#{window_id}"),
                "-t", encodeTmux(sessionID.rawValue + ":"),
            ]
            if let name {
                arguments += ["-n", encodeTmux(name.value)]
            }
            return arguments.joined(separator: " ")

        case let .renameWindow(windowID, name):
            return join(
                "rename-window", "-t", encodeTmux(windowID.rawValue), encodeTmux(name.value)
            )

        case let .killWindow(windowID):
            return join("kill-window", "-t", encodeTmux(windowID.rawValue))

        case let .selectPane(paneID, client):
            return join(
                "switch-client", "-c", encodeTmux(client.value),
                "-t", encodeTmux(paneID.rawValue)
            )

        case let .splitPane(paneID, orientation):
            let direction = orientation == .horizontal ? "-h" : "-v"
            return join(
                "split-window", "-d", "-P", "-F", encodeTmux("#{pane_id}"),
                direction, "-t", encodeTmux(paneID.rawValue)
            )

        case let .setPaneZoom(paneID, zoomed):
            let condition = zoomed
                ? "#{==:#{window_zoomed_flag},0}"
                : "#{window_zoomed_flag}"
            let toggle = join("resize-pane", "-Z", "-t", paneID.rawValue)
            return join(
                "if-shell", "-F", "-t", encodeTmux(paneID.rawValue),
                encodeTmux(condition), encodeTmux(toggle), encodeTmux("")
            )

        case let .killPane(paneID):
            return join("kill-pane", "-t", encodeTmux(paneID.rawValue))
        }
    }

    private func join(_ arguments: String...) -> String {
        arguments.joined(separator: " ")
    }

    private func encodeTmux(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func encodePOSIX(_ argument: String) -> String {
        POSIXShellArgument.encode(argument)
    }
}
