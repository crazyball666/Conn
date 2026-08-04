import ConnKit
import ConnMonitor
import ConnSSH
import ConnUI
import Foundation
import Testing
@testable import Conn

private final class StubHostRepository: HostRepository, @unchecked Sendable {
    var hosts: [Host]

    init(hosts: [Host] = []) { self.hosts = hosts }

    func allHosts() throws -> [Host] { hosts }
    func host(id: String) throws -> Host? { hosts.first { $0.id == id } }
    func save(_ host: Host) throws {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
    }
    func delete(id: String) throws { hosts.removeAll { $0.id == id } }
}

/// 模拟 `host_group_membership` 的 `ON DELETE CASCADE`：删组时把成员 id 摘掉。
private final class StubHostGroupRepository: HostGroupRepository, @unchecked Sendable {
    var groups: [HostGroup]
    weak var hostStore: StubHostRepository?

    init(groups: [HostGroup] = []) { self.groups = groups }

    func allGroups() throws -> [HostGroup] { groups.sorted { $0.sortOrder < $1.sortOrder } }

    func save(_ group: HostGroup) throws {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
    }

    func delete(id: String) throws {
        groups.removeAll { $0.id == id }
        guard let hostStore else { return }
        for index in hostStore.hosts.indices {
            hostStore.hosts[index].groupIDs.removeAll { $0 == id }
        }
    }
}

