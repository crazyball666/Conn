import ConnSSH
import ConnTerminal
import Foundation
import Testing

private final class HostSaveCrashTestChannel: ShellChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func write(_ bytes: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func close() async { continuation.finish() }
}

@Suite("主机保存后的终端元数据同步")
@MainActor
struct TerminalSessionHostSaveCrashTests {
    @Test("活动终端存在时可反复刷新指定主机名")
    func refreshesHostNameWithoutInvalidatingSessionStorage() {
        let store = TerminalSessionStore()
        for index in 0 ..< 32 {
            store.add(TerminalTab(
                id: "tab-\(index)",
                hostID: "host-\(index)",
                hostName: "主机-\(index)",
                session: TerminalSession(channel: HostSaveCrashTestChannel())
            ))
        }

        for revision in 0 ..< 1_000 {
            store.refreshHostName(hostID: "host-16", name: "生产主机-\(revision)")
        }

        #expect(store.tabs.count == 32)
        #expect(store.tab(id: "tab-16")?.hostName == "生产主机-999")
        #expect(store.tab(id: "tab-15")?.hostName == "主机-15")
    }
}
