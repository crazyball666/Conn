import Foundation

/// 一颗内存文件树的种子（演示/测试用）。
public struct MockFileSeed: Sendable {
    public let path: String
    public let kind: FileKind
    public let content: String
    public let permissions: UInt32

    public init(path: String, kind: FileKind, content: String = "", permissions: UInt32? = nil) {
        self.path = path
        self.kind = kind
        self.content = content
        self.permissions = permissions ?? (kind == .directory ? 0o040755 : 0o100644)
    }

    /// 一颗像样的 Linux 文件树，演示模式直接可逛。
    public static let defaultTree: [MockFileSeed] = [
        .init(path: "/home", kind: .directory),
        .init(path: "/home/deploy", kind: .directory),
        .init(path: "/home/deploy/.bashrc", kind: .file, content: "export PATH=$PATH:/usr/local/bin\nalias ll='ls -la'\n"),
        .init(path: "/home/deploy/app", kind: .directory),
        .init(path: "/home/deploy/app/config.yml", kind: .file, content: "server:\n  port: 8080\n  workers: 4\n"),
        .init(path: "/home/deploy/app/app.log", kind: .file, content: "[info] started\n[warn] cache miss\n[info] ok\n"),
        .init(path: "/home/deploy/deploy.sh", kind: .file,
              content: "#!/bin/bash\nset -e\ngit pull\ndocker compose up -d\n", permissions: 0o100755),
        .init(path: "/etc", kind: .directory),
        .init(path: "/etc/hostname", kind: .file, content: "web-01\n"),
        .init(path: "/etc/nginx", kind: .directory),
        .init(path: "/etc/nginx/nginx.conf", kind: .file,
              content: "user www-data;\nworker_processes auto;\nhttp {\n    server {\n        listen 80;\n    }\n}\n"),
        .init(path: "/var", kind: .directory),
        .init(path: "/var/log", kind: .directory),
        .init(path: "/var/log/syslog", kind: .file, content: "Jul 23 09:14 web-01 systemd[1]: Started.\n")
    ]
}

