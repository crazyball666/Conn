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
                        .padding(.horizontal, ConnSpacing.xs)
                    if dependencies.subscription.isPro {
                        activeSubscriptionCard
                    } else if context != .upgrade {
                        contextBanner
                    }
                    featureList
                    if !dependencies.subscription.isPro {
                        planPicker
                    }
                    legalNotes
                }
                .padding(.horizontal, ConnSpacing.page)
                .padding(.top, ConnSpacing.sm)
                .padding(.bottom, ConnSpacing.page)
            }
            .contentMargins(.top, 0, for: .scrollContent)
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

    private var legalNotes: some View {
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ConnSpacing.xs)
        .padding(.bottom, ConnSpacing.sm)
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.purple, Color.pink.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GeometryReader { proxy in
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 210, height: 210)
                    .blur(radius: 1)
                    .offset(x: proxy.size.width - 92, y: -112)

                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 156, height: 156)
                    .blur(radius: 2)
                    .offset(x: proxy.size.width - 190, y: proxy.size.height - 34)

                PaywallHeroIllustration()
                    .position(
                        x: proxy.size.width - 70,
                        y: proxy.size.height - 38
                    )
            }

            VStack(alignment: .leading, spacing: ConnSpacing.lg) {
                Label(L("CONN PRO"), systemImage: "sparkles")
                    .font(.connCaption)
                    .connEyebrowTracking()
                    .foregroundStyle(.white)
                    .padding(.horizontal, ConnSpacing.md)
                    .padding(.vertical, ConnSpacing.xs)
                    .background(Color.white.opacity(0.15), in: Capsule())

                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    Text(L("将复杂的远程工作，整合至一个工作台"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("连接、管理与执行，核心能力集中于一处。"))
                        .font(.connSubheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(ConnSpacing.lg)
        }
        .frame(maxWidth: .infinity, minHeight: 204, alignment: .leading)
        .clipShape(.rect(cornerRadius: ConnRadius.listCard, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.hero")
    }

    private struct PaywallHeroIllustration: View {
        var body: some View {
            VStack(spacing: 13) {
                Capsule()
                    .fill(Color.white.opacity(0.34))
                    .frame(width: 126, height: 8)
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 154, height: 8)
            }
            .frame(width: 174, height: 94)
            .background(Color.white.opacity(0.12), in: .rect(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 1.2)
            }
            .rotationEffect(.degrees(-11))
            .opacity(0.92)
        }
    }

    private var contextBanner: some View {
        HStack(alignment: .top, spacing: ConnSpacing.sm) {
            IconChip("arrow.up.right", tint: .accent, size: ConnSize.iconChipCompact)
            VStack(alignment: .leading, spacing: 4) {
                Text(contextTitle)
                    .font(.connFootnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.connInk)
                Text(contextMessage)
                    .font(.connCaption)
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
                .font(.connFootnote)
                .fontWeight(.semibold)
                .foregroundStyle(.connGood)
            Text(L("当前账号已拥有全部 Conn Pro 功能。"))
                .font(.connFootnote)
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
        VStack(alignment: .leading, spacing: ConnSpacing.sm) {
            HStack(spacing: ConnSpacing.xs) {
                Text(L("Pro 包含"))
                Text("·")
                Text(L("四项核心能力"))
            }
            .font(.connCaption)
            .connEyebrowTracking()
            .foregroundStyle(.connMuted)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: ConnSpacing.md),
                    GridItem(.flexible(), spacing: ConnSpacing.md),
                ],
                spacing: ConnSpacing.xs
            ) {
                ForEach(featureItems) { item in
                    featureItem(item)
                }
            }
        }
        .padding(.horizontal, ConnSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall.features")
    }

    private func featureItem(_ item: PaywallFeature) -> some View {
        HStack(spacing: ConnSpacing.xs) {
            IconChip(item.systemImage, tint: .accent, size: ConnSize.iconChipCompact)
            Text(item.title)
                .font(.connFootnote)
                .fontWeight(.medium)
                .foregroundStyle(.connInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 64, alignment: .leading)
        .padding(.horizontal, ConnSpacing.sm)
        .background(Color.connSurface, in: .rect(cornerRadius: ConnRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 1)
        }
        .accessibilityValue(Text(item.detail))
        .accessibilityIdentifier("paywall.feature.\(item.id)")
    }

    private var planPicker: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("选择订阅周期"))
                    .font(.connCaption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.connMuted)
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
        .padding(ConnSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .connSurface(cornerRadius: ConnRadius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall.plans")
    }

    private func planButton(_ plan: SubscriptionStore.Plan) -> some View {
        let selected = selectedPlan == plan
        return Button {
            selectedPlan = plan
        } label: {
            VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                HStack(alignment: .top, spacing: ConnSpacing.xs) {
                    Text(planTitle(plan))
                        .font(.connFootnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(.connInk)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.connFootnote)
                        .foregroundStyle(selected ? Color.connAccent : Color.connDim)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(priceText(for: plan))
                        .font(.connData(.subheadline))
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
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(ConnSpacing.sm)
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
