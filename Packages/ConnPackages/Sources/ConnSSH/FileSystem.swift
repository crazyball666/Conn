import Foundation

/// 远端文件类型。
///
/// `Comparable` 顺序：directory < file < symlink < other——文件管理器按「类型」
/// 排序时把目录集中到一段，便于一眼看结构（ViewModel 排序会再叠加「目录永远在前」）。
public enum FileKind: Sendable, Equatable, Comparable {
    case directory, file, symlink, other
}

/// 远端一个文件/目录条目（SFTP，方案 §4.5）。
public struct FileEntry: Identifiable, Sendable, Equatable, Hashable {
    public let name: String
    /// 绝对路径。
    public let path: String
    public let size: UInt64
    /// 完整 POSIX mode（含类型位）。nil 表示服务器未返回。
    public let permissions: UInt32?
    public let uid: UInt32?
    public let gid: UInt32?
    public let modifiedAt: Date?
    public let kind: FileKind

    public var id: String {
        path
    }

    public var isDirectory: Bool {
        kind == .directory
    }

    public var isSymlink: Bool {
        kind == .symlink
    }

    public var isHidden: Bool {
        name.hasPrefix(".")
    }

    /// 权限 rwx 串（不含类型位），如 `rwxr-xr-x`。
    public var permissionString: String {
        FilePermissions.string(from: permissions)
    }

    /// 八进制权限串，如 `755`。nil 无信息。
    public var octalPermissions: String? {
        permissions.map { String($0 & 0o777, radix: 8) }
    }

    public init(
        name: String,
        path: String,
        size: UInt64,
        permissions: UInt32?,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        modifiedAt: Date? = nil,
        kind: FileKind
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.permissions = permissions
        self.uid = uid
        self.gid = gid
        self.modifiedAt = modifiedAt
        self.kind = kind
    }
}

/// POSIX 权限工具。纯函数、host 可测。
public enum FilePermissions {
    public static let typeMask: UInt32 = 0o170000
    public static let directoryBit: UInt32 = 0o040000
    public static let symlinkBit: UInt32 = 0o120000
    public static let regularBit: UInt32 = 0o100000

    /// 由 mode 判类型；mode 缺失时回退 `ls -l` longname 首字符。
    public static func kind(from mode: UInt32?, longname: String? = nil) -> FileKind {
        if let mode {
            switch mode & typeMask {
            case directoryBit: return .directory
            case symlinkBit: return .symlink
            case regularBit: return .file
            default: break
            }
        }
        switch longname?.first {
        case "d": return .directory
        case "l": return .symlink
        case "-": return .file
        default: return .other
        }
    }

    /// mode → `rwxr-xr-x`。缺失返回 `---------`。
    public static func string(from mode: UInt32?) -> String {
        guard let mode else { return "---------" }
        func rwx(_ part: UInt32) -> String {
            let read = part & 0o4 != 0 ? "r" : "-"
            let write = part & 0o2 != 0 ? "w" : "-"
            let exec = part & 0o1 != 0 ? "x" : "-"
            return read + write + exec
        }
        let bits = mode & 0o777
        return rwx((bits >> 6) & 0o7) + rwx((bits >> 3) & 0o7) + rwx(bits & 0o7)
    }

    /// 八进制字符串（如 `"755"`）→ mode 位，非法返回 nil。
    public static func mode(fromOctal text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 4, let value = UInt32(trimmed, radix: 8) else { return nil }
        return value
    }
}

/// 远端路径工具（POSIX 正斜杠）。纯函数、host 可测。
public enum RemotePath {
    public static func join(_ base: String, _ component: String) -> String {
        if base == "/" {
            return "/" + component
        }
        return base.hasSuffix("/") ? base + component : base + "/" + component
    }

    public static func parent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let index = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<index])
        return parent.isEmpty ? "/" : parent
    }

    public static func lastComponent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? "/"
    }
}

/// 一个打开的远端文件句柄，支持 offset 读写（断点续传的基础）。
public protocol RemoteFile: Sendable {
    /// 从 offset 读至多 length 字节；返回空 Data 表示 EOF。
    func read(offset: UInt64, length: UInt32) async throws -> Data
    /// 在 offset 处写入。
    func write(_ data: Data, at offset: UInt64) async throws
    func close() async throws
}

public enum RemoteFileMode: Sendable {
    /// 只读。
    case read
    /// 写既有文件（保留 inode/权限），配合截断。
    case write
    /// 新建或截断。
    case writeCreate
}