/// 内存实现的 `RemoteFileSystem`（演示模式与测试复用）。
///
/// 用 actor 保证并发读写文件树安全。默认载入一颗像样的 Linux 树。
public actor MockRemoteFileSystem: RemoteFileSystem {
    private struct Node {
        var kind: FileKind
        var data: Data
        var permissions: UInt32
        var modifiedAt: Date
    }

    private var nodes: [String: Node]
    // 固定时间戳，保证测试确定性。
    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    public init(seeds: [MockFileSeed] = MockFileSeed.defaultTree) {
        var built: [String: Node] = [
            "/": Node(kind: .directory, data: Data(), permissions: 0o040755, modifiedAt: Self.referenceDate)
        ]
        for seed in seeds {
            Self.addAncestors(of: seed.path, into: &built)
            built[seed.path] = Node(
                kind: seed.kind,
                data: Data(seed.content.utf8),
                permissions: seed.permissions,
                modifiedAt: Self.referenceDate
            )
        }
        nodes = built
    }

    /// 补齐路径的所有祖先目录。静态、操作 inout 字典——init 与 async 方法共用。
    private static func addAncestors(of path: String, into nodes: inout [String: Node]) {
        var current = RemotePath.parent(path)
        while current != "/" {
            if nodes[current] == nil {
                nodes[current] = Node(kind: .directory, data: Data(), permissions: 0o040755, modifiedAt: referenceDate)
            }
            current = RemotePath.parent(current)
        }
    }

    // MARK: - RemoteFileSystem

    public func list(_ path: String) async throws -> [FileEntry] {
        let base = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        guard nodes[base]?.kind == .directory else { throw SFTPFileError.notFound(base) }
        return nodes.keys
            .filter { RemotePath.parent($0) == base && $0 != "/" }
            .compactMap { entry(at: $0) }
            .sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory : lhs.name < rhs.name
            }
    }

    public func stat(_ path: String) async throws -> FileEntry {
        guard let entry = entry(at: path) else { throw SFTPFileError.notFound(path) }
        return entry
    }

    public func open(_ path: String, mode: RemoteFileMode) async throws -> any RemoteFile {
        switch mode {
        case .read:
            guard nodes[path]?.kind == .file else { throw SFTPFileError.notFound(path) }
        case .write:
            guard nodes[path] != nil else { throw SFTPFileError.notFound(path) }
        case .writeCreate:
            let permissions = nodes[path]?.permissions ?? 0o100644
            Self.addAncestors(of: path, into: &nodes)
            nodes[path] = Node(kind: .file, data: Data(), permissions: permissions, modifiedAt: Self.referenceDate)
        }
        return MockRemoteFile(fileSystem: self, path: path)
    }

    public func createDirectory(_ path: String) async throws {
        guard nodes[path] == nil else { throw SFTPFileError.alreadyExists(path) }
        Self.addAncestors(of: path, into: &nodes)
        nodes[path] = Node(kind: .directory, data: Data(), permissions: 0o040755, modifiedAt: Self.referenceDate)
    }

    public func remove(_ path: String) async throws {
        guard nodes[path] != nil else { throw SFTPFileError.notFound(path) }
        nodes[path] = nil
    }

    public func removeDirectory(_ path: String) async throws {
        guard nodes[path]?.kind == .directory else { throw SFTPFileError.notFound(path) }
        // 递归删子项（Mock 简化；真实 SFTP rmdir 要求空目录）
        for key in nodes.keys where key == path || key.hasPrefix(path + "/") {
            nodes[key] = nil
        }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        guard let node = nodes[path] else { throw SFTPFileError.notFound(path) }
        Self.addAncestors(of: newPath, into: &nodes)
        nodes[newPath] = node
        nodes[path] = nil
        // #13：目录改名要连同所有子孙一起重挂，否则子项被孤立、目录内容“消失”。
        if node.kind == .directory {
            let prefix = path + "/"
            for key in nodes.keys where key.hasPrefix(prefix) {
                nodes[newPath + "/" + String(key.dropFirst(prefix.count))] = nodes[key]
                nodes[key] = nil
            }
        }
    }

    public func setPermissions(_ mode: UInt32, path: String) async throws {
        guard var node = nodes[path] else { throw SFTPFileError.notFound(path) }
        // 保留类型位，只改权限位
        node.permissions = (node.permissions & FilePermissions.typeMask) | (mode & 0o7777)
        nodes[path] = node
    }

    public func realPath(_ path: String) async throws -> String { path }

    public func close() async {}

    // MARK: - 供 MockRemoteFile 回调

    func readData(_ path: String, offset: UInt64, length: UInt32) throws -> Data {
        guard let node = nodes[path], node.kind == .file else { throw SFTPFileError.notFound(path) }
        let start = Int(offset)
        guard start < node.data.count else { return Data() }
        let end = min(start + Int(length), node.data.count)
        return node.data.subdata(in: (node.data.startIndex + start) ..< (node.data.startIndex + end))
    }

    func writeData(_ path: String, data: Data, at offset: UInt64) throws {
        guard var node = nodes[path] else { throw SFTPFileError.notFound(path) }
        var buffer = node.data
        let start = Int(offset)
        if buffer.count < start { buffer.append(Data(count: start - buffer.count)) }
        let end = start + data.count
        if buffer.count < end { buffer.append(Data(count: end - buffer.count)) }
        buffer.replaceSubrange((buffer.startIndex + start) ..< (buffer.startIndex + end), with: data)
        node.data = buffer
        node.modifiedAt = Self.referenceDate
        nodes[path] = node
    }

    private func entry(at path: String) -> FileEntry? {
        guard let node = nodes[path] else { return nil }
        return FileEntry(
            name: RemotePath.lastComponent(path),
            path: path,
            size: UInt64(node.data.count),
            permissions: node.permissions,
            uid: 1000,
            gid: 1000,
            modifiedAt: node.modifiedAt,
            kind: node.kind
        )
    }
}

/// Mock 文件句柄：读写委托回文件系统 actor。
final class MockRemoteFile: RemoteFile {
    private let fileSystem: MockRemoteFileSystem
    private let path: String

    init(fileSystem: MockRemoteFileSystem, path: String) {
        self.fileSystem = fileSystem
        self.path = path
    }

    func read(offset: UInt64, length: UInt32) async throws -> Data {
        try await fileSystem.readData(path, offset: offset, length: length)
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        try await fileSystem.writeData(path, data: data, at: offset)
    }

    func close() async throws {}
}

/// Mock 文件系统错误。
public enum SFTPFileError: Error, Sendable, Equatable {
    case notFound(String)
    case alreadyExists(String)
}
