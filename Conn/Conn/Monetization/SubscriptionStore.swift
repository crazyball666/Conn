import ConnEntitlement
import Foundation
import Observation
import StoreKit

struct SubscriptionProduct: Equatable, Sendable {
    let id: String
    let displayPrice: String
}

enum SubscriptionPurchaseOutcome: Equatable, Sendable {
    case purchased
    case pending
    case cancelled
    case failed
}

enum SubscriptionTransactionUpdate: Equatable, Sendable {
    case verified(productID: String)
    case unverified
}

@MainActor
protocol SubscriptionStoreProvider {
    func loadProducts(for productIDs: [String]) async throws -> [SubscriptionProduct]
    func hasActiveEntitlement(for productIDs: [String]) async -> Bool
    func purchase(productID: String) async throws -> SubscriptionPurchaseOutcome
    func synchronize() async throws
    func transactionUpdates() -> AsyncStream<SubscriptionTransactionUpdate>
}

private enum LiveSubscriptionProviderError: Error {
    case productUnavailable
}

@MainActor
private final class LiveSubscriptionStoreProvider: SubscriptionStoreProvider {
    private var products: [String: Product] = [:]

    func loadProducts(for productIDs: [String]) async throws -> [SubscriptionProduct] {
        let loaded = try await Product.products(for: productIDs)
        products = Dictionary(
            loaded.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return loaded.map { SubscriptionProduct(id: $0.id, displayPrice: $0.displayPrice) }
    }

    func hasActiveEntitlement(for productIDs: [String]) async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            if productIDs.contains(transaction.productID) {
                return true
            }
        }
        return false
    }

    func purchase(productID: String) async throws -> SubscriptionPurchaseOutcome {
        guard let product = products[productID] else {
            throw LiveSubscriptionProviderError.productUnavailable
        }

        switch try await product.purchase() {
        case let .success(.verified(transaction)):
            await transaction.finish()
            return .purchased
        case .success(.unverified):
            return .failed
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .failed
        }
    }

    func synchronize() async throws {
        try await AppStore.sync()
    }

    func transactionUpdates() -> AsyncStream<SubscriptionTransactionUpdate> {
        AsyncStream { continuation in
            Task { @MainActor in
                for await result in Transaction.updates {
                    switch result {
                    case let .verified(transaction):
                        await transaction.finish()
                        continuation.yield(.verified(productID: transaction.productID))
                    case .unverified:
                        continuation.yield(.unverified)
                    }
                }
                continuation.finish()
            }
        }
    }
}

/// App Store 订阅状态的唯一入口。
///
/// 商品加载、购买、恢复和交易更新都集中在这里，UI 只读取状态和权益门控，
/// 不直接依赖 StoreKit。`live` 是真实 StoreKit 流程；`fixed` 用于编译期免订阅构建和单元测试，
/// 注入确定的免费/Pro 状态。
@MainActor
@Observable
final class SubscriptionStore {
    enum Status: Equatable, Sendable {
        case loading
        case free
        case pro
        case unavailable
    }

    enum Plan: String, CaseIterable, Identifiable, Sendable {
        case monthly
        case yearly

        var id: String { rawValue }

        var productID: String {
            switch self {
            case .monthly: SubscriptionStore.monthlyProductID
            case .yearly: SubscriptionStore.yearlyProductID
            }
        }
    }

    enum PurchaseResult: Equatable, Sendable {
        case purchased
        case pending
        case cancelled
        case unavailable
        case failed
    }

    enum RestoreResult: Equatable, Sendable {
        case restored
        case noActiveSubscription
        case inProgress
        case failed
    }

    enum SubscriptionError: Equatable, Sendable {
        case productLoadFailed
        case purchaseFailed
        case restoreFailed
    }

    static let monthlyProductID = "com.crazyball.conn.pro.monthly"
    static let yearlyProductID = "com.crazyball.conn.pro.yearly"
    static let productIDs = [monthlyProductID, yearlyProductID]

    private(set) var status: Status
    private(set) var products: [String: SubscriptionProduct] = [:]
    private(set) var lastError: SubscriptionError?

    var isPro: Bool { status == .pro }

    var gate: EntitlementGate {
        EntitlementGate(snapshot: isPro ? .pro : .free)
    }

    @ObservationIgnored private let mode: Mode
    @ObservationIgnored private let provider: (any SubscriptionStoreProvider)?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var operationInFlight = false
    @ObservationIgnored private var refreshGeneration = 0

    private enum Mode {
        case live
        case fixed(EntitlementSnapshot)
    }

    private init(mode: Mode, provider: (any SubscriptionStoreProvider)? = nil) {
        self.mode = mode
        self.provider = provider
        switch mode {
        case .live:
            status = .loading
        case let .fixed(snapshot):
            status = snapshot == .pro ? .pro : .free
        }
    }

    static func live() -> SubscriptionStore {
        SubscriptionStore(mode: .live, provider: LiveSubscriptionStoreProvider())
    }

