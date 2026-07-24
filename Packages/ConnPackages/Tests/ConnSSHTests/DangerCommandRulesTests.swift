import Testing
@testable import ConnSSH

@Suite("DangerCommandRules — 危险命令拦截")
struct DangerCommandRulesTests {
    @Test("rm -rf / 判为危险")
    func rmRootIsDangerous() {
        #expect(DangerCommandRules.evaluate("rm -rf /", isProduction: false).isDangerous)
        #expect(DangerCommandRules.evaluate("rm -rf /*", isProduction: false).isDangerous)
        #expect(DangerCommandRules.evaluate("sudo rm -rf /", isProduction: false).isDangerous)
    }

    @Test("rm -rf 子目录不判危险（只拦根/家目录级）")
    func rmSubdirNotDangerous() {
        #expect(!DangerCommandRules.evaluate("rm -rf /tmp/build", isProduction: false).isDangerous)
        #expect(!DangerCommandRules.evaluate("rm -rf ./node_modules", isProduction: false).isDangerous)
    }

    @Test("mkfs 格式化判为危险")
    func mkfsIsDangerous() {
        #expect(DangerCommandRules.evaluate("mkfs.ext4 /dev/sda1", isProduction: false).isDangerous)
        #expect(DangerCommandRules.evaluate("mkfs -t ext4 /dev/sdb", isProduction: false).isDangerous)
    }

    @Test("dd 写块设备判为危险")
    func ddToDeviceIsDangerous() {
        #expect(DangerCommandRules.evaluate("dd if=/dev/zero of=/dev/sda", isProduction: false).isDangerous)
    }

    @Test("fork bomb 判为危险")
    func forkBombIsDangerous() {
        #expect(DangerCommandRules.evaluate(":(){ :|:& };:", isProduction: false).isDangerous)
    }

    @Test("dev 全盘覆写与 mkfs on whole disk")
    func overwriteDisk() {
        #expect(DangerCommandRules.evaluate("> /dev/sda", isProduction: false).isDangerous)
    }

    @Test("普通命令不判危险")
    func normalCommandsSafe() {
        #expect(!DangerCommandRules.evaluate("ls -la", isProduction: false).isDangerous)
        #expect(!DangerCommandRules.evaluate("systemctl restart nginx", isProduction: false).isDangerous)
        #expect(!DangerCommandRules.evaluate("docker ps", isProduction: false).isDangerous)
    }

    @Test("生产环境的重启/停止类命令需确认（即使本身不致命）")
    func productionSensitiveCommands() {
        let verdict = DangerCommandRules.evaluate("systemctl stop nginx", isProduction: true)
        #expect(verdict.needsConfirmation)
        // 非生产环境同一命令不需确认
        #expect(!DangerCommandRules.evaluate("systemctl stop nginx", isProduction: false).needsConfirmation)
    }

    @Test("危险命令在任何环境都需确认")
    func dangerousAlwaysNeedsConfirmation() {
        #expect(DangerCommandRules.evaluate("rm -rf /", isProduction: false).needsConfirmation)
        #expect(DangerCommandRules.evaluate("rm -rf /", isProduction: true).needsConfirmation)
    }

    @Test("命中规则时给出可读原因")
    func providesReason() {
        let verdict = DangerCommandRules.evaluate("rm -rf /", isProduction: false)
        #expect(verdict.reason != nil)
    }

    @Test("docker prune 任何环境都需确认（#8）")
    func dockerPruneFlagged() {
        #expect(DangerCommandRules.evaluate("docker image prune -f", isProduction: false).needsConfirmation)
        #expect(DangerCommandRules.evaluate("docker system prune -af --volumes", isProduction: false).needsConfirmation)
        #expect(DangerCommandRules.evaluate("docker container prune", isProduction: false).needsConfirmation)
    }

    @Test("find -delete 任何环境都需确认（#8）")
    func findDeleteFlagged() {
        #expect(DangerCommandRules.evaluate("find /var/log -name '*.log' -mtime +30 -delete", isProduction: false).needsConfirmation)
    }

    @Test("普通 find / docker 不误报")
    func benignNotFlagged() {
        #expect(!DangerCommandRules.evaluate("find /var/log -name '*.log'", isProduction: false).needsConfirmation)
        #expect(!DangerCommandRules.evaluate("docker ps -a", isProduction: false).needsConfirmation)
    }
}
