import ConnCrypto
import ConnEntitlement
import ConnKit
import ConnMonitor
import ConnRunner
import ConnSSH
import ConnTerminal
import Foundation
import Testing
@testable import Conn

@Suite("远程文件写入完整性")
@MainActor
struct RemoteFileIntegrityTests {
    @Test("编辑保存替换失败时保留原文件")
    func editorSaveReplacementFailurePreservesOriginal() async throws {
        let path = "/etc/service.conf"
        let original = Data("original=true\n".utf8)
        let fileSystem = FaultInjectingFileSystem(
            seeds: [path: original],
            replacementTarget: path
        )
        let dependencies = makeDependencies(fileSystem: fileSystem)
        let entry = FileEntry(
            name: "service.conf",
            path: path,
            size: UInt64(original.count),
            permissions: 0o100640,
            kind: .file
        )
        let viewModel = FileEditorViewModel(
            host: Self.host,
            dependencies: dependencies,
            entry: entry
        )

        await viewModel.load()
        viewModel.content = "original=false\n"
        await viewModel.save()

        #expect(try await fileSystem.readAll(path) == original)
    }

    @Test("上传中断时保留已有同名远端文件")
    func interruptedUploadPreservesExistingDestination() async throws {
        let original = Data("published payload\n".utf8)
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-upload-integrity-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let localURL = localDirectory.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: 128 * 1024).write(to: localURL)

        let destination = "/payload.bin"
        let fileSystem = FaultInjectingFileSystem(
            seeds: [destination: original],
            failWritesStartingAt: 64 * 1024
        )
        let viewModel = FileBrowserViewModel(
            host: Self.host,
            dependencies: makeDependencies(fileSystem: fileSystem)
        )

        await viewModel.upload(from: localURL)

