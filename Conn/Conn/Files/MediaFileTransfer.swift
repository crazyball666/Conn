import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// PhotosPicker 的视频/图片文件表示：让系统把媒体复制到临时 URL，
/// 避免把整段视频读入内存后再交给上传器。
struct MediaFileTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            MediaFileTransfer(url: try copyToTemporaryFile(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            MediaFileTransfer(url: try copyToTemporaryFile(received.file))
        }
    }

    private static func copyToTemporaryFile(_ source: URL) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-media-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
