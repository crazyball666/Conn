import ConnKit
import ConnSSH
import Foundation

public struct ZellijProviderConfiguration: Codable, Sendable, Equatable {
    public init() {}
}

public struct ZellijWorkspaceInstancePayload: Codable, Sendable, Equatable {
    public init() {}
}

public struct ZellijAttachmentPayload: Codable, Sendable, Equatable {
    public let sessionName: String

    public init(sessionName: String) {
        self.sessionName = sessionName
    }
}

package struct ZellijSessionName: RawRepresentable, Hashable, Sendable {
    package let rawValue: String

    package init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue != ".",
              rawValue != "..",
              !rawValue.hasPrefix("-"),
              !rawValue.contains("/"),
              !rawValue.unicodeScalars.contains(where: {
                  $0.value < 0x20 || (0x7F ... 0x9F).contains($0.value)
              })
        else { return nil }
        self.rawValue = rawValue
    }
}

public struct ZellijProvider: PersistentTerminalProvider {
    public static let providerID = "zellij"
    public static let configurationVersion = 1
    public static let workspaceInstancePayloadVersion = 1
    public static let attachmentPayloadVersion = 1

    private static let runtimeCache = ZellijRuntimeCache()
    private static let attachmentGenerations = ZellijAttachmentGenerationSource()

    public let descriptor: PersistentTerminalProviderDescriptor
    public let defaultConfiguration: PersistentTerminalConfiguration

    public init() {
        let configuration = ZellijProviderConfiguration()
        let payload: Data
        do {
            payload = try JSONEncoder().encode(configuration)
        } catch {
            preconditionFailure("built-in Zellij configuration must encode: \(error)")
        }
        defaultConfiguration = PersistentTerminalConfiguration(
            providerID: Self.providerID,
            configurationKey: "default",
            payloadVersion: Self.configurationVersion,
            providerPayload: payload
        )
        descriptor = PersistentTerminalProviderDescriptor(
            id: Self.providerID,
            displayName: "Zellij",
            supportedPlatforms: [.linux, .macOS],
            supportedConfigurationVersions: [Self.configurationVersion],
            supportedWorkspaceInstancePayloadVersions: [Self.workspaceInstancePayloadVersion],
            supportedAttachmentPayloadVersions: [Self.attachmentPayloadVersion],
            potentialFeatures: [
                .workspaceDiscovery,
                .workspaceCreation,
                .workspaceDestruction
            ]
        )
    }

    public func probe(
        in context: PersistentTerminalContext
    ) async throws -> PersistentTerminalAvailability {
        guard descriptor.supportedPlatforms.contains(context.platformProfile.kind) else {
            return .init(state: .unsupported, issue: .unsupportedPlatform)
        }
        do {
            let runtime = try await resolveRuntime(in: context)
            return try PersistentTerminalAvailability(
                state: .available,
                effectiveFeatures: descriptor.potentialFeatures,
                instance: makeProviderInstance(runtime: runtime)
            )
        } catch let issue as PersistentTerminalError {
            return .init(state: .unavailable, issue: issue)
        }
    }

    public func listWorkspaces(
        in context: PersistentTerminalContext
    ) async throws -> [RemoteWorkspaceSummary] {
        let runtime = try await resolveRuntime(in: context)
        let result = try await execute(
            runtime: runtime,
            arguments: ["list-sessions", "--short", "--no-formatting"],
            in: context
        )
        guard result.isSuccess else {
            if isEmptyCatalogDiagnostic(result.stderrText) {
                return []
            }
            throw commandRejected(result)
        }

        let names = try decodeSessionNames(result.stdout)
        return try names.map { try workspaceSummary(name: $0) }
    }

    public func createWorkspace(
        _ request: CreateWorkspaceRequest,
        in context: PersistentTerminalContext
    ) async throws -> RemoteWorkspaceSummary {
        let candidate = request.name ?? Self.generatedSessionName()
        guard let name = ZellijSessionName(rawValue: candidate) else {
            throw PersistentTerminalError.invalidConfiguration
        }
        let runtime = try await resolveRuntime(in: context)
        let result = try await execute(
            runtime: runtime,
            arguments: ["attach", "--create-background", name.rawValue],
            in: context
        )
        guard result.isSuccess else { throw commandRejected(result) }
        return try workspaceSummary(name: name)
    }

    public func renameWorkspace(
        _ workspace: RemoteWorkspaceRef,
        to newName: String,
        in context: PersistentTerminalContext
    ) async throws {
        _ = (workspace, newName, context)
        throw PersistentTerminalError.unsupportedFeature(
            providerID: Self.providerID,
            feature: "workspaceRename"
        )
    }

