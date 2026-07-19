import Foundation
import Testing
@testable import ConnKit

@Suite("Host 领域模型")
struct HostTests {
    @Test("新建主机带默认值：端口 22、状态 unknown、时间戳自动填充")
    func newHostDefaults() {
        let host = Host(name: "web-01", address: "10.0.0.1", username: "root")
        #expect(host.port == 22)
        #expect(host.status == .unknown)
        #expect(host.authKind == .key)
        #expect(host.createdAt > 0)
        #expect(host.createdAt == host.updatedAt)
        #expect(host.deletedAt == nil)
        #expect(host.syncDirty == false)
    }

    @Test("displayAddress 组合 user@address:port，标准端口省略")
    func displayAddressOmitsDefaultPort() {
        let standard = Host(name: "a", address: "10.0.0.1", username: "root")
        #expect(standard.displayAddress == "root@10.0.0.1")

        let custom = Host(name: "b", address: "10.0.0.2", username: "deploy", port: 2222)
        #expect(custom.displayAddress == "deploy@10.0.0.2:2222")
    }

    @Test("isProduction 由 prod 标签判定，大小写不敏感")
    func productionDetection() {
        #expect(Host(name: "a", address: "1", username: "r", tags: ["web", "prod"]).isProduction)
        #expect(Host(name: "b", address: "1", username: "r", tags: ["PROD"]).isProduction)
        #expect(!Host(name: "c", address: "1", username: "r", tags: ["staging"]).isProduction)
    }

    @Test("跳板链默认为空，usesJumpHost 随之为 false")
    func emptyJumpChainByDefault() {
        let host = Host(name: "a", address: "1", username: "r")
        #expect(host.jumpChain.isEmpty)
        #expect(!host.usesJumpHost)

        let viaBastion = Host(name: "b", address: "1", username: "r", jumpChain: ["bastion"])
        #expect(viaBastion.usesJumpHost)
    }
}
