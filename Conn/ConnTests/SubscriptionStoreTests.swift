import Testing
import ConnEntitlement
@testable import Conn

@Suite("Conn Pro 订阅状态")
@MainActor
struct SubscriptionStoreTests {
    @Test("默认订阅状态由编译配置决定")
    func appDefaultSubscriptionFollowsCompilationFlag() {
        let store = SubscriptionStore.appDefault()

        #if DEBUG && CONN_DISABLE_SUBSCRIPTION
            #expect(store.status == .pro)
            #expect(store.isPro)
            #expect(store.gate.canAddHost(currentCount: 100))
            #expect(store.gate.allowed(.fileManagement))
            #expect(store.gate.allowed(.dockerManagement))
            #expect(store.gate.allowed(.batchExecution))
        #else
            #expect(store.status == .loading)
            #expect(!store.isPro)
        #endif
    }

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

    @Test("已有 Pro 权益时不应再次发起购买")
    func proStateDoesNotStartAnotherPurchase() async {
        let store = SubscriptionStore.fixed(.pro)

        #expect(await store.purchase(.monthly) == .unavailable)
    }

    @Test("商店已确认 Pro 权益时不应再次发起购买")
    func activeEntitlementDoesNotStartAnotherPurchase() async {
        let provider = TestSubscriptionProvider(hasEntitlement: true)
        let store = SubscriptionStore.live(provider: provider)

        await store.refresh()
        #expect(store.isPro)
        #expect(await store.purchase(.monthly) == .unavailable)
        #expect(provider.purchaseCalls.isEmpty)
    }

    @Test("权益失效后应回到免费状态")
    func revokedEntitlementReturnsToFree() async {
        let provider = TestSubscriptionProvider(hasEntitlement: true)
        let store = SubscriptionStore.live(provider: provider)

        await store.refresh()
        #expect(store.isPro)

        provider.hasEntitlement = false
        await store.refresh()

        #expect(!store.isPro)
        #expect(store.status == .free)
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

    @Test("商品加载失败不应撤销已确认的 Pro 权益")
    func productLoadingFailureDoesNotRevokeExistingPro() async {
        let provider = TestSubscriptionProvider(
            hasEntitlement: true,
            productLoadError: true
        )
        let store = SubscriptionStore.live(provider: provider)

        await store.refresh()

        #expect(store.isPro)
        #expect(store.lastError == .productLoadFailed)
    }

    @Test("商品未加载时不能发起购买")
    func missingProductsCannotStartPurchase() async {
        let provider = TestSubscriptionProvider(products: [])
        let store = SubscriptionStore.live(provider: provider)

        await store.refresh()
        let result = await store.purchase(.monthly)

        #expect(result == .unavailable)
        #expect(provider.purchaseCalls.isEmpty)
    }

    @Test("购买期间的外部刷新不会覆盖购买状态")
    func externalRefreshDoesNotRaceWithPurchase() async {
        let provider = TestSubscriptionProvider(
            hasEntitlement: false,
            purchaseOutcome: .purchased
        )
        provider.waitForPurchase = true
        let store = SubscriptionStore.live(provider: provider)

        await store.refresh()
        let purchaseTask = Task { await store.purchase(.monthly) }
        for _ in 0..<100 {
            if provider.isPurchaseBlocked { break }
            await Task.yield()
        }

        #expect(provider.isPurchaseBlocked)
        let entitlementCallsBeforeRefresh = provider.entitlementCalls
        await store.refresh()
        #expect(provider.entitlementCalls == entitlementCallsBeforeRefresh)

        provider.releasePurchase()
        #expect(await purchaseTask.value == .purchased)
        #expect(store.isPro)
    }

    @Test("已验证购买立即授予 Pro，即使随后权益刷新尚未同步")
    func successfulPurchaseGrantsProImmediately() async {
        let provider = TestSubscriptionProvider(
            hasEntitlement: false,
            purchaseOutcome: .purchased
        )
        let store = SubscriptionStore.live(provider: provider)

        await store.refresh()
        let result = await store.purchase(.monthly)

        #expect(result == .purchased)
        #expect(store.isPro)
        #expect(provider.purchaseCalls == [SubscriptionStore.monthlyProductID])
    }

    @Test("恢复同步失败时返回明确失败结果")
    func restoreFailureIsReported() async {
        let provider = TestSubscriptionProvider(syncError: true)
        let store = SubscriptionStore.live(provider: provider)

        let result = await store.restore()

        #expect(result == .failed)
        #expect(store.lastError == .restoreFailed)
    }

    @Test("恢复购买无有效权益时返回明确结果")
    func restoreWithoutEntitlementIsReported() async {
        let provider = TestSubscriptionProvider(hasEntitlement: false)
        let store = SubscriptionStore.live(provider: provider)

        #expect(await store.restore() == .noActiveSubscription)
        #expect(!store.isPro)
    }

    @Test("未验证交易更新不应授予 Pro")
    func unverifiedTransactionDoesNotGrantPro() async {
        let provider = TestSubscriptionProvider(hasEntitlement: false)
        let store = SubscriptionStore.live(provider: provider)
        store.start()
        await Task.yield()

        provider.emit(.unverified)
        await Task.yield()

        #expect(!store.isPro)
    }

    @Test("交易更新会刷新当前权益")
    func verifiedTransactionUpdateRefreshesEntitlement() async {
        let provider = TestSubscriptionProvider(hasEntitlement: false)
        let store = SubscriptionStore.live(provider: provider)
        store.start()
        await Task.yield()

        provider.hasEntitlement = true
        provider.emit(.verified(productID: SubscriptionStore.yearlyProductID))
        await Task.yield()
        await Task.yield()

        #expect(store.isPro)
    }
}

@MainActor
private final class TestSubscriptionProvider: SubscriptionStoreProvider {
    var products: [SubscriptionProduct]
    var hasEntitlement: Bool
    var purchaseOutcome: SubscriptionPurchaseOutcome
    var productLoadError: Bool
    var syncError: Bool
    var waitForPurchase = false
    private(set) var isPurchaseBlocked = false
    private(set) var entitlementCalls = 0
    private(set) var purchaseCalls: [String] = []
    private var updateContinuation: AsyncStream<SubscriptionTransactionUpdate>.Continuation?
    private var purchaseContinuation: CheckedContinuation<Void, Never>?

