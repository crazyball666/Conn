import ConnAnalytics
import ConnKit
import ConnSSH
import ConnTerminal
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
                    if chunk.isEmpty {
                        break
                    }
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
                trackTransfer(direction: "download", size: entry.size, result: "failure", errorCategory: "incomplete")
                return
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            downloadedURL = destination
            trackTransfer(direction: "download", size: entry.size, result: "success")
        } catch {
            trackTransfer(
                direction: "download",
                size: entry.size,
                result: "failure",
                errorCategory: Analytics.errorCategory(error)
            )
            actionMessage = String(format: L("下载失败：%@（已保留断点，重试可续传）"), error.friendlyDiagnosis)
        }
    }

    /// 断点文件名：由完整远端路径生成，避免不同目录同名文件冲突；过长时保留尾部。
    private static func partialName(for path: String) -> String {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        return String(sanitized.suffix(180)) + ".connpart"
    }

    /// 从照片或视频选择器上传到当前目录。媒体以临时文件表示，避免整段视频驻留内存。
    func uploadMedia(_ items: [PhotosPickerItem]) async {
        guard transfer == nil, !isMediaUploading else {
            actionMessage = L("已有上传任务正在进行")
            return
        }
        isMediaUploading = true
        defer { isMediaUploading = false }
        for item in items {
            guard !Task.isCancelled else { return }
            do {
                guard let media = try await item.loadTransferable(type: MediaFileTransfer.self) else {
                    actionMessage = L("无法读取所选照片或视频。")
                    continue
                }
                await upload(from: media.url, reloadAfter: false, allowWhileMediaBatch: true)
                try? FileManager.default.removeItem(at: media.url)
            } catch is CancellationError {
                return
            } catch {
                actionMessage = String(format: L("上传失败：%@"), error.friendlyDiagnosis)
            }
        }
        await refresh()
    }

    /// 从本地文件上传到当前目录（流式读本地，避免整包载入内存）。
    func upload(
        from localURL: URL,
        reloadAfter: Bool = true,
        allowWhileMediaBatch: Bool = false
    ) async {
        guard allowWhileMediaBatch || (!isMediaUploading && transfer == nil) else {
            actionMessage = L("已有上传任务正在进行")
            return
        }
        let name = localURL.lastPathComponent
        let size = Self.fileSize(localURL)
        transfer = FileTransferState(name: name, direction: .upload, progress: 0)
        defer { transfer = nil }
        do {
            let fileSystem = try await filesystem()
            _ = try await uploadService.upload(
                localURL: localURL,
                originalName: name,
                remoteName: name,
                to: currentPath,
                using: fileSystem,
                onProgress: { [weak self] progress in
                    await self?.setUploadProgress(progress)
                }
            )
            if reloadAfter {
                await load()
            }
            trackTransfer(direction: "upload", size: size, result: "success")
        } catch {
            trackTransfer(
                direction: "upload",
                size: size,
                result: "failure",
                errorCategory: Analytics.errorCategory(error)
            )
            actionMessage = String(format: L("上传失败：%@"), error.friendlyDiagnosis)
        }
    }

    private func trackTransfer(
        direction: String,
        size: UInt64,
        result: String,
        errorCategory: String? = nil
    ) {
        var properties: [AnalyticsProperty: String] = [
            .direction: direction,
            .sizeBucket: Analytics.sizeBucket(size),
            .result: result,
        ]
        if let errorCategory {
            properties[.errorCategory] = errorCategory
        }
        Analytics.shared.track(.fileTransferFinished, properties)
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func setUploadProgress(_ progress: Double) {
        transfer?.progress = progress
    }
}
