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
        do {
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
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    func stat(_ path: String) async throws -> FileEntry {
        do {
            let attributes = try await client.getAttributes(at: path)
            return Self.entry(filename: RemotePath.lastComponent(path),
                              dir: RemotePath.parent(path), attributes: attributes, longname: nil)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    func open(_ path: String, mode: RemoteFileMode) async throws -> any RemoteFile {
        do {
            let flags: SFTPOpenFileFlags = switch mode {
            case .read: .read
            case .write: [.write, .truncate]
            case .writeCreate: [.write, .create, .truncate]
            }
            let file = try await client.openFile(filePath: path, flags: flags)
            return CitadelRemoteFile(file: file)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    func createDirectory(_ path: String) async throws {
        do {
            try await client.createDirectory(atPath: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    func remove(_ path: String) async throws {
        do {
            try await client.remove(at: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    func removeDirectory(_ path: String) async throws {
        do {
            try await client.rmdir(at: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    func rename(_ path: String, to newPath: String) async throws {
        do {
            try await client.rename(at: path, to: newPath)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    func setPermissions(_ mode: UInt32, path: String) async throws {
        do {
            var attributes = SFTPFileAttributes()
            attributes.permissions = mode & 0o7777
            try await client.setAttributes(at: path, to: attributes)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    func realPath(_ path: String) async throws -> String {
        do {
            return try await client.getRealPath(atPath: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    func close() async {
        try? await client.close()
    }

    // MARK: - 错误映射

    /// Citadel `SFTPMessage.Status`（含服务器返回的 `errorCode` + `message`）→ 业务层 `SSHError`。
    /// 不在此层暴露 Citadel 类型——上层 ViewModel 只看 SSHError。
    /// `message` 透传服务器原文，**不在客户端翻译**（i18n 边界：Conn 的产品文案本地化，
    /// 服务器消息是远端事实，由服务器自己负责语言）。
    private static func mapSFTPError(_ error: Error, path: String) -> Error {
        guard let status = error as? SFTPMessage.Status else { return error }
        let message = status.message.isEmpty ? status.errorCode.debugDescription : status.message
        return SSHError.sftpError(code: status.errorCode.rawValue, message: message)
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
