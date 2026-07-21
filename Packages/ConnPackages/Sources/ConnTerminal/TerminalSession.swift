import ConnSSH
import Foundation

/// 终端会话：桥接 `ShellChannel` 的字节流与 UI 的 feed 回调。
///
/// 技术方案 §4.2：输出按 ~16ms 合帧批量投递（≤60fps），避免逐字节刷新掉帧。
/// session 生命周期与 UI 解耦——关闭页面不断连（多会话后台保持由 Store 管）。
public actor TerminalSession {
    /// 会话状态。
    public enum State: Sendable {
        case idle, running, closed, failed
    }

    private let channel: any ShellChannel
    private var onFeed: (@Sendable ([UInt8]) -> Void)?
    private var pumpTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pending: [UInt8] = []
    private(set) var state: State = .idle

    /// 合帧间隔（纳秒）。16ms ≈ 60fps。
    private let frameInterval: UInt64

    public init(channel: any ShellChannel, frameIntervalMillis: UInt64 = 16) {
        self.channel = channel
        frameInterval = frameIntervalMillis * 1_000_000
    }

    /// 开始泵送：把通道输出攒帧后经 `onFeed` 投给 UI。
    ///
    /// - Parameter onFeed: 在合帧边界被调用，参数是这一帧累积的字节。
    public func start(onFeed: @escaping @Sendable ([UInt8]) -> Void) {
        guard state == .idle else { return }
        self.onFeed = onFeed
        state = .running

        pumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in await channel.output {
                    await enqueue([UInt8](chunk))
                }
                await markClosed()
            } catch {
                await markFailed()
            }
        }
    }

    /// 用户输入 → 通道。
    public func send(_ bytes: [UInt8]) async {
        try? await channel.write(Data(bytes))
    }

    /// 终端尺寸变化 → PTY resize（SIGWINCH）。
    public func resize(cols: Int, rows: Int) async {
        try? await channel.resize(TermSize(cols: cols, rows: rows))
    }

    public func close() async {
        pumpTask?.cancel()
        flushTask?.cancel()
        await channel.close()
        state = .closed
    }

    // MARK: - 合帧

    private func enqueue(_ bytes: [UInt8]) {
        pending.append(contentsOf: bytes)
        scheduleFlush()
    }

    /// 若无待触发的 flush，安排一次；已有则复用（合帧的核心）。
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: frameInterval)
            await flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard !pending.isEmpty else { return }
        let frame = pending
        pending.removeAll(keepingCapacity: true)
        onFeed?(frame)
    }

    private func markClosed() {
        flush()
        state = .closed
    }

    private func markFailed() {
        state = .failed
    }
}
