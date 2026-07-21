import Testing
@testable import ConnKit

@Suite("SSHCommandParser — ssh 命令粘贴识别")
struct SSHCommandParserTests {
    @Test("裸主机：ssh example.com")
    func bareHost() {
        let draft = SSHCommandParser.parse("ssh example.com")
        #expect(draft?.address == "example.com")
        #expect(draft?.port == 22)
        #expect(draft?.username == "")
    }

    @Test("含用户名：ssh root@1.2.3.4")
    func userAtHost() {
        let draft = SSHCommandParser.parse("ssh root@1.2.3.4")
        #expect(draft?.username == "root")
        #expect(draft?.address == "1.2.3.4")
        #expect(draft?.port == 22)
    }

    @Test("含端口：ssh root@1.2.3.4 -p 2222")
    func customPort() {
        let draft = SSHCommandParser.parse("ssh root@1.2.3.4 -p 2222")
        #expect(draft?.username == "root")
        #expect(draft?.address == "1.2.3.4")
        #expect(draft?.port == 2222)
    }

    @Test("端口与用户名乱序：ssh -p 2222 deploy@host")
    func portBeforeHost() {
        let draft = SSHCommandParser.parse("ssh -p 2222 deploy@host")
        #expect(draft?.username == "deploy")
        #expect(draft?.address == "host")
        #expect(draft?.port == 2222)
    }

    @Test("含密钥文件：ssh -i ~/.ssh/id_ed25519 root@host 识别认证方式为密钥")
    func identityFile() {
        let draft = SSHCommandParser.parse("ssh -i ~/.ssh/id_ed25519 root@host")
        #expect(draft?.address == "host")
        #expect(draft?.authKind == .key)
    }

    @Test("URL 形式：ssh://deploy@10.0.0.1:2202")
    func sshURL() {
        let draft = SSHCommandParser.parse("ssh://deploy@10.0.0.1:2202")
        #expect(draft?.username == "deploy")
        #expect(draft?.address == "10.0.0.1")
        #expect(draft?.port == 2202)
    }

    @Test("IPv6 地址：ssh root@[2001:db8::1] -p 22")
    func ipv6Host() {
        let draft = SSHCommandParser.parse("ssh root@[2001:db8::1] -p 2222")
        #expect(draft?.address == "2001:db8::1")
        #expect(draft?.port == 2222)
    }

    @Test("首尾空白与多余空格被容忍")
    func toleratesWhitespace() {
        let draft = SSHCommandParser.parse("   ssh    root@host   -p   2222  ")
        #expect(draft?.username == "root")
        #expect(draft?.port == 2222)
    }

    @Test("非 ssh 命令返回 nil")
    func nonSSHReturnsNil() {
        #expect(SSHCommandParser.parse("hello world") == nil)
        #expect(SSHCommandParser.parse("scp file host:") == nil)
        #expect(SSHCommandParser.parse("") == nil)
    }

    @Test("缺少主机的 ssh 返回 nil")
    func missingHostReturnsNil() {
        #expect(SSHCommandParser.parse("ssh -p 2222") == nil)
        #expect(SSHCommandParser.parse("ssh") == nil)
    }

    @Test("非法端口返回 nil")
    func invalidPortReturnsNil() {
        #expect(SSHCommandParser.parse("ssh host -p abc") == nil)
        #expect(SSHCommandParser.parse("ssh host -p 99999") == nil)
    }
}
