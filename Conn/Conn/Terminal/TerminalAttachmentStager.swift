import Foundation

struct TerminalStagedAttachment: Sendable, Equatable {
    nonisolated let url: URL
    nonisolated let originalName: String
}

/// Performs attachment file creation away from MainActor. Image bytes are preserved instead
/// of decoding and re-encoding full-resolution photos, reducing both latency and peak memory.
enum TerminalAttachmentStager {
    nonisolated static func stage(
        data: Data,
        preferredFileExtension: String?,
        baseName: String,
        directory: URL? = nil
    ) async throws -> TerminalStagedAttachment {
        guard !data.isEmpty else {
            throw TerminalAttachmentPreparationError.unsupportedImage
        }
        let fileExtension = cleanedExtension(preferredFileExtension) ?? inferredExtension(data)
        let destinationDirectory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-terminal-attachments", isDirectory: true)
        return try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            let name = "\(baseName)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
            let url = destinationDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return TerminalStagedAttachment(url: url, originalName: name)
        }.value
    }

    private nonisolated static func cleanedExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(10))
    }

    private nonisolated static func inferredExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "png"
        }
        if bytes.starts(with: Array("GIF8".utf8)) {
            return "gif"
        }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        {
            return "tif"
        }
        if bytes.count >= 12,
           String(decoding: bytes[4 ..< 8], as: UTF8.self) == "ftyp"
        {
            let brand = String(decoding: bytes[8 ..< 12], as: UTF8.self)
            if ["heic", "heix", "hevc", "mif1"].contains(brand) {
                return "heic"
            }
        }
        if bytes.count >= 12,
           String(decoding: bytes[0 ..< 4], as: UTF8.self) == "RIFF",
           String(decoding: bytes[8 ..< 12], as: UTF8.self) == "WEBP"
        {
            return "webp"
        }
        return "img"
    }
}
