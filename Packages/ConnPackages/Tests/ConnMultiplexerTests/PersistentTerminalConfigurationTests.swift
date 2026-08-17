import Foundation
import Testing
@testable import ConnMultiplexer

@Suite("Persistent terminal configuration")
struct PersistentTerminalConfigurationTests {
    @Test("configuration and attachment descriptor round-trip without database identity")
    func descriptorRoundTrip() throws {
        let configuration = PersistentTerminalConfiguration(
            providerID: "fake",
            configurationKey: "default",
            payloadVersion: 1,
            providerPayload: Data(#"{"mode":"default"}"#.utf8)
        )
        let workspace = RemoteWorkspaceRef(
            workspaceID: "workspace-1",
            instancePayloadVersion: 1,
            providerInstancePayload: Data("instance".utf8)
        )
        let descriptor = PersistentAttachmentDescriptor(
            providerID: "fake",
            configuration: configuration,
            workspace: workspace,
            payloadVersion: 1,
            providerPayload: Data("attachment".utf8)
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(PersistentAttachmentDescriptor.self, from: data)

        #expect(decoded == descriptor)
        #expect(decoded.configuration == configuration)
    }
}