        #expect(try await fileSystem.readAll(destination) == original)
    }

    @Test("文件浏览器首次加载使用终端初始目录")
    func fileBrowserLoadsConfiguredInitialPath() async {
        let fileSystem = FaultInjectingFileSystem(
            seeds: ["/home/deploy/.profile": Data()]
        )
        let viewModel = FileBrowserViewModel(
            host: Self.host,
            dependencies: makeDependencies(fileSystem: fileSystem)
        )

        viewModel.setInitialPathIfNeeded("/home/deploy")
        await viewModel.loadIfNeeded()

        #expect(viewModel.currentPath == "/home/deploy")
        #expect(viewModel.loadState == .ready)
    }

    @Test("文件浏览器加载后不覆盖用户当前目录")
    func fileBrowserDoesNotOverwriteLoadedPath() async {
        let fileSystem = FaultInjectingFileSystem(
            seeds: ["/home/readme": Data()]
        )
        let viewModel = FileBrowserViewModel(
            host: Self.host,
            dependencies: makeDependencies(fileSystem: fileSystem)
        )

        viewModel.setInitialPathIfNeeded("/home")
        await viewModel.loadIfNeeded()
        viewModel.setInitialPathIfNeeded("/")

        #expect(viewModel.currentPath == "/home")
    }

    @Test("终端目录失效时首次加载回退根目录")
    func fileBrowserFallsBackToRootAfterInitialPathFailure() async {
        let fileSystem = FaultInjectingFileSystem(
            seeds: [:],
            failingListPaths: ["/home/deleted"]
        )
        let viewModel = FileBrowserViewModel(
            host: Self.host,
            dependencies: makeDependencies(fileSystem: fileSystem)
        )

        viewModel.setInitialPathIfNeeded("/home/deleted")
        await viewModel.loadIfNeeded()

        #expect(viewModel.currentPath == "/")
        #expect(viewModel.loadState == .ready)
    }

    @Test("根目录也失败时保留文件浏览器错误状态")
    func fileBrowserKeepsRootFailure() async {
        let fileSystem = FaultInjectingFileSystem(
            seeds: [:],
            failingListPaths: ["/home/deleted", "/"]
        )
        let viewModel = FileBrowserViewModel(
            host: Self.host,
            dependencies: makeDependencies(fileSystem: fileSystem)
        )

        viewModel.setInitialPathIfNeeded("/home/deleted")
        await viewModel.loadIfNeeded()

        if case .failed = viewModel.loadState {
            #expect(true)
        } else {
            Issue.record("expected root listing failure")
        }
    }

    @Test("重新打开终端文件页前清理遗留操作提示")
    func fileBrowserResetsTransientPresentationState() {
        let viewModel = FileBrowserViewModel(
            host: Self.host,
            dependencies: makeDependencies(fileSystem: FaultInjectingFileSystem(seeds: [:]))
        )
        viewModel.actionMessage = "stale"
        viewModel.pendingDeletion = FileEntry(
            name: "old.txt",
            path: "/old.txt",
            size: 1,
            permissions: 0o100644,
            kind: .file
        )

        viewModel.resetTransientPresentationState()

        #expect(viewModel.actionMessage == nil)
        #expect(viewModel.pendingDeletion == nil)
    }

    private static let host = Host(
        name: "integrity-test",
        address: "127.0.0.1",
        username: "tester",
        authKind: .password
    )

    private func makeDependencies(fileSystem: any RemoteFileSystem) -> AppDependencies {
        let hostRepository = IntegrityHostRepository(host: Self.host)
        let transport = IntegrityTransport(fileSystem: fileSystem)
        let connectionManager = ConnectionManager(transport: transport)
        return AppDependencies(
            hostRepository: hostRepository,
            hostGroupRepository: IntegrityHostGroupRepository(),
            keyRepository: IntegrityKeyRepository(),
            credentialStore: InMemoryCredentialStore(),
            connectionManager: connectionManager,
            snippetExecutionPlanner: SnippetExecutionPlanner(
                connectionManager: connectionManager,
                executionProviderRegistry: .default,
                requirementAdapterRegistry: SnippetRequirementAdapterRegistry(adapters: [])
            ),
            diagnosticsTransport: transport,
            hostKeyStore: InMemoryHostKeyStore(),
            monitor: MonitorScheduler(connectionManager: connectionManager),
            runHistory: IntegrityRunHistoryRepository(),
            snippetRepository: IntegritySnippetRepository(),
            snippetGroupRepository: IntegritySnippetGroupRepository(),
            terminalSessions: TerminalSessionCoordinator(
                hostRepository: hostRepository,
                connectionManager: connectionManager
            ),
            appLock: AppLockController(authenticator: IntegrityAuthenticator(), isEnabled: false),
            subscription: .fixed(.free)
        )
    }
}

private final class FaultInjectingFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let underlying: MockRemoteFileSystem
    private let replacementTarget: String?
    private let failWritesStartingAt: UInt64?
    private let failingListPaths: Set<String>
    private let lock = NSLock()
    private var replacementFailuresRemaining: Int

    init(
        seeds: [String: Data],
        replacementTarget: String? = nil,
        failWritesStartingAt: UInt64? = nil,
        failingListPaths: Set<String> = []
    ) {
        underlying = MockRemoteFileSystem(seeds: seeds.map {
            MockFileSeed(path: $0.key, kind: .file, content: String(decoding: $0.value, as: UTF8.self))
        })
        self.replacementTarget = replacementTarget
        self.failWritesStartingAt = failWritesStartingAt
        self.failingListPaths = failingListPaths
        replacementFailuresRemaining = replacementTarget == nil ? 0 : 1
    }

    func list(_ path: String) async throws -> [FileEntry] {
        if failingListPaths.contains(path) { throw SSHError.channelClosed }
        return try await underlying.list(path)
    }
    func stat(_ path: String) async throws -> FileEntry { try await underlying.stat(path) }

    func open(_ path: String, mode: RemoteFileMode) async throws -> any RemoteFile {
        let file = try await underlying.open(path, mode: mode)
        guard mode == .writeCreate, let failWritesStartingAt else { return file }
        return FaultInjectingRemoteFile(underlying: file, failWritesStartingAt: failWritesStartingAt)
    }

    func createDirectory(_ path: String) async throws { try await underlying.createDirectory(path) }
    func remove(_ path: String) async throws { try await underlying.remove(path) }
    func removeDirectory(_ path: String) async throws { try await underlying.removeDirectory(path) }

    func rename(_ path: String, to newPath: String) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard newPath == replacementTarget, replacementFailuresRemaining > 0 else { return false }
            replacementFailuresRemaining -= 1
            return true
        }
        if shouldFail { throw SSHError.channelClosed }
        try await underlying.rename(path, to: newPath)
    }

    func setPermissions(_ mode: UInt32, path: String) async throws {
        try await underlying.setPermissions(mode, path: path)
    }

    func realPath(_ path: String) async throws -> String { try await underlying.realPath(path) }
    func close() async { await underlying.close() }
}

