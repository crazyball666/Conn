import Foundation
import Testing
@testable import Conn

@Suite("Terminal attachment destination")
struct TerminalAttachmentDestinationTests {
    @Test("fresh provider directory wins without changing the host database model")
    func providerDirectoryWins() throws {
        #expect(try TerminalAttachmentDestinationResolver.resolve(
            providerWorkingDirectory: "/repo/conn",
            accountHome: "/home/deploy",
            date: Date(timeIntervalSince1970: 1_787_313_845)
        ) == "/repo/conn")
    }

    @Test("ordinary PTY and unsafe provider paths fall back to a dated private home directory")
    func homeFallback() throws {
        #expect(try TerminalAttachmentDestinationResolver.resolve(
            providerWorkingDirectory: nil,
            accountHome: "/home/deploy",
            date: Date(timeIntervalSince1970: 1_787_313_845)
        ) == "/home/deploy/.conn/uploads/2026-08-21")
        #expect(try TerminalAttachmentDestinationResolver.resolve(
            providerWorkingDirectory: "/repo\nunsafe",
            accountHome: "/home/deploy",
            date: Date(timeIntervalSince1970: 1_787_313_845)
        ) == "/home/deploy/.conn/uploads/2026-08-21")
    }

    @Test("an unsafe SFTP home path fails closed")
    func rejectsUnsafeHome() {
        #expect(throws: TerminalAttachmentDestinationError.unsafePath) {
            try TerminalAttachmentDestinationResolver.resolve(
                providerWorkingDirectory: nil,
                accountHome: "relative/home"
            )
        }
    }
}
