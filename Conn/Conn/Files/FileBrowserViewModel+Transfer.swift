import ConnKit
import ConnSSH
import Foundation

/// 下载 / 上传（chunked + 进度 + 断点续传）。
extension FileBrowserViewModel {
    private static let chunkSize: UInt32 = 64 * 1024

    /// 下载到本地临时目录。断点续传：`.connpart` 已存在则从其大小续读，完成后原子 rename。
    func download(_ entry: FileEntry) async {
        transfer = FileTransferState(name: entry.name, direction: .download, progress: 0)
        defer { transfer = nil }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
        let partial = destination.appendingPathExtension("connpart")
        do {
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            var offset = Self.fileSize(partial)
            try handle.seek(toOffset: offset)

            let file = try await filesystem().open(entry.path, mode: .read)
            let total = max(entry.size, 1)
            do {
                while true {
                    let chunk = try await file.read(offset: offset, length: Self.chunkSize)
                    if chunk.isEmpty { break }
                    try handle.write(contentsOf: chunk)
                    offset += UInt64(chunk.count)
                    transfer?.progress = min(1, Double(offset) / Double(total))
                }
                try await file.close()
            } catch {
                try? await file.close()
                try? handle.close()
                throw error // 保留 .connpart 以便续传
            }
            try handle.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            downloadedURL = destination
        } catch {
            actionMessage = "下载失败：\(friendly(error))（已保留断点，重试可续传）"
        }
    }

    /// 从本地文件上传到当前目录（流式读本地，避免整包载入内存）。
    func upload(from localURL: URL) async {
        let name = localURL.lastPathComponent
        transfer = FileTransferState(name: name, direction: .upload, progress: 0)
        defer { transfer = nil }
        let scoped = localURL.startAccessingSecurityScopedResource()
        defer { if scoped { localURL.stopAccessingSecurityScopedResource() } }
        do {
            let localHandle = try FileHandle(forReadingFrom: localURL)
            let total = max(Self.fileSize(localURL), 1)
            let remotePath = RemotePath.join(currentPath, name)
            let file = try await filesystem().open(remotePath, mode: .writeCreate)
            var offset: UInt64 = 0
            do {
                while true {
                    let chunk = try localHandle.read(upToCount: Int(Self.chunkSize)) ?? Data()
                    if chunk.isEmpty { break }
                    try await file.write(chunk, at: offset)
                    offset += UInt64(chunk.count)
                    transfer?.progress = min(1, Double(offset) / Double(total))
                }
                try await file.close()
                try localHandle.close()
            } catch {
                try? await file.close()
                try? localHandle.close()
                throw error
            }
            await load()
        } catch {
            actionMessage = "上传失败：\(friendly(error))"
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