    public func destroyWorkspace(
        _ workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) async throws {
        let name = try decodeWorkspace(workspace)
        let runtime = try await resolveRuntime(in: context)
        let result = try await execute(
            runtime: runtime,
            arguments: ["delete-session", "--force", name.rawValue],
            in: context
        )
        guard result.isSuccess else { throw commandRejected(result) }
    }

    public func makeAttachmentDescriptor(
        to workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) throws -> PersistentAttachmentDescriptor {
        try validateConfiguration(context.backendConfiguration)
        let name = try decodeWorkspace(workspace)
        return try PersistentAttachmentDescriptor(
            providerID: Self.providerID,
            configuration: context.backendConfiguration,
            workspace: workspace,
            payloadVersion: Self.attachmentPayloadVersion,
            providerPayload: JSONEncoder().encode(
                ZellijAttachmentPayload(sessionName: name.rawValue)
            )
        )
    }

    public func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment {
        _ = reason
        try validateConfiguration(context.backendConfiguration)
        guard descriptor.providerID == Self.providerID,
              descriptor.configuration == context.backendConfiguration,
              descriptor.payloadVersion == Self.attachmentPayloadVersion
        else {
            if descriptor.payloadVersion != Self.attachmentPayloadVersion {
                throw PersistentTerminalError.unsupportedDescriptorVersion(
                    providerID: Self.providerID,
                    component: .attachment,
                    version: descriptor.payloadVersion
                )
            }
            throw PersistentTerminalError.invalidConfiguration
        }
        let workspaceName = try decodeWorkspace(descriptor.workspace)
        let payload: ZellijAttachmentPayload
        do {
            payload = try JSONDecoder().decode(
                ZellijAttachmentPayload.self,
                from: descriptor.providerPayload
            )
        } catch {
            throw PersistentTerminalError.invalidConfiguration
        }
        guard payload.sessionName == workspaceName.rawValue else {
            throw PersistentTerminalError.invalidConfiguration
        }

        let runtime = try await resolveRuntime(in: context)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let script = zellijAttachmentScript(
            executable: runtime.executable,
            sessionName: workspaceName,
            nonce: nonce
        )
        let command: String
        do {
            command = try POSIXScriptExecutionProvider().invocation(
                for: script,
                interpreter: .sh
            )
        } catch {
            throw PersistentTerminalError.invalidConfiguration
        }
        let process = try await context.session.openProcess(.init(
            command: command,
            terminal: RemoteTerminalRequest(type: "xterm-256color", size: terminalSize)
        ))
        do {
            let channel = try await ZellijProcessShellChannel.open(
                process: process,
                nonce: nonce
            )
            return await ZellijPassthroughAttachment(
                descriptor: descriptor,
                channel: channel,
                attachmentGeneration: Self.attachmentGenerations.next()
            )
        } catch {
            await process.close()
            throw error
        }
    }

    private func resolveRuntime(
        in context: PersistentTerminalContext
    ) async throws -> ZellijRuntime {
        try validateConfiguration(context.backendConfiguration)
        let key = ZellijRuntimeCacheKey(context: context)
        if let cached = await Self.runtimeCache.value(for: key) {
            return cached
        }

        let result = try await context.session.exec("command -v zellij", timeout: .seconds(10))
        guard result.isSuccess else { throw PersistentTerminalError.executableMissing }
        var bytes = result.stdout
        if bytes.last == UInt8(ascii: "\n") {
            bytes.removeLast()
        }
        if bytes.last == UInt8(ascii: "\r") {
            bytes.removeLast()
        }
        guard let path = String(data: bytes, encoding: .utf8),
              path.hasPrefix("/"),
              !path.isEmpty,
              !path.unicodeScalars.contains(where: {
                  $0.value < 0x20 || (0x7F ... 0x9F).contains($0.value)
              })
        else {
            throw PersistentTerminalError.invalidConfiguration
        }
        let runtime = ZellijRuntime(executable: path)
        await Self.runtimeCache.insert(runtime, session: context.session, for: key)
        return runtime
    }

    private func execute(
        runtime: ZellijRuntime,
        arguments: [String],
        in context: PersistentTerminalContext
    ) async throws -> ExecResult {
        let command = ([runtime.executable] + arguments)
            .map(POSIXShellArgument.encode)
            .joined(separator: " ")
        return try await context.session.exec(command, timeout: .seconds(30))
    }

