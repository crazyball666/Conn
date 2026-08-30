import Foundation

/// Failures in the machine protocol used to resolve remote executables.
public enum RemoteExecutableResolutionError: Error, Sendable, Equatable {
    case invalidExecutableName
    case invalidProbeResponse
}

/// Resolves remote executables against the user's login-shell PATH without
/// changing the semantics of ordinary SSH exec commands.
///
/// The first lookup for an SSH session starts the account's configured shell as
/// an interactive login shell, captures only PATH, and resolves all requested
/// executables in the same round trip. Later lookups on that concrete session
/// reuse the captured PATH. No installation directories or operating-system
/// package-manager conventions are assumed.
public actor RemoteExecutableResolver {
    public static let shared = RemoteExecutableResolver()

    private struct CacheEntry: Sendable {
        let path: String
        // Retaining the session prevents ObjectIdentifier reuse while cached.
        let session: any SSHSession
        var lastAccess: Date
    }

    private struct ProbeResponse: Sendable {
        let path: String
        let executables: [String?]
    }

    private let cacheLifetime: TimeInterval = 300
    private let maximumEntryCount = 32
    private let nonceGenerator: @Sendable () -> String
    private var entries: [ObjectIdentifier: CacheEntry] = [:]

    public init() {
        nonceGenerator = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    }

    init(nonceGenerator: @escaping @Sendable () -> String) {
        self.nonceGenerator = nonceGenerator
    }

    public func resolve(
        _ executable: String,
        on session: any SSHSession,
        timeout: Duration = .seconds(15)
    ) async throws -> String? {
        try await resolve([executable], on: session, timeout: timeout)[executable]
    }

    /// Resolves a batch in one remote command. Missing executables are omitted
    /// from the returned dictionary.
    public func resolve(
        _ executables: [String],
        on session: any SSHSession,
        timeout: Duration = .seconds(15)
    ) async throws -> [String: String] {
        let names = try validatedUniqueNames(executables)
        guard !names.isEmpty else { return [:] }

        let sessionID = ObjectIdentifier(session)
        pruneExpiredEntries()

        if let path = cachedPath(for: sessionID) {
            let nonce = makeNonce()
            let command = cachedPathProbeCommand(
                path: path,
                executables: names,
                nonce: nonce
            )
            let result = try await session.exec(command, timeout: timeout)
            guard result.isSuccess,
                  let response = parseProbeResponse(
                      result.stdout,
                      executables: names,
                      nonce: nonce
                  )
            else {
                throw RemoteExecutableResolutionError.invalidProbeResponse
            }
            return resolvedDictionary(names: names, response: response)
        }

        let loginNonce = makeNonce()
        let loginResult = try await session.exec(
            loginShellProbeCommand(executables: names, nonce: loginNonce),
            timeout: timeout
        )
        if loginResult.isSuccess,
           let response = parseProbeResponse(
               loginResult.stdout,
               executables: names,
               nonce: loginNonce
           ) {
            insert(path: response.path, session: session, for: sessionID)
            return resolvedDictionary(names: names, response: response)
        }

        // Preserve compatibility with accounts whose login startup files fail
        // or whose SSH server does not expose SHELL. This is the old exec
        // environment, but still uses the same strict framed protocol.
        let fallbackNonce = makeNonce()
        let fallbackResult = try await session.exec(
            probeScript(executables: names, nonce: fallbackNonce),
            timeout: timeout
        )
        guard fallbackResult.isSuccess,
              let response = parseProbeResponse(
                  fallbackResult.stdout,
                  executables: names,
                  nonce: fallbackNonce
              )
        else {
            throw RemoteExecutableResolutionError.invalidProbeResponse
        }
        insert(path: response.path, session: session, for: sessionID)
        return resolvedDictionary(names: names, response: response)
    }

    private func validatedUniqueNames(_ values: [String]) throws -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            guard Self.isValidExecutableName(value) else {
                throw RemoteExecutableResolutionError.invalidExecutableName
            }
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    private static func isValidExecutableName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first != "-",
              !value.contains("/")
        else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"
        )
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func loginShellProbeCommand(executables: [String], nonce: String) -> String {
        let inner = POSIXShellArgument.encode(
            probeScript(executables: executables, nonce: nonce)
        )
        return """
        conn_login_shell=${SHELL:-}
        case "$conn_login_shell" in /*) ;; *) exit 70 ;; esac
        [ -x "$conn_login_shell" ] || exit 70
        exec "$conn_login_shell" -i -l -c \(inner)
        """
    }

    private func cachedPathProbeCommand(
        path: String,
        executables: [String],
        nonce: String
    ) -> String {
        "PATH=\(POSIXShellArgument.encode(path)); export PATH\n"
            + probeScript(executables: executables, nonce: nonce)
    }

    private func probeScript(executables: [String], nonce: String) -> String {
        let begin = Self.beginMarker(nonce)
        let end = Self.endMarker(nonce)
        var lines = [
            "conn_probe_path=${PATH:-}",
            "printf '%s\\n' '\(begin)'",
            "printf '%s\\n' \"$conn_probe_path\""
        ]

        for (index, executable) in executables.enumerated() {
            lines += [
                "conn_found=",
                "conn_remaining=$conn_probe_path",
                "conn_last=0",
                "while :; do",
                "    case \"$conn_remaining\" in",
                "        *:*) conn_dir=${conn_remaining%%:*}; conn_remaining=${conn_remaining#*:} ;;",
                "        *) conn_dir=$conn_remaining; conn_remaining=; conn_last=1 ;;",
                "    esac",
                "    case \"$conn_dir\" in",
                "        /*) conn_candidate=\"${conn_dir}/\(executable)\"; "
                    + "if [ -f \"$conn_candidate\" ] && [ -x \"$conn_candidate\" ]; then "
                    + "conn_found=$conn_candidate; break; fi ;;",
                "    esac",
                "    [ \"$conn_last\" -eq 1 ] && break",
                "done",
                "printf '%s\\n' '\(Self.itemMarker(index: index, nonce: nonce))'",
                "printf '%s\\n' \"$conn_found\""
            ]
        }
        lines.append("printf '%s\\n' '\(end)'")
        return lines.joined(separator: "\n")
    }

    private func parseProbeResponse(
        _ data: Data,
        executables: [String],
        nonce: String
    ) -> ProbeResponse? {
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let beginIndex = lines.firstIndex(of: Self.beginMarker(nonce)),
              lines.indices.contains(beginIndex + 1)
        else { return nil }

        let path = lines[beginIndex + 1]
        guard Self.isValidEnvironmentPath(path) else { return nil }
        var cursor = beginIndex + 2
        var resolved: [String?] = []
        resolved.reserveCapacity(executables.count)

        for index in executables.indices {
            guard lines.indices.contains(cursor + 1),
                  lines[cursor] == Self.itemMarker(index: index, nonce: nonce)
            else { return nil }
            let value = lines[cursor + 1]
            if value.isEmpty {
                resolved.append(nil)
            } else if Self.isValidResolvedExecutablePath(value) {
                resolved.append(value)
            } else {
                return nil
            }
            cursor += 2
        }

        guard lines.indices.contains(cursor),
              lines[cursor] == Self.endMarker(nonce)
        else { return nil }
        return ProbeResponse(path: path, executables: resolved)
    }

    private static func isValidEnvironmentPath(_ value: String) -> Bool {
        !value.isEmpty && !containsControlCharacters(value)
    }

    private static func isValidResolvedExecutablePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !containsControlCharacters(value)
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0.value < 0x20 || (0x7F ... 0x9F).contains($0.value)
        }
    }

    private func resolvedDictionary(
        names: [String],
        response: ProbeResponse
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (name, executable) in zip(names, response.executables) {
            if let executable {
                result[name] = executable
            }
        }
        return result
    }

    private func cachedPath(for sessionID: ObjectIdentifier) -> String? {
        guard var entry = entries[sessionID] else { return nil }
        entry.lastAccess = .now
        entries[sessionID] = entry
        return entry.path
    }

    private func insert(
        path: String,
        session: any SSHSession,
        for sessionID: ObjectIdentifier
    ) {
        entries[sessionID] = CacheEntry(path: path, session: session, lastAccess: .now)
        guard entries.count > maximumEntryCount,
              let oldest = entries.min(by: {
                  $0.value.lastAccess < $1.value.lastAccess
              })?.key
        else { return }
        entries[oldest] = nil
    }

    private func pruneExpiredEntries() {
        let now = Date()
        entries = entries.filter {
            now.timeIntervalSince($0.value.lastAccess) <= cacheLifetime
        }
    }

    private func makeNonce() -> String {
        let candidate = nonceGenerator().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        return candidate.isEmpty
            ? UUID().uuidString.replacingOccurrences(of: "-", with: "")
            : candidate
    }

    private static func beginMarker(_ nonce: String) -> String {
        "__CONN_EXECUTABLES_v1_BEGIN_\(nonce)__"
    }

    private static func itemMarker(index: Int, nonce: String) -> String {
        "__CONN_EXECUTABLES_v1_ITEM_\(index)_\(nonce)__"
    }

    private static func endMarker(_ nonce: String) -> String {
        "__CONN_EXECUTABLES_v1_END_\(nonce)__"
    }
}