@MainActor
struct ServersViewModelTests {
    private func makeViewModel(
        hosts: [Host] = [],
        groups: [HostGroup] = []
    ) -> (ServersViewModel, StubHostGroupRepository) {
        let hostStore = StubHostRepository(hosts: hosts)
        let groupStore = StubHostGroupRepository(groups: groups)
        groupStore.hostStore = hostStore
        // MockSSHTransport 与 ConnectionManager 的参数都有默认值，测试里不会真的连接。
        let monitor = MonitorScheduler(
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let viewModel = ServersViewModel(
            hostStore: hostStore,
            groupStore: groupStore,
            monitor: monitor
        )
        viewModel.load()
        return (viewModel, groupStore)
    }

    @Test("卡片顺序照抄仓库顺序，不受健康状态影响")
    func keepsRepositoryOrder() {
        let hosts = [
            Host(name: "c-host", address: "3", username: "r"),
            Host(name: "a-host", address: "1", username: "r"),
            Host(name: "b-host", address: "2", username: "r")
        ]
        let (viewModel, _) = makeViewModel(hosts: hosts)

        #expect(viewModel.cards.map(\.name) == ["c-host", "a-host", "b-host"])
    }

    @Test("按分组筛选")
    func filtersByGroup() {
        let prod = HostGroup(name: "生产")
        let hosts = [
            Host(name: "web", address: "1", username: "r", groupIDs: [prod.id]),
            Host(name: "nas", address: "2", username: "r")
        ]
        let (viewModel, _) = makeViewModel(hosts: hosts, groups: [prod])

        viewModel.selectedGroupID = prod.id

        #expect(viewModel.cards.map(\.name) == ["web"])
    }

    @Test("搜索与分组取交集")
    func combinesSearchAndGroup() {
        let prod = HostGroup(name: "生产")
        let hosts = [
            Host(name: "web-01", address: "1", username: "r", groupIDs: [prod.id]),
            Host(name: "api-02", address: "2", username: "r", groupIDs: [prod.id])
        ]
        let (viewModel, _) = makeViewModel(hosts: hosts, groups: [prod])

        viewModel.selectedGroupID = prod.id
        viewModel.searchText = "api"

        #expect(viewModel.cards.map(\.name) == ["api-02"])
    }

    @Test("选中的分组 id 悬空时按「全部」处理")
    func danglingSelectionFallsBackToAll() {
        let hosts = [Host(name: "web", address: "1", username: "r")]
        let (viewModel, _) = makeViewModel(hosts: hosts)

        viewModel.selectedGroupID = "gone"

        #expect(viewModel.cards.count == 1)
    }

    @Test("页面运行中重新加载主机后会把新增主机交给监控调度")
    func reloadWhileVisibleRefreshesDashboardTargets() async throws {
        let existing = Host(name: "existing", address: "10.0.0.1", username: "root")
        let added = Host(name: "added", address: "10.0.0.2", username: "root")
        let hostStore = StubHostRepository(hosts: [existing])
        let log = ExecLog()
        let monitor = MonitorScheduler(
            connectionManager: ConnectionManager(transport: GatedTransport(log: log))
        )
        let viewModel = ServersViewModel(
            hostStore: hostStore,
            groupStore: StubHostGroupRepository(),
            monitor: monitor
        )

        viewModel.appear(interval: .seconds(600))
        defer { viewModel.disappear() }
        for _ in 0 ..< 100 where await log.execs < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await log.execs == 1)

        hostStore.hosts.append(added)
        viewModel.load()

        for _ in 0 ..< 100 where await log.execs < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await log.execs >= 2)
        #expect(viewModel.monitor.metrics[added.id] != nil)
    }

    @Test("删除当前选中的分组后回到「全部」")
    func deletingSelectedGroupResetsSelection() {
        let prod = HostGroup(name: "生产")
        let (viewModel, _) = makeViewModel(groups: [prod])
        viewModel.selectedGroupID = prod.id

        viewModel.deleteGroup(id: prod.id)

        #expect(viewModel.selectedGroupID == nil)
        #expect(viewModel.groups.isEmpty)
    }

    @Test("删除分组不影响组内主机")
    func deletingGroupKeepsHosts() {
        let prod = HostGroup(name: "生产")
        let hosts = [Host(name: "web", address: "1", username: "r", groupIDs: [prod.id])]
        let (viewModel, _) = makeViewModel(hosts: hosts, groups: [prod])

        viewModel.deleteGroup(id: prod.id)

        #expect(viewModel.cards.map(\.name) == ["web"])
    }

    @Test("重名分组被拒并写入错误消息")
    func rejectsDuplicateGroupName() {
        let (viewModel, groupStore) = makeViewModel(groups: [HostGroup(name: "生产")])

        viewModel.addGroup(" 生产 ")

        #expect(groupStore.groups.count == 1)
        #expect(viewModel.errorMessage == Conn.L("已存在同名分组"))
    }

    @Test("新增分组的排序权重递增")
    func newGroupGetsNextSortOrder() {
        let (viewModel, groupStore) = makeViewModel(groups: [HostGroup(name: "生产", sortOrder: 4)])

        viewModel.addGroup("测试")

        #expect(groupStore.groups.map(\.sortOrder).max() == 5)
    }

    @Test("重命名分组不影响成员关系")
    func renameKeepsMembership() {
        let prod = HostGroup(name: "旧名")
        let hosts = [Host(name: "web", address: "1", username: "r", groupIDs: [prod.id])]
        let (viewModel, groupStore) = makeViewModel(hosts: hosts, groups: [prod])
        viewModel.selectedGroupID = prod.id

        viewModel.renameGroup(id: prod.id, to: "新名")

        #expect(groupStore.groups.map(\.name) == ["新名"])
        #expect(viewModel.cards.map(\.name) == ["web"])
    }

    @Test("采集进行中卡片标记为忙碌，结束后复位")
    func mapsCollectPhaseToCard() async throws {
        let target = Host(name: "web", address: "10.0.0.1", username: "root")
        let log = ExecLog()
        await log.armGate(Gate())
        let monitor = MonitorScheduler(
            connectionManager: ConnectionManager(transport: GatedTransport(log: log))
        )
        let viewModel = ServersViewModel(
            hostStore: StubHostRepository(hosts: [target]),
            groupStore: StubHostGroupRepository(),
            monitor: monitor
        )
        viewModel.load()
        #expect(viewModel.cards.first?.collectPhase == .idle)

        let scan = Task { await monitor.scanNow(hosts: [target]) }

        // 等采集真正进入飞行中（exec 被闸门卡住）。上限 200 次轮询，避免死等。
        // 每次真睡 5ms 而非只 `Task.yield()`：yield 烧的是 CPU 周期不推进墙钟，
        // 而 exec 跑在协作线程池上，并行执行测试时 200 次 yield 可能不够它落地。
        // 首采无读数，池空时也应判成 collecting 而非 reconnecting——直接等这个
        // 精确值，既覆盖原来的「转圈亮起」也覆盖原来的「不是重连态」两条断言。
        var busySeen = false
        for _ in 0 ..< 200 where !busySeen {
            try? await Task.sleep(for: .milliseconds(5))
            busySeen = viewModel.cards.first?.collectPhase == .collecting
        }
        #expect(busySeen)
        // 闸门仍关着，这一态是稳定的，可以再读一次确认没跳去重连。
        #expect(viewModel.cards.first?.collectPhase == .collecting)

        await log.openGate()
        await scan.value

        #expect(viewModel.cards.first?.collectPhase == .idle)
    }

    /// 正向覆盖「重连态到达 UI」——`card(for:)` 里的 `collectPhase(_:)` 映射
    /// 是这条通路上**唯一**的一环，而其余测试只断言非重连态：把映射里的
    /// `.reconnecting` 分支错写成 `.collecting`，它们仍会全绿。
    ///
    /// 制造 `.reconnecting` 的办法：先成功采一轮建立读数，再让下一次 exec 抛
    /// `SSHError.channelClosed`（失败会触发 `invalidate(host:)` 清空连接池），
    /// 随后的同轮重试就处于「有读数 + 池空」= `.reconnecting`。
    @Test("重连中（有读数 + 会话被驱逐）映射到卡片 collectPhase")
    func mapsReconnectingPhaseToCard() async throws {
        let target = Host(name: "web", address: "10.0.0.1", username: "root")
        let log = ExecLog()
        let monitor = MonitorScheduler(
            connectionManager: ConnectionManager(transport: GatedTransport(log: log))
        )
        let viewModel = ServersViewModel(
            hostStore: StubHostRepository(hosts: [target]),
            groupStore: StubHostGroupRepository(),
            monitor: monitor
        )
        viewModel.load()

        // 第一轮放行，建立「已知可用」的读数。
        await monitor.scanNow(hosts: [target])
        #expect(viewModel.cards.first?.collectPhase == .idle)

        // 第二轮：首次 exec 抛错触发驱逐（池清空），但读数还在——
        // 重试那次 attempt 应判成 .reconnecting。闸门挡在重试的 exec 上，
        // 好在它返回前读到卡片状态。
        await log.failNext(1)
        await log.armGate(Gate())
        let scan = Task { await monitor.scanNow(hosts: [target]) }

        // 等到第 3 次 exec 已开始（首轮 1 次 + 本轮失败 1 次 + 重试 1 次）。
        // 直接轮询卡片状态可能撞上失败那次 attempt 的瞬时值；用单调递增的 exec
        // 计数定位，才能保证读到的是「重试那次 attempt」写下的、稳定不再变的值。
        await waitUntilExecCount(log, atLeast: 3)
        // `.reconnecting` 同时蕴含「转圈亮着」（`isCollecting` 为真），
        // 不必再单独断言一次忙碌位——枚举已经把两者绑成一个值。
        #expect(viewModel.cards.first?.collectPhase == .reconnecting)

        await log.openGate()
        await scan.value

        // 重试成功：回到常态，不报错、读数还在。
        #expect(viewModel.cards.first?.collectPhase == .idle)
    }

    /// 有上限地轮询，直到 `log.execs` 达到 `target` 或耗尽 `maxAttempts`。
    ///
    /// 每次重试真睡一小段墙钟（而非只 `Task.yield()`）：`yield` 烧的是 CPU 周期，
    /// 而被等的 `exec` 跑在协作线程池上，并行执行测试时 200 次 yield 可能在事件
    /// 落地前就耗尽。耗尽时 `Issue.record` 而非静默返回——静默返回会把「等待超时」
    /// 伪装成「被测行为不对」，让排查从一开始就走错方向。
    private func waitUntilExecCount(
        _ log: ExecLog, atLeast target: Int, maxAttempts: Int = 200,
        pollInterval: Duration = .milliseconds(5),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0 ..< maxAttempts {
            if await log.execs >= target { return }
            try? await Task.sleep(for: pollInterval)
        }
        let actual = await log.execs
        let message: String = """
            等待 execs >= \(target) 超时（\(maxAttempts) 次 × \(pollInterval)），实际 \(actual)。
            紧随其后的断言读到的是等待前的旧值。
            """
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }
}

