import ConnKit
import ConnSSH
import Foundation

/// 下载 / 上传（chunked + 进度 + 断点续传）。
extension FileBrowserViewModel {
    private static let chunkSize: UInt32 = 64 * 1024

    /// 下载到本地临时目录。断点续传：`.connpart` 已存在则从其大小续读，完成后原子 rename。
    ///
    /// 安全性（#3）：断点文件按**完整远端路径**命名（不同目录的同名文件不再互相复用断点）；
    /// 断点大于远端大小（远端变小/换了内容）时从头来过；完成后校验大小==远端,不符不交付。
    func download(_ entry: FileEntry) async {
        transfer = FileTransferState(name: entry.name, direction: .download, progress: 0)
        defer { transfer = nil }
        let temp = FileManager.default.temporaryDirectory
        let destination = temp.appendingPathComponent(entry.name)
        let partial = temp.appendingPathComponent(Self.partialName(for: entry.path))
        do {
            // 断点若已 ≥ 远端大小（远端变小/变化），丢弃重下，避免拼接损坏。
            var offset = Self.fileSize(partial)
            if offset > entry.size {
                try? FileManager.default.removeItem(at: partial)
                offset = 0
            }
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() } // #15：任何路径都关闭，避免 fd 泄漏
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
                throw error // 断点保留以便续传
            }
            try handle.close()

            // 完整性校验：下完的字节数应等于远端大小；不符则保留断点、不交付损坏文件。
            guard Self.fileSize(partial) == entry.size else {
                actionMessage = L("下载不完整（大小不符），已保留断点可重试")
                return
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            downloadedURL = destination
        } catch {
            actionMessage = String(format: L("下载失败：%@（已保留断点，重试可续传）"), friendly(error))
        }
    }

    /// 断点文件名：由完整远端路径生成，避免不同目录同名文件冲突；过长时保留尾部。
    private static func partialName(for path: String) -> String {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        return String(sanitized.suffix(180)) + ".connpart"
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
            defer { try? localHandle.close() } // #15：任何路径都关闭
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
            actionMessage = String(format: L("上传失败：%@"), friendly(error))
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
