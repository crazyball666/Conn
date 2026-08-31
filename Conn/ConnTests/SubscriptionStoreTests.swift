import Testing
import ConnEntitlement
@testable import Conn

@Suite("Conn Pro 订阅状态")
@MainActor
struct SubscriptionStoreTests {
    @Test("固定免费状态不授予 Pro")
    func fixedFreeStateIsNotPro() {
        let store = SubscriptionStore.fixed(.free)

        #expect(store.status == .free)
        #expect(!store.isPro)
        #expect(store.gate.canAddHost(currentCount: 2) == false)
    }

    @Test("固定 Pro 状态授予全部高级权益")
    func fixedProStateIsPro() {
        let store = SubscriptionStore.fixed(.pro)

        #expect(store.status == .pro)
        #expect(store.isPro)
        #expect(store.gate.canAddHost(currentCount: 100))
        #expect(store.gate.allowed(.fileManagement))
        #expect(store.gate.allowed(.dockerManagement))
        #expect(store.gate.allowed(.batchExecution))
    }

    @Test("商品标识保持稳定")
    func productIdentifiersAreStable() {
        #expect(SubscriptionStore.monthlyProductID == "com.crazyball.conn.pro.monthly")
        #expect(SubscriptionStore.yearlyProductID == "com.crazyball.conn.pro.yearly")
    }

    @Test("付费入口映射到对应 Pro 权益")
    func paywallContextsMapToEntitlements() {
        #expect(PaywallContext.thirdHost.feature == nil)
        #expect(PaywallContext.fileManagement.feature == .fileManagement)
        #expect(PaywallContext.dockerManagement.feature == .dockerManagement)
        #expect(PaywallContext.batchExecution.feature == .batchExecution)
    }

    @Test("演示状态显示确定的价格兜底")
    func fallbackPricesAreStable() {
        let store = SubscriptionStore.fixed(.free)
        #expect(store.fallbackPrice(for: .monthly) == "¥18/月")
        #expect(store.fallbackPrice(for: .yearly) == "¥98/年")
    }
}
