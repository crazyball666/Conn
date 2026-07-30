import Foundation

/// 一条会实时产出输出、并在结束后提供最终结果的 SSH 命令。
///
/// 普通 for-await 的 break 只停止显示，不会取消命令；调用方仍可随后等待
/// result() 取得完整终态。阅读 output 的任务被取消，或 output stream 本身终止时，
/// 引擎实现会取消本地读取任务；这不会终止远端进程。
public struct SSHCommandStream: Sendable {
    public let output: AsyncThrowingStream<Data, Error>
    private let resultTask: Task<ExecResult, Error>

    public init(
        output: AsyncThrowingStream<Data, Error>,
        result: @escaping @Sendable () async throws -> ExecResult
    ) {
        self.output = output
        resultTask = Task {
            try await result()
        }
    }

    /// 等待同一次远端命令的终态；可安全地重复调用。
    public func result() async throws -> ExecResult {
        try await resultTask.value
    }
}

/// output 终止时取消引擎的后台命令任务。
///
/// 生命周期中介必须在任务启动后立即 install；任务完成和 output 提前终止无论谁先发生，
/// 都会清空持有的 task，避免 continuation → 中介 → task → continuation 的保留环。
package final class SSHCommandStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ExecResult, Error>?
    private var isFinished = false

    package init() {}

    package func install(_ task: Task<ExecResult, Error>) {
        lock.withLock {
            guard !isFinished else { return }
            self.task = task
        }
    }

    package func cancel() {
        let task = lock.withLock {
            isFinished = true
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
    }

    package func finish() {
        lock.withLock {
            isFinished = true
            task = nil
        }
    }
}
