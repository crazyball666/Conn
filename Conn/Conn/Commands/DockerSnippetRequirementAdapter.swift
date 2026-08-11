import ConnKit
import ConnOps
import ConnRunner
import ConnSSH

/// App-layer inversion boundary between generic snippet requirements and Docker probing.
struct DockerSnippetRequirementAdapter: SnippetRequirementAdapter {
    let capability = RemoteCapability.docker
    let scriptFamily = RemoteScriptFamily.posix

    private let registry: DockerEnvironmentProviderRegistry

    init(registry: DockerEnvironmentProviderRegistry) {
        self.registry = registry
    }

    func prepare(
        on session: any SSHSession,
        profile: RemotePlatformProfile
    ) async throws -> SnippetRequirementResolution {
        guard let provider = registry.provider(for: profile.kind) else {
            return unsupported(.unsupportedPlatform)
        }

        let result = try await provider.probe(on: session)
        switch result.availability {
        case .available:
            guard let runtime = result.runtime else {
                return unavailable(.queryFailed)
            }
            return SnippetRequirementResolution(
                state: .supported,
                scriptPrelude: runtime.shellBootstrapCommand
            )
        case .notInstalled:
            return unavailable(.executableMissing)
        case .permissionDenied:
            return unavailable(.permissionDenied)
        case .daemonNotRunning:
            return unavailable(.daemonNotRunning)
        case .unsupportedPlatform:
            return unsupported(.unsupportedPlatform)
        }
    }

    private func unavailable(_ code: CapabilityReasonCode) -> SnippetRequirementResolution {
        SnippetRequirementResolution(
            state: .unavailable(issue: CapabilityIssue(code: code))
        )
    }

    private func unsupported(_ code: CapabilityReasonCode) -> SnippetRequirementResolution {
        SnippetRequirementResolution(
            state: .unsupported(issue: CapabilityIssue(code: code))
        )
    }
}
