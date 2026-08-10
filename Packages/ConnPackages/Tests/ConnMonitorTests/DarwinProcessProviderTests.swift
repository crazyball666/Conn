import ConnKit
import Testing
@testable import ConnMonitor

@Suite("Darwin process provider")
struct DarwinProcessProviderTests {
    @Test("命令只使用 BSD ps 支持的字段")
    func commandUsesBSDPS() {
        let command = DarwinProcessProvider().command

        #expect(command.contains("ps -axo"))
        #expect(!command.contains("--sort"))
        #expect(!command.contains("nlwp"))
        #expect(!command.contains("top -bn1"))
    }

    @Test("解析字段、跳过坏行并按 CPU 降序")
    func parsesAndSorts() {
        let processes = DarwinProcessProvider().parse(Self.output)

        #expect(processes.map(\.pid) == [234, 567, 1])
        #expect(processes[0].ppid == 1)
        #expect(processes[0].user == "www-data")
        #expect(processes[0].command == "nginx")
        #expect(processes[0].fullCommand == "/usr/local/bin/nginx -g daemon off;")
        #expect(processes[0].cpu == 12.5)
        #expect(processes[0].mem == 4.2)
        #expect(processes[0].memBytes == Int64(120_000 * 1024))
        #expect(processes[0].state == "S")
        #expect(processes[0].elapsedSeconds == 8_130)
        #expect(processes[0].threads == nil)
    }

    @Test("Darwin 明确报告线程数字段降级")
    func reportsMissingThreads() {
        guard case let .degraded(issues) = DarwinProcessProvider().capabilityState else {
            Issue.record("expected degraded process capability")
            return
        }
        #expect(issues.contains { $0.code == .partialData && $0.fields.contains("threadCount") })
    }

    private static let output = """
    __CONN_DARWIN_PROCESS_PS__
      PID  PPID USER      %CPU %MEM    RSS STAT     ELAPSED COMMAND
        1     0 root       0.0  0.1   8500 Ss      10-00:00:00 /sbin/launchd
      malformed process row
      234     1 www-data  12.5  4.2 120000 S          02:15:30 /usr/local/bin/nginx -g daemon off;
      567     1 mysql      8.1  2.0 512000 S       5-00:00:00 /usr/local/mysql/bin/mysqld --daemonize
    __CONN_DARWIN_PROCESS_END__
    """
}