    init(
        products: [SubscriptionProduct]? = nil,
        hasEntitlement: Bool = false,
        purchaseOutcome: SubscriptionPurchaseOutcome = .cancelled,
        productLoadError: Bool = false,
        syncError: Bool = false
    ) {
        self.products = products ?? [
            SubscriptionProduct(id: SubscriptionStore.monthlyProductID, displayPrice: "¥18/month"),
            SubscriptionProduct(id: SubscriptionStore.yearlyProductID, displayPrice: "¥98/year"),
        ]
        self.hasEntitlement = hasEntitlement
        self.purchaseOutcome = purchaseOutcome
        self.productLoadError = productLoadError
        self.syncError = syncError
    }

    func loadProducts(for productIDs: [String]) async throws -> [SubscriptionProduct] {
        if productLoadError { throw TestSubscriptionProviderError.productLoad }
        return products.filter { productIDs.contains($0.id) }
    }

    func hasActiveEntitlement(for productIDs: [String]) async -> Bool {
        entitlementCalls += 1
        return hasEntitlement
    }

    func purchase(productID: String) async throws -> SubscriptionPurchaseOutcome {
        purchaseCalls.append(productID)
        if waitForPurchase {
            isPurchaseBlocked = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                purchaseContinuation = continuation
            }
            isPurchaseBlocked = false
        }
        return purchaseOutcome
    }

    func synchronize() async throws {
        if syncError { throw TestSubscriptionProviderError.synchronize }
    }

    func transactionUpdates() -> AsyncStream<SubscriptionTransactionUpdate> {
        AsyncStream { continuation in
            updateContinuation = continuation
        }
    }

    func emit(_ update: SubscriptionTransactionUpdate) {
        updateContinuation?.yield(update)
    }

    func releasePurchase() {
        purchaseContinuation?.resume()
        purchaseContinuation = nil
    }
}

private enum TestSubscriptionProviderError: Error {
    case productLoad
    case synchronize
}
