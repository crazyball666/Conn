import ConnEntitlement
import ConnUI
import Foundation
import Observation
import StoreKit

/// App Store 订阅状态的唯一入口。
///
/// 商品加载、购买、恢复和交易更新都集中在这里，UI 只读取状态和权益门控，
/// 不直接依赖 StoreKit。`fixed` 供演示和测试注入确定的免费/Pro 状态。
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

    enum SubscriptionError: Equatable, Sendable {
        case productLoadFailed
        case purchaseFailed
        case restoreFailed
    }

    static let monthlyProductID = "com.crazyball.conn.pro.monthly"
    static let yearlyProductID = "com.crazyball.conn.pro.yearly"
    static let productIDs = [monthlyProductID, yearlyProductID]

    private(set) var status: Status
    private(set) var products: [String: Product] = [:]
    private(set) var lastError: SubscriptionError?

    var isPro: Bool { status == .pro }

    var gate: EntitlementGate {
        EntitlementGate(snapshot: isPro ? .pro : .free)
    }

    @ObservationIgnored private let mode: Mode
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    private enum Mode {
        case live
        case fixed(EntitlementSnapshot)
    }

    private init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .live:
            status = .loading
        case let .fixed(snapshot):
            status = snapshot == .pro ? .pro : .free
        }
    }

    static func live() -> SubscriptionStore {
        SubscriptionStore(mode: .live)
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
        switch mode {
        case let .fixed(snapshot):
            status = snapshot == .pro ? .pro : .free
            lastError = nil
        case .live:
            do {
                let loaded = try await Product.products(for: Self.productIDs)
                products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
                status = await hasActiveEntitlement() ? .pro : .free
                lastError = nil
            } catch {
                status = .unavailable
                lastError = .productLoadFailed
            }
        }
    }

    func purchase(_ plan: Plan) async -> PurchaseResult {
        guard case .live = mode else {
            return isPro ? .purchased : .unavailable
        }

        if products[plan.productID] == nil {
            await refresh()
        }
        guard let product = products[plan.productID] else {
            lastError = .purchaseFailed
            return .unavailable
        }

        do {
            switch try await product.purchase() {
            case let .success(verification):
                guard case let .verified(transaction) = verification else {
                    lastError = .purchaseFailed
                    return .failed
                }
                await transaction.finish()
                await refresh()
                return .purchased
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                lastError = .purchaseFailed
                return .failed
            }
        } catch {
            lastError = .purchaseFailed
            return .failed
        }
    }

    func restore() async {
        guard case .live = mode else { return }
        do {
            try await AppStore.sync()
            await refresh()
        } catch {
            lastError = .restoreFailed
        }
    }

    func product(for plan: Plan) -> Product? {
        products[plan.productID]
    }

    func fallbackPrice(for plan: Plan) -> String {
        switch plan {
        case .monthly: L("¥18/月")
        case .yearly: L("¥98/年")
        }
    }

    private func hasActiveEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            if Self.productIDs.contains(transaction.productID) {
                return true
            }
        }
        return false
    }

    private func observeTransactionUpdates() async {
        for await result in Transaction.updates {
            guard case let .verified(transaction) = result,
                  Self.productIDs.contains(transaction.productID)
            else { continue }
            await transaction.finish()
            await refresh()
        }
    }
}
