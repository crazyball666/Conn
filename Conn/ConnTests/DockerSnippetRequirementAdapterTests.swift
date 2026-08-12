import ConnKit
import ConnOps
import ConnRunner
import ConnSSH
import ConnTerminal
import Foundation
import Testing
@testable import Conn

@Suite("Docker snippet requirement adapter")
struct DockerSnippetRequirementAdapterTests {
    @Test("registers the Docker capability for POSIX scripts")
    func exposesRegistryKey() {
        let adapter = DockerSnippetRequirementAdapter(
            registry: DockerEnvironmentProviderRegistry(providers: [])
        )

        #expect(adapter.capability == .docker)
        #expect(adapter.scriptFamily == .posix)
    }

    @Test("maps probe results exactly and probes once per preparation")
    func mapsProbeResultsExactly() async throws {
        let runtime = DockerRuntimeContext(
            executable: "/opt/docker/bin/docker",
            sudo: true
        )
        let cases: [(DockerProbeResult, SnippetRequirementResolution)] = [
            (
                DockerProbeResult(availability: .available(sudo: true), runtime: runtime),
                SnippetRequirementResolution(
                    state: .supported,
                    scriptPrelude: runtime.shellBootstrapCommand
                )
            ),
            (
                DockerProbeResult(availability: .available(sudo: false), runtime: nil),
                SnippetRequirementResolution(
                    state: unavailable(.queryFailed)
                )
            ),
            (
                DockerProbeResult(availability: .notInstalled, runtime: runtime),
                SnippetRequirementResolution(
                    state: unavailable(.executableMissing)
                )
            ),
            (
                DockerProbeResult(availability: .permissionDenied, runtime: runtime),
                SnippetRequirementResolution(
                    state: unavailable(.permissionDenied)
                )
            ),
            (
                DockerProbeResult(availability: .daemonNotRunning, runtime: runtime),
                SnippetRequirementResolution(
                    state: unavailable(.daemonNotRunning)
                )
            ),
            (
                DockerProbeResult(availability: .unsupportedPlatform, runtime: runtime),
                SnippetRequirementResolution(
                    state: unsupported(.unsupportedPlatform)
                )
            ),
        ]

        for (probeResult, expected) in cases {
            let counter = ProbeCounter()
            let registry = DockerEnvironmentProviderRegistry(providers: [
                FixtureDockerEnvironmentProvider(
                    platform: .linux,
                    result: probeResult,
                    counter: counter
                ),
            ])
            let adapter = DockerSnippetRequirementAdapter(registry: registry)

            let resolution = try await adapter.prepare(
                on: AdapterTestSession(),
                profile: RemotePlatformProfile(kind: .linux)
            )

            #expect(resolution == expected)
            #expect(counter.value == 1)
        }
    }

    @Test("missing platform provider is unsupported without probing")
    func missingProviderIsUnsupported() async throws {
        let counter = ProbeCounter()
        let registry = DockerEnvironmentProviderRegistry(providers: [
            FixtureDockerEnvironmentProvider(
                platform: .linux,
                result: DockerProbeResult(
                    availability: .available(sudo: false),
                    runtime: DockerRuntimeContext(executable: "docker", sudo: false)
                ),
                counter: counter
            ),
        ])
        let adapter = DockerSnippetRequirementAdapter(registry: registry)

        let resolution = try await adapter.prepare(
            on: AdapterTestSession(),
            profile: RemotePlatformProfile(kind: .windows)
        )

        #expect(resolution == SnippetRequirementResolution(
            state: unsupported(.unsupportedPlatform)
        ))
        #expect(counter.value == 0)
    }

    private func unavailable(_ code: CapabilityReasonCode) -> CapabilityState {
        .unavailable(issue: CapabilityIssue(code: code))
    }

    private func unsupported(_ code: CapabilityReasonCode) -> CapabilityState {
        .unsupported(issue: CapabilityIssue(code: code))
    }
}

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private struct FixtureDockerEnvironmentProvider: DockerEnvironmentProvider {
    let platform: RemotePlatformKind
    let scriptFamily: RemoteScriptFamily = .posix
    let result: DockerProbeResult
    let counter: ProbeCounter

    func probe(on session: any SSHSession) async throws -> DockerProbeResult {
        _ = session
        counter.increment()
        return result
    }
}

private final class AdapterTestSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true

    init() {
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        _ = command
        _ = timeout
        return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = command
        return AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        _ = command
        _ = timeout
        return SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) {
            ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        _ = term
        throw SSHError.channelClosed
    }

    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        _ = target
        throw SSHError.channelClosed
    }
    func close() async { continuation.finish() }
}
