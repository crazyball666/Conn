import ConnEntitlement
import ConnUI
import StoreKit
import SwiftUI
import UIKit

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

private struct PaywallFeature: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
}

/// Conn Pro 购买页。价格和购买资格均以 StoreKit 状态为准。
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
                    if dependencies.subscription.isPro {
                        activeSubscriptionCard
                    } else {
                        contextBanner
                        planPicker
                    }
                    featureList
                    VStack(spacing: ConnSpacing.xs) {
                        Text(L("订阅由 Apple 管理，可在系统设置中取消。"))
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        Text(L("订阅将自动续订，除非在当前计费周期结束前至少 24 小时取消。"))
                            .font(.connCaption)
                            .foregroundStyle(.connMuted)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        HStack(spacing: ConnSpacing.sm) {
                            if let url = AppLegalLinks.privacyPolicyURL {
                                Link(L("隐私政策"), destination: url)
                                    .accessibilityIdentifier("paywall.legal.privacy")
                            }
                            if let url = AppLegalLinks.termsOfUseURL {
                                Link(L("使用条款"), destination: url)
                                    .accessibilityIdentifier("paywall.legal.terms")
                            }
                        }
                        .font(.connCaption)
                        .foregroundStyle(.connMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, ConnSpacing.xs)
                    .padding(.bottom, ConnSpacing.sm)
                }
                .padding(ConnSpacing.page)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                purchaseBar
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
        }
        .accessibilityIdentifier("paywall")
    }

    private var hero: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [.connAccentDeep, .connAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 190, height: 190)
                .blur(radius: 2)
                .offset(x: 78, y: 74)
            Image(systemName: "server.rack")
                .font(.system(size: 112, weight: .bold))
                .foregroundStyle(.white.opacity(0.11))
                .rotationEffect(.degrees(-8))
                .offset(x: 28, y: 18)

            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                HStack {
                    Label(L("CONN PRO"), systemImage: "bolt.fill")
                        .font(.connCaption)
                        .foregroundStyle(.white.opacity(0.94))
                        .padding(.horizontal, ConnSpacing.sm)
                        .padding(.vertical, ConnSpacing.xxs)
                        .background(Color.white.opacity(0.14), in: Capsule())
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    Text(L("把复杂的主机运维，收进一个工作台"))
                        .font(.connSectionTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("连接、文件、容器与批量执行，全部在一处完成。"))
                        .font(.connFootnote)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(ConnSpacing.lg)
        }
        .frame(maxWidth: .infinity, minHeight: 194, alignment: .leading)
        .clipShape(.rect(cornerRadius: ConnRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.hero")
    }

    private var contextBanner: some View {
        HStack(alignment: .top, spacing: ConnSpacing.sm) {
            IconChip("arrow.up.right", tint: .accent, size: ConnSize.iconChipCompact)
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
        .background(Color.connAccentFill, in: .rect(cornerRadius: ConnRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.card, style: .continuous)
                .strokeBorder(Color.connAccent.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.context")
    }

    private var activeSubscriptionCard: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Label(L("当前已订阅"), systemImage: "checkmark.seal.fill")
                .font(.connSectionTitle)
                .fontWeight(.semibold)
                .foregroundStyle(.connGood)
            Text(L("当前账号已拥有全部 Conn Pro 功能。"))
                .font(.connBody)
                .foregroundStyle(.connMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ConnSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .connSurface(cornerRadius: ConnRadius.card)
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.card, style: .continuous)
                .strokeBorder(Color.connGood.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.active")
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Pro 包含"))
                    .font(.connSectionTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(.connInk)
                Spacer()
                Text(L("四项核心能力"))
                    .font(.connCaption)
                    .foregroundStyle(.connMuted)
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: ConnSpacing.sm),
                    GridItem(.flexible(), spacing: ConnSpacing.sm),
                ],
                spacing: ConnSpacing.sm
            ) {
                ForEach(featureItems) { item in
                    featureItem(item)
                }
            }
        }
        .padding(ConnSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .connSurface(cornerRadius: ConnRadius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall.features")
    }

    private func featureItem(_ item: PaywallFeature) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack {
                IconChip(item.systemImage, tint: .accent, size: ConnSize.iconChipCompact)
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.connGood)
            }
            Text(item.title)
                .font(.connBody)
                .fontWeight(.semibold)
                .foregroundStyle(.connInk)
                .lineLimit(2)
            Text(item.detail)
                .font(.connCaption)
                .foregroundStyle(.connMuted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(ConnSpacing.sm)
        .background(Color.connBg.opacity(0.5), in: .rect(cornerRadius: ConnRadius.control, style: .continuous))
    }

    private var planPicker: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("选择订阅周期"))
                    .font(.connSectionTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(.connInk)
                Spacer()
                Text(L("自动续订"))
                    .font(.connCaption)
                    .foregroundStyle(.connMuted)
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: ConnSpacing.sm),
                    GridItem(.flexible(), spacing: ConnSpacing.sm),
                ],
                spacing: ConnSpacing.sm
            ) {
                ForEach(SubscriptionStore.Plan.allCases) { plan in
                    planButton(plan)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall.plans")
    }

    private func planButton(_ plan: SubscriptionStore.Plan) -> some View {
        let selected = selectedPlan == plan
        return Button {
            selectedPlan = plan
        } label: {
            VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                HStack(alignment: .top, spacing: ConnSpacing.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(planTitle(plan))
                            .font(.connBody)
                            .fontWeight(.semibold)
                            .foregroundStyle(.connInk)
                        Text(planSubtitle(plan))
                            .font(.connCaption)
                            .foregroundStyle(.connMuted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.connAccent : Color.connDim)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(priceText(for: plan))
                        .font(.connData(.title3))
                        .fontWeight(.bold)
                        .foregroundStyle(.connInk)
                        .connTabularNumbers()
                    Text(plan == .yearly ? L("每年") : L("每月"))
                        .font(.connCaption)
                        .foregroundStyle(.connMuted)
                }
                if plan == .yearly {
                    Text(L("更划算"))
                        .font(.connData(.caption2))
                        .fontWeight(.semibold)
                        .foregroundStyle(.connAccent)
                        .padding(.horizontal, ConnSpacing.xs)
                        .padding(.vertical, 3)
                        .background(Color.connAccentFill, in: Capsule())
                        .accessibilityIdentifier("paywall.yearly.badge")
                } else {
                    Color.clear
                        .frame(height: 18)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .padding(ConnSpacing.cardPadding)
            .background(
                selected ? Color.connAccentFill : Color.connSurface,
                in: .rect(cornerRadius: ConnRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ConnRadius.card, style: .continuous)
                    .strokeBorder(
                        selected ? Color.connAccent : Color.connLine,
                        lineWidth: selected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(ConnPressStyle())
        .accessibilityIdentifier("paywall.plan.\(plan.rawValue)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var purchaseBar: some View {
        VStack(spacing: ConnSpacing.xxs) {
            if dependencies.subscription.isPro {
                ConnButton(L("管理订阅"), height: ConnSize.buttonHeightLarge) {
                    Task { await manageSubscription() }
                }
                .accessibilityIdentifier("paywall.manage")
                .frame(maxWidth: .infinity)
            } else {
                ConnButton(
                    String(format: L("订阅 Conn Pro · %@"), priceText(for: selectedPlan)),
                    height: ConnSize.buttonHeightLarge
                ) {
                    Task { await purchase() }
                }
                .disabled(
                    isPurchasing
                        || dependencies.subscription.status != .free
                        || dependencies.subscription.product(for: selectedPlan) == nil
                )
                .accessibilityIdentifier("paywall.purchase")
                .frame(maxWidth: .infinity)

                if dependencies.subscription.status == .unavailable {
                    Text(L("订阅商品暂不可用，请稍后重试。"))
                        .font(.connCaption)
                        .foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("paywall.unavailable")
                }
            }

            Button {
                Task { await restore() }
            } label: {
                Text(L("恢复购买"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: ConnSize.minTouchTarget)
            }
            .disabled(isPurchasing || dependencies.subscription.status == .loading)
            .accessibilityIdentifier("paywall.restore")
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.top, ConnSpacing.sm)
        .padding(.bottom, ConnSpacing.xxs)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.connLine)
                .frame(height: 1)
        }
    }

    private var featureItems: [PaywallFeature] {
        [
            PaywallFeature(
                id: "hosts",
                title: L("无限主机数量"),
                detail: L("不受两台限制"),
                systemImage: "server.rack"
            ),
            PaywallFeature(
                id: "files",
                title: L("远程文件管理"),
                detail: L("上传、下载与整理"),
                systemImage: "folder"
            ),
            PaywallFeature(
                id: "docker",
                title: L("Docker 管理"),
                detail: L("容器与镜像操作"),
                systemImage: "shippingbox"
            ),
            PaywallFeature(
                id: "batch",
                title: L("批量执行脚本"),
                detail: L("多台主机同时执行"),
                systemImage: "square.stack.3d.up"
            ),
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

    private func planSubtitle(_ plan: SubscriptionStore.Plan) -> String {
        switch plan {
        case .monthly: L("按月自动续订")
        case .yearly: L("按年自动续订")
        }
    }

    private func priceText(for plan: SubscriptionStore.Plan) -> String {
        dependencies.subscription.product(for: plan)?.displayPrice
            ?? L("价格暂不可用")
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
        let result = await dependencies.subscription.restore()
        isPurchasing = false
        switch result {
        case .restored:
            message = L("订阅已恢复。")
        case .noActiveSubscription:
            message = L("未找到有效订阅。")
        case .inProgress:
            message = L("已有操作正在处理中，请稍候。")
        case .failed:
            message = L("恢复购买失败，请稍后重试。")
        }
        if dependencies.subscription.isPro { dismiss() }
    }

    private func manageSubscription() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            message = L("无法打开订阅管理。")
            return
        }

        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else {
                message = L("无法打开订阅管理。")
                return
            }
            await UIApplication.shared.open(url)
        }
    }
}