/// 远端文件系统抽象（SFTP，方案 §4.5）。Citadel 与 Mock 各实现。
public protocol RemoteFileSystem: Sendable {
    func list(_ path: String) async throws -> [FileEntry]
    func stat(_ path: String) async throws -> FileEntry
    func open(_ path: String, mode: RemoteFileMode) async throws -> any RemoteFile
    /// Opens a file and requests its mode as part of creation when the transport supports it.
    /// The default implementation fails closed before returning the handle if chmod fails.
    func open(
        _ path: String,
        mode: RemoteFileMode,
        creationPermissions: UInt32?
    ) async throws -> any RemoteFile
    func createDirectory(_ path: String) async throws
    func remove(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
    func setPermissions(_ mode: UInt32, path: String) async throws
    func realPath(_ path: String) async throws -> String
    func close() async
}

public extension RemoteFileSystem {
    func open(
        _ path: String,
        mode: RemoteFileMode,
        creationPermissions: UInt32?
    ) async throws -> any RemoteFile {
        let file = try await open(path, mode: mode)
        guard case .writeCreate = mode, let creationPermissions else { return file }
        do {
            try await setPermissions(creationPermissions & 0o7777, path: path)
            return file
        } catch {
            try? await file.close()
            try? await remove(path)
            throw error
        }
    }

    /// 读全文件（小文件 / 编辑用）。分块累计，避免一次巨读。
    func readAll(_ path: String) async throws -> Data {
        let file = try await open(path, mode: .read)
        do {
            var data = Data()
            var offset: UInt64 = 0
            while true {
                let piece = try await file.read(offset: offset, length: 32 * 1024)
                if piece.isEmpty {
                    break
                }
                data.append(piece)
                offset += UInt64(piece.count)
            }
            try await file.close()
            return data
        } catch {
            try? await file.close()
            throw error
        }
    }

    /// 写全文件（新建/覆盖）。
    func writeAll(_ data: Data, to path: String) async throws {
        let file = try await open(path, mode: .writeCreate)
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + 32 * 1024, data.count)
                let chunk = data.subdata(in: (data.startIndex + offset) ..< (data.startIndex + end))
                try await file.write(chunk, at: UInt64(offset))
                offset = end
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    /// 把完整内容先写到目标同目录的唯一临时文件，再发布到最终路径。
    ///
    /// 同目录保证 rename 不跨文件系统。目标已存在时，发布过程先把原文件移动到
    /// 唯一备份路径；临时文件 rename 失败则立即把备份移回目标，避免原文件丢失。
    func writeFileSafely(
        to destinationPath: String,
        fallbackPermissions: UInt32? = nil,
        writeTemporary: (String) async throws -> Void
    ) async throws {
        let temporaryPath = temporarySiblingPath(of: destinationPath, suffix: "tmp")
        let permissions = await (try? stat(destinationPath).permissions) ?? fallbackPermissions

        do {
            try await writeTemporary(temporaryPath)
            if let permissions {
                try await setPermissions(permissions & 0o7777, path: temporaryPath)
            }
            try Task.checkCancellation()
            try await replaceFile(at: destinationPath, with: temporaryPath)
        } catch {
            try? await remove(temporaryPath)
            throw error
        }
    }

    /// 发布一个已经完整写好的同目录临时文件。
    func replaceFile(at destinationPath: String, with temporaryPath: String) async throws {
        guard try await itemExists(destinationPath) else {
            try await rename(temporaryPath, to: destinationPath)
            return
        }

        let backupPath = temporarySiblingPath(of: destinationPath, suffix: "backup")
        try await rename(destinationPath, to: backupPath)
        do {
            try await rename(temporaryPath, to: destinationPath)
        } catch {
            let replacementError = error
            do {
                try await rename(backupPath, to: destinationPath)
            } catch {
                throw RemoteFileRollbackError(
                    recoveryPath: backupPath,
                    replacementFailure: replacementError.friendlyDiagnosis,
                    rollbackFailure: error.friendlyDiagnosis
                )
            }
            throw replacementError
        }

        // 新文件已经发布成功；清理失败只会留下备份，不应把成功保存误报成失败。
        try? await remove(backupPath)
    }

    private func itemExists(_ path: String) async throws -> Bool {
        do {
            _ = try await stat(path)
            return true
        } catch let error as SFTPFileError {
            guard case .notFound = error else { throw error }
            return false
        } catch let error as SSHError {
            // SFTP v3 SSH_FX_NO_SUCH_FILE = 2。
            guard case let .sftpError(code, _) = error, code == 2 else { throw error }
            return false
        }
    }

    private func temporarySiblingPath(of destinationPath: String, suffix: String) -> String {
        RemotePath.join(
            RemotePath.parent(destinationPath),
            ".conn-\(UUID().uuidString).\(suffix)"
        )
    }
}

/// 原文件已安全移动到备份，但发布失败后的自动回滚也失败。
/// `recoveryPath` 明确保留原始数据所在位置，调用方不得删除该路径。
public struct RemoteFileRollbackError: LocalizedError, Sendable {
    public let recoveryPath: String
    public let replacementFailure: String
    public let rollbackFailure: String

    public var errorDescription: String? {
        "Remote replacement failed and rollback could not restore the original file. "
            + "Original data remains at \(recoveryPath). Replacement: \(replacementFailure). "
            + "Rollback: \(rollbackFailure)."
    }

    public init(recoveryPath: String, replacementFailure: String, rollbackFailure: String) {
        self.recoveryPath = recoveryPath
        self.replacementFailure = replacementFailure
        self.rollbackFailure = rollbackFailure
    }
}
