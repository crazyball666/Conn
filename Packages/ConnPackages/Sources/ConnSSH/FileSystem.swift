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

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }
    public var isSymlink: Bool { kind == .symlink }
    public var isHidden: Bool { name.hasPrefix(".") }

    /// 权限 rwx 串（不含类型位），如 `rwxr-xr-x`。
    public var permissionString: String { FilePermissions.string(from: permissions) }
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
        if base == "/" { return "/" + component }
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
    func createDirectory(_ path: String) async throws
    func remove(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
    func setPermissions(_ mode: UInt32, path: String) async throws
    func realPath(_ path: String) async throws -> String
    func close() async
}

public extension RemoteFileSystem {
    /// 读全文件（小文件 / 编辑用）。分块累计，避免一次巨读。
    func readAll(_ path: String) async throws -> Data {
        let file = try await open(path, mode: .read)
        do {
            var data = Data()
            var offset: UInt64 = 0
            while true {
                let piece = try await file.read(offset: offset, length: 32 * 1024)
                if piece.isEmpty { break }
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
}
