import Testing
import ConnEntitlement
import ConnKit
@testable import Conn

@Suite("脚本执行订阅权限")
struct SnippetEntitlementPolicyTests {
    @Test("免费版执行 Docker 片段时需要升级")
    func dockerSnippetRequiresPro() {
        let snippet = Snippet(
            title: "Docker",
            script: "docker ps",
            requiredCapabilities: [.docker]
        )

        #expect(
            SnippetEntitlementPolicy.blockedFeature(
                for: snippet,
                hostCount: 1,
                mode: .silent,
                gate: EntitlementGate(snapshot: .free)
            ) == .dockerManagement
        )
    }

    @Test("免费版单主机普通脚本仍可执行")
    func regularSingleHostSnippetRemainsAvailable() {
        let snippet = Snippet(title: "健康检查", script: "uname -a")

        #expect(
            SnippetEntitlementPolicy.blockedFeature(
                for: snippet,
                hostCount: 1,
                mode: .silent,
                gate: EntitlementGate(snapshot: .free)
            ) == nil
        )
    }

    @Test("免费版批量执行需要升级，Pro 不受限")
    func batchExecutionRequiresPro() {
        let snippet = Snippet(title: "健康检查", script: "uname -a")

        #expect(
            SnippetEntitlementPolicy.blockedFeature(
                for: snippet,
                hostCount: 2,
                mode: .silent,
                gate: EntitlementGate(snapshot: .free)
            ) == .batchExecution
        )
        #expect(
            SnippetEntitlementPolicy.blockedFeature(
                for: snippet,
                hostCount: 2,
                mode: .silent,
                gate: EntitlementGate(snapshot: .pro)
            ) == nil
        )
    }
}
