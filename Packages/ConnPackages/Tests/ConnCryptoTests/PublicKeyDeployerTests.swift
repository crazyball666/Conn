import Testing
@testable import ConnCrypto

@Suite("PublicKeyDeployer — 一键部署命令")
struct PublicKeyDeployerTests {
    private let pubkey = "ssh-ed25519 AAAAC3Nz...abc conn@device"

    @Test("部署命令幂等：grep 去重后再追加")
    func deployIsIdempotent() {
        let command = PublicKeyDeployer.deployCommand(publicKeyOpenSSH: pubkey)
        #expect(command.contains("grep -qF"))
        #expect(command.contains("|| echo"))
        #expect(command.contains(">> ~/.ssh/authorized_keys"))
    }

    @Test("部署命令设置正确权限（.ssh 700、authorized_keys 600）")
    func deploySetsPermissions() {
        let command = PublicKeyDeployer.deployCommand(publicKeyOpenSSH: pubkey)
        #expect(command.contains("chmod 700 ~/.ssh"))
        #expect(command.contains("chmod 600 ~/.ssh/authorized_keys"))
    }

    @Test("公钥被单引号包裹")
    func quotesPublicKey() {
        let command = PublicKeyDeployer.deployCommand(publicKeyOpenSSH: pubkey)
        #expect(command.contains("'\(pubkey)'"))
    }

    @Test("含单引号的公钥被安全转义")
    func escapesSingleQuotes() {
        let quoted = PublicKeyDeployer.shellSingleQuote("a'b")
        #expect(quoted == "'a'\\''b'")
    }

    @Test("移除命令过滤掉该公钥行")
    func removeFiltersKey() {
        let command = PublicKeyDeployer.removeCommand(publicKeyOpenSSH: pubkey)
        #expect(command.contains("grep -vF"))
        #expect(command.contains("mv ~/.ssh/ak.tmp ~/.ssh/authorized_keys"))
    }
}
