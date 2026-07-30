import Foundation

/// 一条会实时产出输出、并在结束后提供最终结果的 SSH 命令。
public struct SSHCommandStream: Sendable {
    public let output: AsyncThrowingStream<Data, Error>
    private let waitForResult: @Sendable () async throws -> ExecResult

    public init(
        output: AsyncThrowingStream<Data, Error>,
        result: @escaping @Sendable () async throws -> ExecResult
    ) {
        self.output = output
        waitForResult = result
    }

    /// 等待同一次远端命令的终态；可安全地重复调用。
    public func result() async throws -> ExecResult {
        try await waitForResult()
    }
}