    static func live(provider: any SubscriptionStoreProvider) -> SubscriptionStore {
        SubscriptionStore(mode: .live, provider: provider)
    }

    /// App 默认订阅策略由编译配置决定：正式构建默认启用订阅；
    /// Debug 构建可通过测试环境变量或编译宏注入确定的订阅状态。
    static func appDefault() -> SubscriptionStore {
        #if DEBUG
            switch ProcessInfo.processInfo.environment["CONN_SUBSCRIPTION_STATE"] {
            case "pro": return .fixed(.pro)
            case "free": return .fixed(.free)
            default: break
            }
        #endif
        #if DEBUG && CONN_DISABLE_SUBSCRIPTION
            return .fixed(.pro)
        #else
            return .live()
        #endif
    }

    static func fixed(_ snapshot: EntitlementSnapshot) -> SubscriptionStore {
        SubscriptionStore(mode: .fixed(snapshot))
    }

    deinit {
        updatesTask?.cancel()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard case .live = mode else { return }

        updatesTask = Task { [weak self] in
            await self?.observeTransactionUpdates()
        }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func refresh() async {
        // 购买或恢复期间，前后台切换和交易监听可能同时请求刷新。
        // 忽略这次外部刷新，避免旧的商店快照覆盖当前操作结果；操作流程会在关键节点自行对账。
        guard !operationInFlight else { return }
        await refreshState()
    }

    private func refreshState() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration

        switch mode {
        case let .fixed(snapshot):
            guard generation == refreshGeneration else { return }
            status = snapshot == .pro ? .pro : .free
            lastError = nil
        case .live:
            guard let provider else {
                guard generation == refreshGeneration else { return }
                status = .unavailable
                lastError = .productLoadFailed
                return
            }

            // 权益查询独立于商品价格加载，避免已购买用户因商店暂时不可用而丢失 Pro。
            let hasEntitlement = await provider.hasActiveEntitlement(for: Self.productIDs)
            guard generation == refreshGeneration else { return }

            do {
                let loaded = try await provider.loadProducts(for: Self.productIDs)
                let loadedProducts = Dictionary(
                    loaded.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let hasAllProducts = Set(loadedProducts.keys) == Set(Self.productIDs)
                guard generation == refreshGeneration else { return }
                products = loadedProducts
                status = hasEntitlement ? .pro : (hasAllProducts ? .free : .unavailable)
                lastError = hasAllProducts ? nil : .productLoadFailed
            } catch {
                guard generation == refreshGeneration else { return }
                products = [:]
                status = hasEntitlement ? .pro : .unavailable
                lastError = .productLoadFailed
            }
        }
    }

    func purchase(_ plan: Plan) async -> PurchaseResult {
        guard case .live = mode, let provider else {
            return .unavailable
        }
        guard !operationInFlight else { return .unavailable }
        operationInFlight = true
        // 让已经在后台执行的旧刷新失效，避免它在购买完成后覆盖当前结果。
        refreshGeneration &+= 1
        defer { operationInFlight = false }

        guard !isPro else { return .unavailable }

        // 购买前再次读取权益，避免页面状态尚未完成刷新时重复调用 StoreKit。
        if await provider.hasActiveEntitlement(for: Self.productIDs) {
            status = .pro
            lastError = nil
            return .unavailable
        }

        if status != .free || products[plan.productID] == nil {
            await refreshState()
        }
        guard status == .free, products[plan.productID] != nil else {
            return .unavailable
        }

        do {
            switch try await provider.purchase(productID: plan.productID) {
            case .purchased:
                // 已完成验证的交易立即授予本次运行时权益；后续刷新负责和商店状态对账。
                status = .pro
                lastError = nil
                await refreshState()
                status = .pro
                return .purchased
            case .pending:
                return .pending
            case .cancelled:
                return .cancelled
            case .failed:
                lastError = .purchaseFailed
                return .failed
            }
        } catch {
            lastError = .purchaseFailed
            return .failed
        }
    }

    func restore() async -> RestoreResult {
        guard case .live = mode, let provider else {
            return isPro ? .restored : .noActiveSubscription
        }
        guard !operationInFlight else { return .inProgress }
        operationInFlight = true
        // 恢复流程同样不能被前后台切换触发的旧刷新覆盖。
        refreshGeneration &+= 1
        defer { operationInFlight = false }

        do {
            try await provider.synchronize()
            await refreshState()
            return isPro ? .restored : .noActiveSubscription
        } catch {
            lastError = .restoreFailed
            return .failed
        }
    }

    func product(for plan: Plan) -> SubscriptionProduct? {
        products[plan.productID]
    }

    private func observeTransactionUpdates() async {
        guard let provider else { return }
        for await update in provider.transactionUpdates() {
            guard case let .verified(productID) = update,
                  Self.productIDs.contains(productID)
            else { continue }
            await refresh()
        }
    }
}