private final class FaultInjectingRemoteFile: RemoteFile, @unchecked Sendable {
    private let underlying: any RemoteFile
    private let failWritesStartingAt: UInt64

    init(underlying: any RemoteFile, failWritesStartingAt: UInt64) {
        self.underlying = underlying
        self.failWritesStartingAt = failWritesStartingAt
    }

    func read(offset: UInt64, length: UInt32) async throws -> Data {
        try await underlying.read(offset: offset, length: length)
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        if offset >= failWritesStartingAt { throw SSHError.channelClosed }
        try await underlying.write(data, at: offset)
    }

    func close() async throws { try await underlying.close() }
}

private final class IntegrityTransport: SSHTransport, @unchecked Sendable {
    private let session: IntegritySession

    init(fileSystem: any RemoteFileSystem) {
        session = IntegritySession(fileSystem: fileSystem)
    }

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        session
    }
}

private final class IntegritySession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    let isConnected = true
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    private let fileSystem: any RemoteFileSystem

    init(fileSystem: any RemoteFileSystem) {
        self.fileSystem = fileSystem
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        throw SSHError.channelClosed
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw SSHError.channelClosed
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        throw SSHError.channelClosed
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { fileSystem }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }

    func close() async {
        continuation.yield(.closed)
        continuation.finish()
    }
}

private final class IntegrityHostRepository: HostRepository, @unchecked Sendable {
    private let storedHost: Host
    init(host: Host) { storedHost = host }
    func allHosts() throws -> [Host] { [storedHost] }
    func host(id: String) throws -> Host? { storedHost.id == id ? storedHost : nil }
    func save(_ host: Host) throws {}
    func delete(id: String) throws {}
}

private final class IntegrityHostGroupRepository: HostGroupRepository, @unchecked Sendable {
    func allGroups() throws -> [HostGroup] { [] }
    func save(_ group: HostGroup) throws {}
    func delete(id: String) throws {}
}

private final class IntegrityKeyRepository: SSHKeyRepository, @unchecked Sendable {
    func allKeys() throws -> [SSHKey] { [] }
    func key(id: String) throws -> SSHKey? { nil }
    func save(_ key: SSHKey) throws {}
    func delete(id: String) throws {}
}

private final class IntegrityRunHistoryRepository: RunHistoryRepository, @unchecked Sendable {
    func record(_ entry: RunHistoryEntry) throws {}
    func update(_ entry: RunHistoryEntry) throws {}
    func recoverPending() throws {}
    func recent(hostUUID: String?, limit: Int) throws -> [RunHistoryEntry] { [] }
}

private final class IntegritySnippetRepository: SnippetRepository, @unchecked Sendable {
    func allSnippets() throws -> [Snippet] { [] }
    func snippet(id: String) throws -> Snippet? { nil }
    func save(_ snippet: Snippet) throws {}
    func delete(id: String) throws {}
    func count() throws -> Int { 0 }
}

private final class IntegritySnippetGroupRepository: SnippetGroupRepository, @unchecked Sendable {
    func allGroups() throws -> [SnippetGroup] { [] }
    func save(_ group: SnippetGroup) throws {}
    func delete(id: String) throws {}
}

private struct IntegrityAuthenticator: BiometricAuthenticator {
    let isAvailable = true
    let displayName = "Face ID"
    func authenticate(reason: String) async -> BiometricResult { .success }
}
