import Testing
@testable import ConnEntitlement

@Suite("Conn Pro 权益规则")
struct EntitlementGateTests {
    @Test("免费版最多添加两台主机")
    func freeUserCanAddOnlyTwoHosts() {
        let gate = EntitlementGate(snapshot: .free)

        #expect(gate.canAddHost(currentCount: 0))
        #expect(gate.canAddHost(currentCount: 1))
        #expect(!gate.canAddHost(currentCount: 2))
        #expect(!gate.canAddHost(currentCount: 3))
    }

    @Test("Pro 不限制主机数量")
    func proUserCanAddAnyHostCount() {
        let gate = EntitlementGate(snapshot: .pro)

        #expect(gate.canAddHost(currentCount: 2))
        #expect(gate.canAddHost(currentCount: 100))
    }

    @Test("免费版保留连接、进程、日志和单主机执行")
    func freeKeepsCoreOperations() {
        let gate = EntitlementGate(snapshot: .free)

        #expect(gate.allowed(.terminal))
        #expect(gate.allowed(.processControl))
        #expect(gate.allowed(.logCenter))
        #expect(gate.allowed(.singleHostExecution))
    }

    @Test("文件、Docker 和批量执行仅属于 Pro")
    func proOnlyOperationsAreGated() {
        let free = EntitlementGate(snapshot: .free)
        let pro = EntitlementGate(snapshot: .pro)

        for feature in [
            EntitlementFeature.fileManagement,
            .dockerManagement,
            .batchExecution,
        ] {
            #expect(!free.allowed(feature))
            #expect(pro.allowed(feature))
        }
    }
}
