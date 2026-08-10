import ConnSSH

public extension DockerService {
    static func inspect(
        id: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ContainerDetail {
        let result = try await session.exec(DockerCommand.inspect(id: id, runtime: runtime))
        try requireQuerySuccess(result)
        guard let detail = DockerParser.parseInspect(result.stdoutText) else {
            throw DockerQueryError.invalidResponse
        }
        return detail
    }

    static func volumeDetail(
        name: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> VolumeDetail {
        let result = try await session.exec(
            DockerCommand.volumeInspect(name: name, runtime: runtime)
        )
        try requireQuerySuccess(result)
        guard let detail = DockerParser.parseVolumeInspect(result.stdoutText) else {
            throw DockerQueryError.invalidResponse
        }
        return detail
    }

    static func networkDetail(
        name: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> NetworkDetail {
        let result = try await session.exec(
            DockerCommand.networkInspect(name: name, runtime: runtime)
        )
        try requireQuerySuccess(result)
        guard let detail = DockerParser.parseNetworkInspect(result.stdoutText) else {
            throw DockerQueryError.invalidResponse
        }
        return detail
    }

    static func imageDetail(
        reference: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ImageDetail {
        let result = try await session.exec(
            DockerCommand.imageInspect(reference: reference, runtime: runtime)
        )
        try requireQuerySuccess(result)
        guard let detail = DockerParser.parseImageInspect(result.stdoutText) else {
            throw DockerQueryError.invalidResponse
        }
        return detail
    }

    /// 容器详情（inspect）。命令失败或响应无法解析时抛错，避免 UI 把失败当成空详情。
    static func inspect(
        id: String,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> ContainerDetail {
        let result = try await session.exec(DockerCommand.inspect(id: id, sudo: sudo))
        try requireQuerySuccess(result)
        guard let detail = DockerParser.parseInspect(result.stdoutText) else {
            throw DockerQueryError.invalidResponse
        }
        return detail
    }

    static func volumeDetail(
        name: String,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> VolumeDetail {
        let result = try await session.exec(DockerCommand.volumeInspect(name: name, sudo: sudo))
        try requireQuerySuccess(result)
        guard let detail = DockerParser.parseVolumeInspect(result.stdoutText) else {
            throw DockerQueryError.invalidResponse
        }
        return detail
    }

    static func networkDetail(
        name: String,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> NetworkDetail {
        let result = try await session.exec(DockerCommand.networkInspect(name: name, sudo: sudo))
        try requireQuerySuccess(result)
        guard let detail = DockerParser.parseNetworkInspect(result.stdoutText) else {
            throw DockerQueryError.invalidResponse
        }
        return detail
    }

    static func imageDetail(
        reference: String,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> ImageDetail {
        let result = try await session.exec(DockerCommand.imageInspect(reference: reference, sudo: sudo))
        try requireQuerySuccess(result)
        guard let detail = DockerParser.parseImageInspect(result.stdoutText) else {
            throw DockerQueryError.invalidResponse
        }
        return detail
    }

    internal static func requireQuerySuccess(_ result: ExecResult) throws {
        guard result.exitCode == 0 else {
            throw DockerQueryError.commandFailed(
                exitCode: result.exitCode,
                message: result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            )
        }
    }
}
