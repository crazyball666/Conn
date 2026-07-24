import Testing
@testable import ConnOps

struct DockerParserTests {
    private let psModern = """
    {"ID":"a1b2c3d4e5f6","Image":"nginx:1.25","Names":"nginx-proxy","Ports":"0.0.0.0:80->80/tcp","State":"running","Status":"Up 3 days"}
    {"ID":"f6e5d4c3b2a1","Image":"redis:7","Names":"redis-cache","State":"exited","Status":"Exited (0) 2 hours ago","Ports":""}
    """

    private let stats = """
    {"CPUPerc":"1.50%","ID":"a1b2c3d4e5f6","MemPerc":"3.20%","MemUsage":"12MiB / 2GiB","Name":"nginx-proxy"}
    """

    @Test("ps + stats 合并")
    func mergePSAndStats() {
        let containers = DockerParser.parse(psOutput: psModern, statsOutput: stats)
        #expect(containers.count == 2)
        let nginx = containers.first { $0.name == "nginx-proxy" }
        #expect(nginx?.state == .running)
        #expect(nginx?.image == "nginx:1.25")
        #expect(nginx?.ports == "0.0.0.0:80->80/tcp")
        #expect(nginx?.cpuPercent == 1.5)
        #expect(nginx?.memPercent == 3.2)
        #expect(nginx?.memUsage == "12MiB / 2GiB")
    }

    @Test("已停容器无 stats，cpu/mem 为 nil")
    func stoppedHasNoStats() {
        let containers = DockerParser.parse(psOutput: psModern, statsOutput: stats)
        let redis = containers.first { $0.name == "redis-cache" }
        #expect(redis?.state == .exited)
        #expect(redis?.cpuPercent == nil)
        #expect(redis?.isRunning == false)
    }

    @Test("旧版 docker 无 State 字段 → 从 Status 推断")
    func legacyStateInference() {
        let ps = """
        {"ID":"aaa111","Image":"busybox","Names":"box","Status":"Up 5 minutes","Ports":""}
        {"ID":"bbb222","Image":"alpine","Names":"job","Status":"Exited (0) 1 minute ago","Ports":""}
        """
        let containers = DockerParser.parse(psOutput: ps, statsOutput: "")
        #expect(containers.first { $0.id == "aaa111" }?.state == .running)
        #expect(containers.first { $0.id == "bbb222" }?.state == .exited)
    }

    @Test("坏行（docker warning）被跳过")
    func skipsMalformedLines() {
        let ps = """
        WARNING: Error loading config file
        {"ID":"ccc333","Image":"x","Names":"y","Status":"Up 1 hour"}
        """
        let containers = DockerParser.parse(psOutput: ps, statsOutput: "")
        #expect(containers.count == 1)
        #expect(containers.first?.id == "ccc333")
    }

    @Test("空输出 → 空列表，不崩")
    func emptyOutput() {
        #expect(DockerParser.parse(psOutput: "", statsOutput: "").isEmpty)
    }

    @Test("stats 用 64 位全 id、ps 用 12 位短 id 仍能合并（#11）")
    func mergesShortVsFullID() {
        let ps = #"{"ID":"a1b2c3d4e5f6","Image":"nginx","Names":"web","State":"running","Status":"Up 1h"}"#
        let fullID = "a1b2c3d4e5f6" + String(repeating: "0", count: 52) // 64 位
        let stats = #"{"ID":""# + fullID + #"","CPUPerc":"5.00%","MemPerc":"2.00%","MemUsage":"10MiB / 2GiB","Name":"web"}"#
        let containers = DockerParser.parse(psOutput: ps, statsOutput: stats)
        #expect(containers.first?.cpuPercent == 5.0)
        #expect(containers.first?.memPercent == 2.0)
    }
}
