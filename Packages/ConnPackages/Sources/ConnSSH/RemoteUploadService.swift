import Foundation

/// Deterministic remote-name policy shared by terminal attachments and file management.
public struct RemoteUploadNaming: Sendable {
    private let now: @Sendable () -> Date
    private let suffix: @Sendable () -> String

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        suffix: @escaping @Sendable () -> String = {
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        }
    ) {
        self.now = now
        self.suffix = suffix
    }

    public func remoteName(for originalName: String) -> String {
        let source = originalName as NSString
        let rawExtension = source.pathExtension
        let rawStem = source.deletingPathExtension
        let stem = Self.sanitize(rawStem).isEmpty ? "attachment" : Self.sanitize(rawStem)
        let date = Self.timestamp(now())
        let token = Self.sanitize(suffix()).uppercased()
        let prefix = [date, token.isEmpty ? "UPLOAD" : token, stem].joined(separator: "-")
        guard !rawExtension.isEmpty else { return prefix }
        return prefix + "." + rawExtension.lowercased()
    }

    private static func sanitize(_ value: String) -> String {
        var result = ""
        var lastWasSeparator = false
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !result.isEmpty, !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(64))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

public struct RemoteUploadedResource: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let originalName: String
    public let remotePath: String
    public let terminalReferencePath: String
    public let byteCount: UInt64

    public init(
        id: UUID = UUID(),
        originalName: String,
        remotePath: String,
        terminalReferencePath: String,
        byteCount: UInt64
    ) {
        self.id = id
        self.originalName = originalName
        self.remotePath = remotePath
        self.terminalReferencePath = terminalReferencePath
        self.byteCount = byteCount
    }
}

/// Atomic, bounded-memory upload primitive over an already-open remote filesystem.
public struct RemoteUploadService: Sendable {
    public enum UploadError: Error, Sendable, Equatable {
        case invalidRemoteName
    }

    private let chunkSize: Int
    private let naming: RemoteUploadNaming

    public init(
        chunkSize: Int = 64 * 1024,
        naming: RemoteUploadNaming = RemoteUploadNaming()
    ) {
        precondition(chunkSize > 0)
        self.chunkSize = chunkSize
        self.naming = naming
    }

    public func upload(
        localURL: URL,
        originalName: String? = nil,
        remoteName: String? = nil,
        to remoteDirectory: String,
        using fileSystem: any RemoteFileSystem,
        onProgress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> RemoteUploadedResource {
        try Task.checkCancellation()
        let scoped = localURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                localURL.stopAccessingSecurityScopedResource()
            }
        }

        let displayName = originalName ?? localURL.lastPathComponent
        let resolvedRemoteName = remoteName ?? naming.remoteName(for: displayName)
        guard Self.isSingleSafeComponent(resolvedRemoteName) else {
            throw UploadError.invalidRemoteName
        }
        let remotePath = RemotePath.join(remoteDirectory, resolvedRemoteName)
        let size = try Self.localFileSize(localURL)
        let denominator = max(size, 1)
        try await ensureDirectory(remoteDirectory, using: fileSystem)
        await onProgress(0)

        let localHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? localHandle.close() }

        try await fileSystem.writeFileSafely(
            to: remotePath,
            fallbackPermissions: 0o600
        ) { temporaryPath in
            let remoteFile = try await fileSystem.open(
                temporaryPath,
                mode: .writeCreate,
                creationPermissions: 0o600
            )
            var offset: UInt64 = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let data = try localHandle.read(upToCount: chunkSize) ?? Data()
                    if data.isEmpty {
                        break
                    }
                    try await remoteFile.write(data, at: offset)
                    offset += UInt64(data.count)
                    await onProgress(min(1, Double(offset) / Double(denominator)))
                }
                try await remoteFile.close()
            } catch {
                try? await remoteFile.close()
                throw error
            }
        }
        await onProgress(1)

        return RemoteUploadedResource(
            originalName: displayName,
            remotePath: remotePath,
            terminalReferencePath: remotePath,
            byteCount: size
        )
    }

    private func ensureDirectory(
        _ path: String,
        using fileSystem: any RemoteFileSystem
    ) async throws {
        guard path != "/" else { return }
        do {
            let entry = try await fileSystem.stat(path)
            guard entry.isDirectory else { throw SFTPFileError.alreadyExists(path) }
            return
        } catch where Self.isMissing(error) {
            let parent = RemotePath.parent(path)
            try await ensureDirectory(parent, using: fileSystem)
            do {
                try await fileSystem.createDirectory(path)
            } catch let error as SFTPFileError {
                guard case .alreadyExists = error else { throw error }
            }
            try await fileSystem.setPermissions(0o700, path: path)
        }
    }

    private static func localFileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values.fileSize ?? 0)
    }

    private static func isSingleSafeComponent(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func isMissing(_ error: Error) -> Bool {
        if let error = error as? SFTPFileError, case .notFound = error {
            return true
        }
        if let error = error as? SSHError,
           case let .sftpError(code, _) = error,
           code == 2 {
            return true
        }
        return false
    }
}
