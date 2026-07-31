import ConnSSH

/// 独立的进程采集器：复用 SSH 会话，但不读取或更新主机基础指标。
public struct ProcessCollector: Sendable {
    public init() {}

    public func collect(session: any SSHSession) async throws -> [RemoteProcess] {
        let result = try await session.exec(ProcessCollectionScript.command)
        return ProcessParser.parse(result.stdoutText)
    }
}
