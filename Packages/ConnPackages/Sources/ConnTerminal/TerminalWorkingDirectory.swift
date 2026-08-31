import Foundation

/// The terminal-side sources that can provide a host file-browser directory.
public enum TerminalWorkingDirectorySource: Sendable, Equatable {
    case provider
    case osc7
}

/// Strict path normalization shared by provider metadata and OSC 7 reports.
public enum TerminalWorkingDirectoryPath {
    /// Parses a SwiftTerm OSC 7 payload. Only `file:` URLs are accepted; URL
    /// host, query, and fragment are deliberately ignored because the file
    /// browser connects to the already-selected host.
    public static func osc7Path(from value: String?) -> String? {
        guard let value, hasSafeCharacters(value) else { return nil }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme,
              scheme.caseInsensitiveCompare("file") == .orderedSame
        else {
            return nil
        }

        guard let rawPath = rawURLPath(from: value),
              hasValidPercentEscapes(rawPath)
        else {
            return nil
        }

        let encodedPath = components.percentEncodedPath
        guard !encodedPath.isEmpty,
              encodedPath.hasPrefix("/"),
              hasValidPercentEscapes(encodedPath),
              let decodedPath = encodedPath.removingPercentEncoding,
              hasSafeCharacters(decodedPath)
        else {
            return nil
        }
        return normalizedAbsolutePath(decodedPath)
    }

    /// Validates a provider-reported raw POSIX path without interpreting it
    /// as a URL. This keeps provider metadata and OSC 7 trust boundaries
    /// separate while applying the same traversal/character rules.
    public static func providerPath(from value: String?) -> String? {
        guard let value,
              hasSafeCharacters(value),
              hasValidPercentEscapes(value)
        else {
            return nil
        }
        return normalizedAbsolutePath(value)
    }

    private static func normalizedAbsolutePath(_ value: String) -> String? {
        guard value.first == "/" else { return nil }

        var components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "" else { return nil }
        components.removeFirst()

        if components.last == "" {
            components.removeLast()
        }

        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func hasSafeCharacters(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func rawURLPath(from value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        var remainder = value[value.index(after: colon)...]

        if remainder.hasPrefix("//") {
            remainder.removeFirst(2)
            guard let slash = remainder.firstIndex(of: "/") else { return "" }
            remainder = remainder[slash...]
        }

        let end = remainder.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? remainder.endIndex
        return String(remainder[..<end])
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        for index in scalars.indices where scalars[index] == "%" {
            guard scalars.index(after: index) < scalars.endIndex,
                  let secondIndex = scalars.index(index, offsetBy: 2, limitedBy: scalars.index(before: scalars.endIndex)),
                  isHex(scalars[scalars.index(after: index)]),
                  isHex(scalars[secondIndex])
            else {
                return false
            }
        }
        return true
    }

    private static func isHex(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."f", "A"..."F": return true
        default: return false
        }
    }
}

/// Keeps terminal working-directory candidates isolated by connection
/// generation. `TerminalScreen` owns one instance per terminal tab.
public struct TerminalWorkingDirectoryResolver: Sendable, Equatable {
    public private(set) var generation: UInt64?
    private var providerPath: String?
    private var osc7Path: String?

    public init() {}

    public var effectivePath: String? {
        providerPath ?? osc7Path
    }

    /// Invalidates candidates when a tab's connection generation changes even
    /// before the new connection emits a directory report.
    public mutating func synchronize(generation: UInt64) {
        guard self.generation == nil || generation > self.generation! else { return }
        self.generation = generation
        providerPath = nil
        osc7Path = nil
    }

    /// Updates one already-normalized source value. A newer generation clears
    /// both candidates; an old generation is ignored. A nil provider value
    /// removes only the provider candidate so a valid OSC 7 fallback remains
    /// usable.
    public mutating func update(
        source: TerminalWorkingDirectorySource,
        generation: UInt64,
        path: String?
    ) {
        if let currentGeneration = self.generation {
            guard generation >= currentGeneration else { return }
            if generation > currentGeneration { synchronize(generation: generation) }
        } else {
            self.generation = generation
        }

        switch source {
        case .provider:
            let normalized = path.flatMap(TerminalWorkingDirectoryPath.providerPath(from:))
            guard path == nil || normalized != nil else {
                return
            }
            providerPath = normalized
        case .osc7:
            let normalized = path.flatMap(TerminalWorkingDirectoryPath.providerPath(from:))
            guard path == nil || normalized != nil else {
                return
            }
            osc7Path = normalized
        }
    }
}