/// 由测试控制开合的闸门：`exec` 在此挂起，直到测试放行。
///
/// 用数组而非单个 `CheckedContinuation?` 存等待者：单槽位的版本在第二个等待者到来时
/// 会**静默覆盖**第一个，`open()` 只唤醒最后那个，被覆盖的那个永远醒不过来 → 测试挂死。
private actor Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// 记录 exec 次数，并按预设让前 N 次 exec 抛错（模拟后台期间死掉的会话）。
///
/// 计数与失败预设必须跨会话存活——重连会新建 `GatedSession`，状态挂在会话上就丢了。
private actor ExecLog {
    private(set) var execs = 0
    private var failuresRemaining = 0
    private var gate: Gate?

    /// 追加 n 次待失败的 exec。
    func failNext(_ count: Int) { failuresRemaining += count }

    /// 装闸门：此后「成功」的 exec 会挂起等放行。失败路径不受闸门影响，保持即时确定。
    func armGate(_ gate: Gate) { self.gate = gate }

    func openGate() async { await gate?.open() }

    /// 返回 true 表示本次 exec 应当抛错。
    func shouldFailExec() -> Bool {
        execs += 1
        guard failuresRemaining > 0 else { return false }
        failuresRemaining -= 1
        return true
    }

    func waitIfGated() async {
        if let gate { await gate.wait() }
    }
}

private final class GatedTransport: SSHTransport {
    let log: ExecLog
    init(log: ExecLog) { self.log = log }

    func connect(
        _ endpoint: SSHEndpoint, username: String, auth: SSHAuth, hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        GatedSession(log: log)
    }
}

private final class GatedSession: SSHSession {
    private let log: ExecLog
    let state: AsyncStream<SSHSessionState>
    let isConnected = true
    private let continuation: AsyncStream<SSHSessionState>.Continuation

    init(log: ExecLog) {
        self.log = log
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        if await log.shouldFailExec() { throw SSHError.channelClosed }
        await log.waitIfGated()
        return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) {
            ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }
    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}