    private func validateConfiguration(
        _ configuration: PersistentTerminalConfiguration
    ) throws {
        guard configuration.providerID == Self.providerID,
              configuration.configurationKey == "default",
              configuration.payloadVersion == Self.configurationVersion,
              (try? JSONDecoder().decode(
                  ZellijProviderConfiguration.self,
                  from: configuration.providerPayload
              )) != nil
        else {
            throw PersistentTerminalError.invalidConfiguration
        }
    }

    private func decodeSessionNames(_ data: Data) throws -> [ZellijSessionName] {
        let text = String(decoding: data, as: UTF8.self)
        var result: [ZellijSessionName] = []
        for line in text.split(whereSeparator: \Character.isNewline) {
            guard let name = ZellijSessionName(rawValue: String(line)) else {
                throw PersistentTerminalError.protocolViolation
            }
            result.append(name)
        }
        return result
    }

    private func decodeWorkspace(_ workspace: RemoteWorkspaceRef) throws -> ZellijSessionName {
        guard workspace.instancePayloadVersion == Self.workspaceInstancePayloadVersion,
              (try? JSONDecoder().decode(
                  ZellijWorkspaceInstancePayload.self,
                  from: workspace.providerInstancePayload
              )) != nil,
              let name = ZellijSessionName(rawValue: workspace.workspaceID)
        else {
            throw PersistentTerminalError.invalidConfiguration
        }
        return name
    }

    private func workspaceSummary(
        name: ZellijSessionName
    ) throws -> RemoteWorkspaceSummary {
        try RemoteWorkspaceSummary(
            workspace: RemoteWorkspaceRef(
                workspaceID: name.rawValue,
                instancePayloadVersion: Self.workspaceInstancePayloadVersion,
                providerInstancePayload: JSONEncoder().encode(
                    ZellijWorkspaceInstancePayload()
                )
            ),
            name: name.rawValue,
            occupancy: RemoteWorkspaceOccupancy(
                affectedAttachmentCount: nil,
                observedAt: .now,
                freshness: .unknown
            )
        )
    }

    private func makeProviderInstance(
        runtime: ZellijRuntime
    ) throws -> PersistentTerminalProviderInstance {
        _ = runtime
        return try PersistentTerminalProviderInstance(
            payloadVersion: Self.workspaceInstancePayloadVersion,
            providerPayload: JSONEncoder().encode(ZellijWorkspaceInstancePayload())
        )
    }

    private func isEmptyCatalogDiagnostic(_ diagnostic: String) -> Bool {
        let value = diagnostic.lowercased()
        return value.contains("no active zellij sessions")
            || value.contains("no zellij sessions")
    }

    private func commandRejected(_ result: ExecResult) -> PersistentTerminalError {
        .commandRejected(
            result.stderrText.isEmpty ? "Zellij command failed" : result.stderrText
        )
    }

    private static func generatedSessionName() -> String {
        "conn-" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(12)
    }
}

package struct ZellijRuntime: Sendable, Equatable {
    package let executable: String
}

private struct ZellijRuntimeCacheKey: Hashable, @unchecked Sendable {
    let sessionObjectID: ObjectIdentifier
    let connectionIdentity: SSHConnectionIdentity
    let configuration: PersistentTerminalConfiguration

    init(context: PersistentTerminalContext) {
        sessionObjectID = ObjectIdentifier(context.session)
        connectionIdentity = context.connectionIdentity
        configuration = context.backendConfiguration
    }
}

private actor ZellijRuntimeCache {
    private struct Entry: Sendable {
        let runtime: ZellijRuntime
        let session: any SSHSession
        var lastAccess: Date
    }

    private let lifetime: TimeInterval = 120
    private let maximumEntryCount = 32
    private var entries: [ZellijRuntimeCacheKey: Entry] = [:]

    func value(for key: ZellijRuntimeCacheKey) -> ZellijRuntime? {
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.lastAccess) <= lifetime }
        guard var entry = entries[key] else { return nil }
        entry.lastAccess = now
        entries[key] = entry
        return entry.runtime
    }

    func insert(
        _ runtime: ZellijRuntime,
        session: any SSHSession,
        for key: ZellijRuntimeCacheKey
    ) {
        entries[key] = Entry(runtime: runtime, session: session, lastAccess: .now)
        guard entries.count > maximumEntryCount,
              let oldest = entries.min(by: {
                  $0.value.lastAccess < $1.value.lastAccess
              })?.key
        else { return }
        entries[oldest] = nil
    }
}

package actor ZellijAttachmentGenerationSource {
    private var generation: UInt64 = 0

    package func next() -> UInt64 {
        generation &+= 1
        return generation
    }
}
