import Foundation
import Testing
@testable import ConnSSH

@Suite("RemoteUploadService")
struct RemoteUploadServiceTests {
    @Test("生成可读、无空格且保留扩展名的远端文件名")
    func safeRemoteName() {
        let naming = RemoteUploadNaming(
            now: { Date(timeIntervalSince1970: 1_787_313_845) },
            suffix: { "A1B2C3D4" }
        )

        #expect(
            naming.remoteName(for: "产品 截图 (最终版).PNG")
                == "20260821-120405-A1B2C3D4-产品-截图-最终版.png"
        )
    }

    @Test("流式上传完整发布文件并设置私有权限")
    func uploadsWithPrivatePermissions() async throws {
        let source = try temporaryFile(named: "screen shot.png", data: Data((0 ..< 200_000).map { UInt8($0 % 251) }))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fileSystem = MockRemoteFileSystem(seeds: [
            .init(path: "/home", kind: .directory),
            .init(path: "/home/deploy", kind: .directory)
        ])
        let service = RemoteUploadService(
            chunkSize: 16 * 1024,
            naming: RemoteUploadNaming(
                now: { Date(timeIntervalSince1970: 1_787_313_845) },
                suffix: { "11223344" }
            )
        )
        let progress = ProgressRecorder()

        let receipt = try await service.upload(
            localURL: source,
            originalName: "screen shot.png",
            to: "/home/deploy/.conn/uploads/2026-08-21",
            using: fileSystem,
            onProgress: { value in await progress.append(value) }
        )

        #expect(receipt.remotePath == "/home/deploy/.conn/uploads/2026-08-21/20260821-120405-11223344-screen-shot.png")
        #expect(receipt.byteCount == 200_000)
        #expect(try await fileSystem.readAll(receipt.remotePath) == Data((0 ..< 200_000).map { UInt8($0 % 251) }))
        #expect(try await fileSystem.stat(receipt.remotePath).permissionString == "rw-------")
        #expect(try await fileSystem.stat("/home/deploy/.conn").permissionString == "rwx------")
        let values = await progress.values
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("file management can preserve the exact original destination name")
    func preservesCallerSelectedName() async throws {
        let source = try temporaryFile(named: "local.txt", data: Data("replacement".utf8))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fileSystem = MockRemoteFileSystem(seeds: [
            .init(path: "/files", kind: .directory),
            .init(path: "/files/report final.txt", kind: .file, content: "old")
        ])

        let receipt = try await RemoteUploadService().upload(
            localURL: source,
            originalName: "report final.txt",
            remoteName: "report final.txt",
            to: "/files",
            using: fileSystem
        )

        #expect(receipt.remotePath == "/files/report final.txt")
        #expect(try await fileSystem.readAll(receipt.remotePath) == Data("replacement".utf8))
    }

    @Test("取消上传会移除临时文件且不会发布目标文件")
    func cancellationRemovesPartialUpload() async throws {
        let source = try temporaryFile(named: "large.bin", data: Data(repeating: 0x5A, count: 128 * 1024))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fileSystem = MockRemoteFileSystem(seeds: [
            .init(path: "/uploads", kind: .directory)
        ])
        let gate = UploadCancellationGate()
        let service = RemoteUploadService(chunkSize: 8 * 1024)

        let task = Task {
            try await service.upload(
                localURL: source,
                to: "/uploads",
                using: fileSystem,
                onProgress: { progress in
                    if progress > 0, progress < 1 {
                        await gate.pauseOnce()
                    }
                }
            )
        }

        await gate.waitUntilPaused()
        task.cancel()
        await gate.resume()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try await fileSystem.list("/uploads").isEmpty)
    }

    private func temporaryFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

private actor ProgressRecorder {
    private(set) var values: [Double] = []

    func append(_ value: Double) {
        values.append(value)
    }
}

private actor UploadCancellationGate {
    private var hasPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseOnce() async {
        guard !hasPaused else { return }
        hasPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !hasPaused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
