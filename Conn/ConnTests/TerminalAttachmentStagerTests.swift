@testable import Conn
import Foundation
import Testing

@Suite("Terminal attachment staging")
struct TerminalAttachmentStagerTests {
    @Test("staging preserves original bytes and preferred extension")
    func stagesOriginalData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-stager-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])

        let staged = try await TerminalAttachmentStager.stage(
            data: data,
            preferredFileExtension: "JPEG",
            baseName: "photo",
            directory: directory
        )

        #expect(staged.originalName.hasPrefix("photo-"))
        #expect(staged.originalName.hasSuffix(".jpeg"))
        #expect(try Data(contentsOf: staged.url) == data)
    }

    @Test("staging infers PNG when no extension is supplied")
    func infersImageExtension() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-stager-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

        let staged = try await TerminalAttachmentStager.stage(
            data: data,
            preferredFileExtension: nil,
            baseName: "image",
            directory: directory
        )

        #expect(staged.originalName.hasSuffix(".png"))
    }
}
