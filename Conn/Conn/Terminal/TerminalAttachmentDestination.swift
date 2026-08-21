import ConnSSH
import Foundation

enum TerminalAttachmentDestinationError: Error, Equatable {
    case unsafePath
}

enum TerminalAttachmentDestinationResolver {
    static func resolve(
        providerWorkingDirectory: String?,
        accountHome: String,
        date: Date = Date()
    ) throws -> String {
        if let providerWorkingDirectory,
           isSafeAbsolutePath(providerWorkingDirectory) {
            return providerWorkingDirectory
        }
        guard isSafeAbsolutePath(accountHome) else {
            throw TerminalAttachmentDestinationError.unsafePath
        }
        return RemotePath.join(
            RemotePath.join(
                RemotePath.join(accountHome, ".conn"),
                "uploads"
            ),
            day(date)
        )
    }

    static func isSafeAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
