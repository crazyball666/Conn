import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Testing
@testable import Conn

@MainActor
@Suite("Docker Compose App 模型")
struct DockerComposeModelTests {
    @Test("手动项目在 Compose 子模型重建后仍与自动发现项目合并")
    func manualProjectsSurviveModelRecreation() async throws {
        let automaticJSON = """
        [{"Name":"auto","Status":"running(1)","ConfigFiles":"/srv/auto/compose.yml"}]
        """
        let session = try await mockSession(responses: [
            DockerCommand.composeVersion(.v2, sudo: false): .init(stdout: "Docker Compose version v2.0"),
            DockerCommand.composeProjects(sudo: false): .init(stdout: automaticJSON),
            DockerCommand.composeContainers(sudo: false): .init(stdout: "")
        ])
        let registry = DockerComposeRegistry()
        let manual = try #require(
            DockerComposeManualDraft(configFile: "/srv/manual/compose.yml").project
        )
        registry.upsertManual(manual)
        let context = makeContext(session: session)

        let first = DockerComposeModel(context: context, registry: registry)
        await first.load()
        let rebuilt = DockerComposeModel(context: context, registry: registry)
        await rebuilt.load()

        #expect(first.items.map(\.name) == ["auto", "manual"])
        #expect(rebuilt.items.map(\.name) == ["auto", "manual"])
        #expect(rebuilt.dialect == .v2)
        #expect(rebuilt.errorMessage == nil)
    }

    @Test("自动发现失败时保留 registry 的上次成功快照")
    func discoveryFailureKeepsLastSnapshot() async throws {
        let registry = DockerComposeRegistry()
        registry.replaceDiscovered([
            DockerComposeProject(
                name: "last-known", state: .running,
                configFiles: ["/srv/app/compose.yml"], projectDirectory: "/srv/app",
                source: .automatic
            )
        ])
        let session = try await mockSession(responses: [
            DockerCommand.composeVersion(.v2, sudo: false): .init(stdout: "v2"),
            DockerCommand.composeProjects(sudo: false): .init(
                stderr: "daemon unavailable", exitCode: 1
            ),
            DockerCommand.composeContainers(sudo: false): .init(
                stderr: "daemon unavailable", exitCode: 1
            )
        ])
        let model = DockerComposeModel(
            context: makeContext(session: session),
            registry: registry
        )

        await model.load()

        #expect(model.items.map(\.name) == ["last-known"])
        #expect(model.errorMessage != nil)
    }

    @Test("手动添加项目先读取远端服务，成功后才进入会话 registry")
    func manualProjectRequiresRemoteValidation() async throws {
        let draft = DockerComposeManualDraft(
            configFile: "/srv/manual/compose.yml",
            projectDirectory: "/srv/manual",
            projectName: "manual"
        )
        let project = try #require(draft.project)
        let session = try await mockSession(responses: [
            DockerCommand.composeVersion(.v2, sudo: false): .init(stdout: "Docker Compose version v2.0"),
            DockerCommand.composeProjects(sudo: false): .init(stdout: "[]"),
            DockerCommand.composeContainers(sudo: false): .init(stdout: ""),
            DockerCommand.composeConfigServices(project, dialect: .v2, sudo: false): .init(stdout: "api\nworker\n"),
            DockerCommand.composeContainers(projectName: "manual", sudo: false): .init(stdout: "")
        ])
        let registry = DockerComposeRegistry()
        let model = DockerComposeModel(
            context: makeContext(session: session),
            registry: registry
        )

        await model.load()
        let added = await model.addManualProject(draft)

        #expect(added)
        #expect(model.items.count == 1)
        #expect(model.items[0].name == "manual")
        #expect(model.items[0].serviceCount == 2)
        #expect(model.items[0].source == .manual)
    }

    @Test("Compose down 后保留项目配置供再次启动")
    func retainedProjectSurvivesDiscoveryDisappearance() throws {
        let registry = DockerComposeRegistry()
        let automatic = DockerComposeProject(
            name: "web",
            state: .running,
            configFiles: ["/srv/web/compose.yml"],
            projectDirectory: "/srv/web",
            source: .automatic,
            serviceCount: 2,
            containerCount: 2,
            runningContainerCount: 2
        )
        registry.replaceDiscovered([automatic])

        registry.preserveForRestart(automatic)
        registry.replaceDiscovered([])

        let retained = try #require(registry.projects.first)
        #expect(retained.name == "web")
        #expect(retained.configFiles == ["/srv/web/compose.yml"])
        #expect(retained.source == .manual)
        #expect(retained.state == .stopped)
        #expect(retained.containerCount == 0)
        #expect(retained.runningContainerCount == 0)
    }

    private func makeContext(session: any SSHSession) -> DockerContext {
        DockerContext(
            session: { session },
            sudo: false,
            isUsable: true,
            report: { _ in },
            refresh: { _ in },
            reprobe: {}
        )
    }

    private func mockSession(
        responses: [String: MockSSHTransport.CommandResponse]
    ) async throws -> any SSHSession {
        let transport = MockSSHTransport(
            behavior: .init(commandResponses: responses)
        )
        return try await transport.connect(
            SSHEndpoint(host: "compose.test", port: 22),
            username: "root",
            auth: .password(""),
            hostKeyPolicy: .tofu
        )
    }
}
