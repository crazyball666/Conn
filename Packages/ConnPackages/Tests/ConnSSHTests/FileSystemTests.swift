import Foundation
import Testing
@testable import ConnSSH

struct FilePermissionsTests {
    @Test("mode → rwx 串")
    func permissionString() {
        #expect(FilePermissions.string(from: 0o040755) == "rwxr-xr-x")
        #expect(FilePermissions.string(from: 0o100644) == "rw-r--r--")
        #expect(FilePermissions.string(from: 0o100600) == "rw-------")
        #expect(FilePermissions.string(from: nil) == "---------")
    }

    @Test("类型位判定")
    func kindDetection() {
        #expect(FilePermissions.kind(from: 0o040755) == .directory)
        #expect(FilePermissions.kind(from: 0o100644) == .file)
        #expect(FilePermissions.kind(from: 0o120777) == .symlink)
        // mode 缺失回退 longname
        #expect(FilePermissions.kind(from: nil, longname: "drwxr-xr-x 2 root") == .directory)
        #expect(FilePermissions.kind(from: nil, longname: "-rw-r--r-- 1 root") == .file)
    }

    @Test("八进制解析")
    func octalParse() {
        #expect(FilePermissions.mode(fromOctal: "755") == 0o755)
        #expect(FilePermissions.mode(fromOctal: "644") == 0o644)
        #expect(FilePermissions.mode(fromOctal: "xyz") == nil)
    }
}

struct RemotePathTests {
    @Test("join")
    func join() {
        #expect(RemotePath.join("/", "etc") == "/etc")
        #expect(RemotePath.join("/home", "deploy") == "/home/deploy")
        #expect(RemotePath.join("/home/", "deploy") == "/home/deploy")
    }

    @Test("parent")
    func parent() {
        #expect(RemotePath.parent("/home/deploy") == "/home")
        #expect(RemotePath.parent("/etc") == "/")
        #expect(RemotePath.parent("/") == "/")
        #expect(RemotePath.parent("/home/deploy/") == "/home")
    }

    @Test("lastComponent")
    func lastComponent() {
        #expect(RemotePath.lastComponent("/home/deploy/config.yml") == "config.yml")
        #expect(RemotePath.lastComponent("/etc") == "etc")
        #expect(RemotePath.lastComponent("/") == "/")
    }
}

struct MockRemoteFileSystemTests {
    @Test("列目录：目录优先、按名排序")
    func listSorted() async throws {
        let fileSystem = MockRemoteFileSystem()
        let entries = try await fileSystem.list("/home/deploy")
        #expect(entries.contains { $0.name == "app" && $0.isDirectory })
        #expect(entries.contains { $0.name == ".bashrc" && !$0.isDirectory })
        // 目录排在文件前
        let firstFileIndex = entries.firstIndex { !$0.isDirectory } ?? 0
        let lastDirIndex = entries.lastIndex { $0.isDirectory } ?? 0
        #expect(lastDirIndex < firstFileIndex || entries.allSatisfy(\.isDirectory))
    }

    @Test("读写往返 + 权限保留")
    func readWriteRoundtrip() async throws {
        let fileSystem = MockRemoteFileSystem()
        let original = try await fileSystem.stat("/etc/nginx/nginx.conf")
        try await fileSystem.writeAll(Data("new content\n".utf8), to: "/etc/nginx/nginx.conf")
        let read = try await fileSystem.readAll("/etc/nginx/nginx.conf")
        #expect(read == Data("new content\n".utf8))
        // 覆写既有文件权限不变
        let after = try await fileSystem.stat("/etc/nginx/nginx.conf")
        #expect(after.permissions == original.permissions)
    }

    @Test("断点续传：分两次 offset 写入拼成完整内容")
    func resumeWrite() async throws {
        let fileSystem = MockRemoteFileSystem()
        let file = try await fileSystem.open("/tmp/part.bin", mode: .writeCreate)
        try await file.write(Data("hello ".utf8), at: 0)
        try await file.write(Data("world".utf8), at: 6)
        try await file.close()
        let content = try await fileSystem.readAll("/tmp/part.bin")
        #expect(content == Data("hello world".utf8))
    }

    @Test("mkdir / rename / remove")
    func directoryOps() async throws {
        let fileSystem = MockRemoteFileSystem()
        try await fileSystem.createDirectory("/home/deploy/new")
        #expect(try await fileSystem.stat("/home/deploy/new").isDirectory)

        try await fileSystem.rename("/home/deploy/new", to: "/home/deploy/renamed")
        let entries = try await fileSystem.list("/home/deploy")
        #expect(entries.contains { $0.name == "renamed" })
        #expect(!entries.contains { $0.name == "new" })

        try await fileSystem.removeDirectory("/home/deploy/renamed")
        #expect(!(try await fileSystem.list("/home/deploy")).contains { $0.name == "renamed" })
    }

    @Test("chmod 只改权限位、保留类型位")
    func chmod() async throws {
        let fileSystem = MockRemoteFileSystem()
        try await fileSystem.setPermissions(0o600, path: "/etc/nginx/nginx.conf")
        let entry = try await fileSystem.stat("/etc/nginx/nginx.conf")
        #expect(entry.permissionString == "rw-------")
        #expect(entry.kind == .file) // 类型位没被破坏
    }

    @Test("读不存在的文件抛错")
    func readMissing() async throws {
        let fileSystem = MockRemoteFileSystem()
        await #expect(throws: SFTPFileError.self) {
            try await fileSystem.readAll("/nope/missing.txt")
        }
    }
}
