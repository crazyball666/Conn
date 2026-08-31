import ConnEntitlement
import ConnUI
import StoreKit
import SwiftUI

/// 触发 Pro 购买页的业务场景。
enum PaywallContext: String, CaseIterable, Equatable, Identifiable, Sendable {
    case upgrade
    case thirdHost
    case fileManagement
    case dockerManagement
    case batchExecution

    var id: String { rawValue }

    var feature: EntitlementFeature? {
        switch self {
        case .upgrade, .thirdHost: nil
        case .fileManagement: .fileManagement
        case .dockerManagement: .dockerManagement
        case .batchExecution: .batchExecution
        }
    }
}

/// Conn Pro 购买页。价格以 StoreKit 返回值为准，未配置商品时使用确定的开发兜底值，
/// 保证演示包和商品配置前的 UI 验收仍然可用。
struct PaywallView: View {
    let dependencies: AppDependencies
    let context: PaywallContext

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlan: SubscriptionStore.Plan = .yearly
    @State private var isPurchasing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ConnSpacing.md) {
                    hero
                    reasonCard
                    featureList
                    planPicker
                    purchaseButton
                    restoreButton
                    Text(L("订阅由 Apple 管理，可在系统设置中取消。"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(ConnSpacing.page)
            }
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("Conn Pro"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("关闭")) { dismiss() }
                        .accessibilityIdentifier("paywall.close")
                }
            }
            .overlay {
                if isPurchasing {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView(L("处理中…"))
                        .padding(ConnSpacing.lg)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ConnRadius.card))
                        .accessibilityIdentifier("paywall.progress")
                }
            }
            .alert(L("订阅"), isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button(L("确定"), role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .task {
                dependencies.subscription.start()
                await dependencies.subscription.refresh()
            }
            .onChange(of: dependencies.subscription.isPro) { _, isPro in
                if isPro { dismiss() }
            }
        }
        .accessibilityIdentifier("paywall")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.connAccent, in: RoundedRectangle(cornerRadius: ConnRadius.control))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Conn Pro"))
                        .font(.connTitle)
                        .foregroundStyle(.connInk)
                    Text(L("解锁完整的主机管理能力"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
            }
            Text(L("为多主机运维工作流提供无限制的文件、容器和批量操作。"))
                .font(.connBody)
                .foregroundStyle(.connInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var reasonCard: some View {
        HStack(alignment: .top, spacing: ConnSpacing.sm) {
            Image(systemName: "lock.open.fill")
                .foregroundStyle(.connAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(contextTitle)
                    .font(.connBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(.connInk)
                Text(contextMessage)
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("Pro 包含"))
                .font(.connCaption)
                .foregroundStyle(.connMuted)
                .connEyebrowTracking()
            ForEach(featureItems, id: \.self) { item in
                Label(item, systemImage: "checkmark.circle.fill")
                    .font(.connBody)
                    .foregroundStyle(.connInk)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.connGood)
                    .padding(.vertical, 2)
            }
        }
        .padding(ConnSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private var planPicker: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("选择订阅周期"))
                .font(.connCaption)
                .foregroundStyle(.connMuted)
                .connEyebrowTracking()
            HStack(spacing: ConnSpacing.sm) {
                ForEach(SubscriptionStore.Plan.allCases) { plan in
                    planButton(plan)
                }
            }
        }
    }

    private func planButton(_ plan: SubscriptionStore.Plan) -> some View {
        let selected = selectedPlan == plan
        return Button {
            selectedPlan = plan
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(planTitle(plan))
                        .font(.connBody)
                        .fontWeight(.semibold)
                    Spacer()
                    if plan == .yearly {
                        Text(L("更划算"))
                            .font(.connData(.caption2))
                            .foregroundStyle(selected ? .white : .connAccent)
                    }
                }
                Text(priceText(for: plan))
                    .font(.connData(.title3))
                    .fontWeight(.bold)
                    .connTabularNumbers()
                Text(plan == .yearly ? L("按年自动续订") : L("按月自动续订"))
                    .font(.connFootnote)
                    .foregroundStyle(selected ? .white.opacity(0.82) : .connMuted)
            }
            .foregroundStyle(selected ? .white : .connInk)
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.connAccent : Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: ConnRadius.card)
                    .stroke(selected ? Color.clear : Color.connMuted.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("paywall.plan.\(plan.rawValue)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var purchaseButton: some View {
        Button {
            Task { await purchase() }
        } label: {
            Text(String(format: L("订阅 Conn Pro · %@"), priceText(for: selectedPlan)))
                .font(.connBody)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ConnSpacing.sm)
        }
        .buttonStyle(.borderedProminent)
        .tint(.connAccent)
        .disabled(isPurchasing || dependencies.subscription.status == .loading)
        .accessibilityIdentifier("paywall.purchase")
    }

    private var restoreButton: some View {
        Button {
            Task { await restore() }
        } label: {
            Text(L("恢复购买"))
                .font(.connFootnote)
                .frame(maxWidth: .infinity)
        }
        .disabled(isPurchasing)
        .accessibilityIdentifier("paywall.restore")
    }

    private var featureItems: [String] {
        [
            L("无限主机数量"),
            L("远程文件管理"),
            L("Docker 管理"),
            L("批量执行脚本"),
        ]
    }

    private var contextTitle: String {
        switch context {
        case .upgrade: L("升级到 Conn Pro")
        case .thirdHost: L("添加第三台主机")
        case .fileManagement: L("文件管理")
        case .dockerManagement: L("Docker 管理")
        case .batchExecution: L("批量执行")
        }
    }

    private var contextMessage: String {
        switch context {
        case .upgrade: L("订阅后即可使用全部 Pro 功能。")
        case .thirdHost: L("免费版最多添加两台主机，升级后可添加任意数量。")
        case .fileManagement: L("文件管理是 Conn Pro 功能，升级后即可访问远程文件。")
        case .dockerManagement: L("Docker 管理是 Conn Pro 功能，升级后即可管理容器和镜像。")
        case .batchExecution: L("批量执行是 Conn Pro 功能，升级后可同时操作多台主机。")
        }
    }

    private func planTitle(_ plan: SubscriptionStore.Plan) -> String {
        switch plan {
        case .monthly: L("按月")
        case .yearly: L("按年")
        }
    }

    private func priceText(for plan: SubscriptionStore.Plan) -> String {
        dependencies.subscription.product(for: plan)?.displayPrice
            ?? dependencies.subscription.fallbackPrice(for: plan)
    }

    private func purchase() async {
        isPurchasing = true
        defer { isPurchasing = false }
        switch await dependencies.subscription.purchase(selectedPlan) {
        case .purchased:
            dismiss()
        case .pending:
            message = L("购买已提交，完成后将自动生效。")
        case .cancelled:
            break
        case .unavailable:
            message = L("购买暂不可用，请稍后重试。")
        case .failed:
            message = L("购买失败，请稍后重试。")
        }
    }

    private func restore() async {
        isPurchasing = true
        await dependencies.subscription.restore()
        isPurchasing = false
        message = dependencies.subscription.isPro
            ? L("订阅已恢复。")
            : L("未找到有效订阅。")
        if dependencies.subscription.isPro { dismiss() }
    }
}
