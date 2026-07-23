import Citadel
import ConnSSH
import Foundation
import NIOCore

/// Citadel `SFTPClient` 到 `ConnSSH.RemoteFileSystem` 的适配（方案 §4.5）。
final class CitadelFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let client: SFTPClient

    init(client: SFTPClient) {
        self.client = client
    }

    func list(_ path: String) async throws -> [FileEntry] {
        let names = try await client.listDirectory(atPath: path)
        return names
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                Self.entry(filename: component.filename, dir: path,
                           attributes: component.attributes, longname: component.longname)
            }
            .sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory : lhs.name < rhs.name
            }
    }

    func stat(_ path: String) async throws -> FileEntry {
        let attributes = try await client.getAttributes(at: path)
        return Self.entry(filename: RemotePath.lastComponent(path),
                          dir: RemotePath.parent(path), attributes: attributes, longname: nil)
    }

    func open(_ path: String, mode: RemoteFileMode) async throws -> any RemoteFile {
        let flags: SFTPOpenFileFlags = switch mode {
        case .read: .read
        case .write: [.write, .truncate]
        case .writeCreate: [.write, .create, .truncate]
        }
        let file = try await client.openFile(filePath: path, flags: flags)
        return CitadelRemoteFile(file: file)
    }

    func createDirectory(_ path: String) async throws {
        try await client.createDirectory(atPath: path)
    }

    func remove(_ path: String) async throws {
        try await client.remove(at: path)
    }

    func removeDirectory(_ path: String) async throws {
        try await client.rmdir(at: path)
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await client.rename(at: path, to: newPath)
    }

    func setPermissions(_ mode: UInt32, path: String) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = mode & 0o7777
        try await client.setAttributes(at: path, to: attributes)
    }

    func realPath(_ path: String) async throws -> String {
        try await client.getRealPath(atPath: path)
    }

    func close() async {
        try? await client.close()
    }

    /// SFTP 属性 → 领域 `FileEntry`。
    private static func entry(
        filename: String,
        dir: String,
        attributes: SFTPFileAttributes,
        longname: String?
    ) -> FileEntry {
        FileEntry(
            name: filename,
            path: RemotePath.join(dir, filename),
            size: attributes.size ?? 0,
            permissions: attributes.permissions,
            uid: attributes.uidgid?.userId,
            gid: attributes.uidgid?.groupId,
            modifiedAt: attributes.accessModificationTime?.modificationTime,
            kind: FilePermissions.kind(from: attributes.permissions, longname: longname)
        )
    }
}

/// Citadel `SFTPFile` 到 `RemoteFile` 句柄的适配。
final class CitadelRemoteFile: RemoteFile, @unchecked Sendable {
    private let file: SFTPFile

    init(file: SFTPFile) {
        self.file = file
    }

    func read(offset: UInt64, length: UInt32) async throws -> Data {
        let buffer = try await file.read(from: offset, length: length)
        return Data(buffer.readableBytesView)
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        try await file.write(buffer, at: offset)
    }

    func close() async throws {
        try await file.close()
    }
}
