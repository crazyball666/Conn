import Foundation
import Testing
import UIKit
@testable import Conn

struct AppWideUIConsistencyTests {
    @Test("密钥提示明确说明本地 Keychain 存储")
    func keyGenerationCopyUsesLocalKeychainStatement() throws {
        let source = try appSource("Keys/KeyManagerView.swift")

        #expect(source.contains("Text(L(\"密钥只保存在本地 Keychain\"))"))
        #expect(!source.contains("私钥不会写入数据库，只保存在设备 Keychain。"))
    }

    @Test("新建终端类型仅展示类型名称，不展示冗余说明")
    func newTerminalTypeChoicesHideSubtitles() throws {
        let source = try appSource("Terminal/NewTerminalSheet.swift")

        #expect(source.contains("launchChoice(\n                        title: L(\"普通终端\"),\n                        systemImage: \"terminal\""))
        #expect(source.contains("launchChoice(\n                        title: \"tmux\",\n                        systemImage: \"rectangle.connected.to.line.below\""))
        #expect(!source.contains("启动独立远程 Shell"))
        #expect(!source.contains("连接或创建可恢复的远程 Session"))
        #expect(!source.contains("subtitle:"))
    }

    @Test("终端快捷键分类按常用、Provider、Claude Code、上传排列")
    func terminalKeybarCategoriesUseProviderFirstOrder() throws {
        let source = try packageSource("Sources/ConnTerminal/TerminalKeybar.swift")

        let common = try #require(source.range(of: "title: L(\"常用\")"))
        let provider = try #require(source.range(of: "title: providerQuickActionGroup.title"))
        let claudeCode = try #require(source.range(of: "title: L(\"Claude Code\")"))
        let upload = try #require(source.range(of: "title: L(\"上传\")"))

        #expect(common.lowerBound < provider.lowerBound)
        #expect(provider.lowerBound < claudeCode.lowerBound)
        #expect(claudeCode.lowerBound < upload.lowerBound)
        #expect(!source.contains("title: L(\"Claude\")"))
    }

    @Test("刷新间隔使用紧凑技术单位并保留秒数调度语义")
    func refreshIntervalUsesCompactTechnicalUnit() throws {
        let settings = try appSource("Settings/SettingsStore.swift")

        #expect(settings.contains("var label: String { String(format: L(\"%ds\"), rawValue) }"))
        #expect(!settings.contains("每 %d 秒"))
        #expect(settings.contains("var duration: Duration { .seconds(rawValue) }"))
    }

    @Test("设置页提供带设备环境信息的邮件反馈入口")
    func settingsProvidesFeedbackMailEntry() throws {
        let settings = try appSource("Me/MeView.swift")
        let feedback = try appSource("Me/FeedbackMailComposer.swift")

        #expect(settings.contains("Section(L(\"支持\"))"))
        #expect(settings.contains("accessibilityIdentifier(\"settings.feedback\")"))
        #expect(settings.contains("MFMailComposeViewController.canSendMail()"))
        #expect(settings.contains("UIPasteboard.general.string = content.body"))
        #expect(feedback.contains("setToRecipients([FeedbackMailTemplate.recipient])"))
        #expect(feedback.contains("UIDevice.current.systemVersion"))
        #expect(feedback.contains("SIMULATOR_MODEL_IDENTIFIER"))
        #expect(feedback.contains("CFBundleShortVersionString"))
        #expect(feedback.contains("Device: "))
        #expect(feedback.contains("OS: "))
        #expect(feedback.contains("App Version: "))
    }

    @Test("反馈邮件模板预留填写区域并附带设备环境信息")
    @MainActor
    func feedbackMailTemplateContainsEnvironmentDetails() {
        let content = FeedbackMailTemplate.make()

        #expect(!content.subject.isEmpty)
        #expect(content.body.hasPrefix("\n\n\n\n\n"))
        #expect(content.body.contains("Device: "))
        #expect(content.body.contains("OS: "))
        #expect(content.body.contains("App Version: "))
        #expect(content.body.contains(UIDevice.current.systemVersion))
        #expect(!content.body.contains("问题描述"))
        #expect(!content.body.contains("复现步骤"))
    }

    @Test("全 App 交互触感统一使用高强度策略")
    func appHapticsUseHighImpactPolicy() throws {
        let sources = [
            try appSource("Hosts/HostOverviewView.swift"),
            try packageSource("Sources/ConnUI/Components/GroupFilterBar.swift"),
            try packageSource("Sources/ConnTerminal/TerminalDirectionPad.swift"),
            try packageSource("Sources/ConnTerminal/TerminalKeybar.swift"),
            try packageSource("Sources/ConnTerminal/TerminalHostingView.swift"),
        ]
        for source in sources {
            #expect(!source.contains(".sensoryFeedback(.selection"))
            #expect(!source.contains("weight: .light"))
            #expect(!source.contains("UISelectionFeedbackGenerator"))
        }
        #expect(sources.allSatisfy { $0.contains("ConnHapticFeedback.highImpact")
            || $0.contains("ConnHapticFeedback.performHighImpact()") })

        let overview = sources[0]
        #expect(overview.contains("@State private var cpuSelectionHapticCount = 0"))
        #expect(overview.contains("cpuSelectionHapticCount &+= 1"))
        #expect(overview.contains(
            ".sensoryFeedback(ConnHapticFeedback.highImpact, trigger: cpuSelectionHapticCount)"
        ))
        #expect(!overview.contains(
            ".sensoryFeedback(ConnHapticFeedback.highImpact, trigger: cpuVisibility)"
        ))

        let swiftTerm = try vendorSource("SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift")
        #expect(swiftTerm.contains("UIImpactFeedbackGenerator(style: .heavy)"))
        #expect(swiftTerm.contains("impactOccurred(intensity: 1.0)"))
        #expect(!swiftTerm.contains("UINotificationFeedbackGenerator"))
    }

    @Test("终端模拟器依赖固定到仓库内 SwiftTerm vendor")
    func terminalEmulatorUsesRepositoryOwnedVendor() throws {
        let package = try packageSource("Package.swift")

        #expect(package.contains(#".package(path: "../Vendor/SwiftTerm")"#))
        #expect(!package.contains("github.com/migueldeicaza/SwiftTerm"))
    }

    @Test("命令页不再使用命令与分组的嵌套分段")
    func snippetsUsesFocusedListAndGroupDestination() throws {
        let source = try appSource("Commands/SnippetsView.swift")

        #expect(!source.contains("SnippetsPage"))
        #expect(!source.contains("pagePicker"))
        #expect(!source.contains(".pickerStyle(.segmented)"))
        #expect(source.contains("isGroupsPresented"))
        #expect(source.contains(".navigationDestination(isPresented: $isGroupsPresented)"))
        #expect(source.contains("Label(L(\"管理分组\")"))
    }

    @Test("根 Tab 使用脚本文案，脚本执行默认不选主机且按钮状态统一")
    func scriptTabAndRunActionsUseConsistentState() throws {
        let dock = try packageSource("Sources/ConnUI/Components/ConnDock.swift")
        let runView = try appSource("Commands/SnippetRunView.swift")
        let button = try packageSource("Sources/ConnUI/Components/ConnButton.swift")

        #expect(dock.contains("case .commands: \"脚本\""))
        #expect(!runView.contains("if selectedHostIDs.isEmpty, let first = hosts.first"))
        #expect(runView.contains("ConnButton(L(\"执行脚本\"), kind: .primary)"))
        #expect(runView.contains("ConnButton(L(\"在终端中执行\"), kind: .primary)"))
        #expect(runView.contains(".disabled(selectedHosts.isEmpty || isRunning)"))
        #expect(runView.contains(".disabled(selectedHosts.count != 1 || isRunning)"))
        #expect(runView.contains("SnippetExecutionRequestBuilder.prepare("))
        #expect(runView.contains(".frame(maxWidth: .infinity, alignment: .center)"))
        #expect(runView.contains(".padding(.top, ConnSpacing.sm)"))
        #expect(runView.contains("if isRunning {\n                        executionProgress\n                    } else"))
        #expect(!runView.contains("正在检查脚本兼容性"))
        #expect(!runView.contains("scheduleCompatibilityCheck"))
        #expect(!runView.contains("compatibilityByHostID"))
        #expect(button.contains("@Environment(\\.isEnabled)"))
    }

    @Test("主机概览显示指标能力降级且不把缺失采样记录成零")
    func hostOverviewPreservesMissingMetrics() throws {
        let viewModel = try appSource("Hosts/HostOverviewViewModel.swift")
        let view = try appSource("Hosts/HostOverviewView.swift")

        #expect(viewModel.contains("var capabilityMessage: String?"))
        #expect(!viewModel.contains("metrics.cpu ?? 0"))
        #expect(!viewModel.contains("metrics.mem ?? 0"))
        #expect(view.contains("viewModel.capabilityMessage"))
    }

    @Test("主机详情趋势图在首采前保持图表容器")
    func hostOverviewChartsStayVisibleBeforeFirstSample() throws {
        let viewModel = try appSource("Hosts/HostOverviewViewModel.swift")
        let view = try appSource("Hosts/HostOverviewView.swift")
        let chart = try appSource("Hosts/MetricTrendChart.swift")

        #expect(view.contains("private func trendChart("))
        #expect(view.contains("return MetricTrendChart("))
        #expect(!view.contains("chartOrPlaceholder"))
        #expect(!view.contains("Text(L(\"采集中…\"))"))
        #expect(chart.contains("struct TrendSample: Identifiable, Equatable"))
        #expect(chart.contains("let samples: [TrendSample]"))
        #expect(chart.contains("enum TrendViewport"))
        #expect(chart.contains("static let retainedSampleCount = visibleSampleCount + 1"))
        #expect(chart.contains("private var xDomain: ClosedRange<Double>"))
        #expect(chart.contains("TrendViewport.xDomain(endingAt: viewportEnd ?? Double(latestSequence ?? 0))"))
        #expect(!chart.contains("let start = max(0, latest - 39)"))
        #expect(chart.contains(".chartXScale(domain: xDomain, range: .plotDimension"))
        #expect(chart.contains(".chartPlotStyle"))
        #expect(!chart.contains(".animation(chartAnimation, value: dataValues)"))
        #expect(chart.contains(".onChange(of: latestSequence)"))
        #expect(chart.contains("withAnimation(ConnMotion.chartUpdate)"))
        #expect(!chart.contains("private var renderedSeries"))
        #expect(viewModel.contains("private let maxPoints = TrendViewport.retainedSampleCount"))
        #expect(chart.contains("static func axisValues(in domain: ClosedRange<Double>) -> [Double]"))
        #expect(chart.contains("Array(0 ... 4)"))
        #expect(chart.contains("values: yAxisValues"))
        #expect(!chart.contains(".automatic(desiredCount:"))
        #expect(!chart.contains("Array(line.values.enumerated())"))
        #expect(viewModel.contains("monitor.onMetricsUpdated = { [weak self] metrics in"))
        #expect(viewModel.contains("self.record(metrics)"))
        #expect(!view.contains(".onChange(of: viewModel.latest)"))
        #expect(!viewModel.contains("cpuHistory"))
        #expect(!viewModel.contains("coreHistories"))
        #expect(viewModel.contains("recordCPUBreakdown(metrics.cpuBreakdown"))
        #expect(viewModel.contains("guard let value else { return }"))
    }

    @Test("主机详情图表不伪造零点，内存三项按实际值独立绘制")
    func hostOverviewChartsUseRealIndependentMemorySeries() throws {
        let viewModel = try appSource("Hosts/HostOverviewViewModel.swift")
        let view = try appSource("Hosts/HostOverviewView.swift")
        let chart = try appSource("Hosts/MetricTrendChart.swift")

        #expect(!viewModel.contains("appendZero("))
        #expect(!viewModel.contains("append(&netRxHistory, 0"))
        #expect(!viewModel.contains("append(&ioReadHistory, 0"))
        #expect(viewModel.contains("memUsedHistory"))
        #expect(viewModel.contains("memCacheHistory"))
        #expect(viewModel.contains("memFreeHistory"))
        #expect(viewModel.contains("MemoryChartValues(metrics: metrics)"))
        #expect(view.contains("TrendSeries(id: L(\"已用\"), color: HostChartPalette.memoryUsed, samples: viewModel.memUsedHistory)"))
        #expect(view.contains("TrendSeries(id: L(\"缓存\"), color: HostChartPalette.memoryCache, samples: viewModel.memCacheHistory)"))
        #expect(view.contains("TrendSeries(id: L(\"空闲\"), color: HostChartPalette.memoryFree, samples: viewModel.memFreeHistory)"))
        #expect(chart.contains("var stacked: Bool = true"))
        #expect(chart.contains("mapping: chartStyle(for:)"))
        #expect(chart.contains("private func chartStyle(for id: String) -> AnyShapeStyle"))
        #expect(chart.contains(".foregroundStyle(chartStyle(for: line.id))"))
        #expect(chart.contains("LinearGradient("))
        #expect(chart.contains("case cumulative"))
        #expect(chart.contains("case independent"))
        #expect(chart.contains("case .independent: .unstacked"))
        #expect(chart.contains("stacking: areaStacking.markMethod"))
        // CPU/内存和磁盘/网络共用 AreaMark 视觉，不为独立面积额外叠加粗描边。
        #expect(!chart.contains("private func boundaryLine"))
        #expect(!chart.contains("lineWidth: 1.6"))
        // 内存与 CPU 各有一次独立实际值面积；网络/IO 继续使用默认累计模式。
        #expect(view.components(separatedBy: "areaStacking: .independent").count == 3)
    }

    @Test("首页 CPU 基线缺失不伪造 SSH 连接态")
    func firstCPUBaselineDoesNotBecomeConnectionState() throws {
        let servers = try appSource("Servers/ServersViewModel.swift")
        let scheduler = try packageSource("Sources/ConnMonitor/MonitorScheduler.swift")
        let healthCard = try packageSource("Sources/ConnUI/Components/HealthCard.swift")

        #expect(!servers.contains("isInitialHealthWarmup"))
        #expect(servers.contains("let connectionPhase = connectionPhase(metrics: metrics, error: error, phase: phase)"))
        #expect(servers.contains("connectionPhase: connectionPhase,"))
        #expect(servers.contains("collectPhase: collectPhase(phase)"))
        #expect(scheduler.contains("isCPUBaselinePending"))
        #expect(scheduler.contains("hasEstablishedHealth"))
        #expect(scheduler.contains("$0.severity != .unknown"))
        #expect(healthCard.contains("model.connectionPhase.pillText"))
        #expect(!healthCard.contains("connectionPhase.pillText(status:"))
    }

    @Test("管理分组页自己承载分组弹窗并居中空状态")
    func snippetGroupsOwnPresentationAndCenteredEmptyState() throws {
        let source = try appSource("Commands/SnippetsView.swift")

        #expect(source.contains("private var groupsPage: some View {\n        GeometryReader"))
        #expect(source.contains("isNewGroupPresented: $isGroupsNewGroupPresented"))
        #expect(source.contains(".frame(minHeight: geometry.size.height)"))
    }

    @Test("连接失败页面统一使用设计系统重试组件")
    func featureFailuresUseSharedRetryState() throws {
        let paths = [
            "Hosts/ProcessListView.swift",
            "Files/FileBrowserView.swift",
            "Files/DirectoryPickerView.swift",
            "Hosts/LogCenterView.swift",
            "Hosts/DockerView.swift",
            "Hosts/DockerComposeViews.swift",
            "Hosts/DockerDetailBuilding.swift",
        ]

        for path in paths {
            #expect(try appSource(path).contains("ConnRetryState("), "\(path) 尚未接入统一错误重试组件")
        }
    }

    @Test("命令列表项使用长按操作和紧凑大圆角卡片")
    func snippetRowsUseLongPressActionsAndCompactCards() throws {
        let source = try appSource("Commands/SnippetsView.swift")

        #expect(!source.contains("ConnMoreActionsIcon()"))
        #expect(source.components(separatedBy: ".contextMenu").count >= 3)
        #expect(source.contains(".connSurface(cornerRadius: ConnRadius.listCard)"))
        #expect(source.contains("static let iconSize: CGFloat = 30"))
        #expect(source.contains(".padding(.vertical, ConnSpacing.xs)"))
        #expect(source.contains("Text(snippet.title)\n                            .font(.connSubheadline)"))
        #expect(!source.contains("Text(snippet.title)\n                            .font(.connBody)"))
    }

    @Test("命令与分组列表项长按整行空白区域也能触发操作")
    func snippetRowsMakeEntireCardInteractive() throws {
        let source = try appSource("Commands/SnippetsView.swift")

        #expect(source.components(separatedBy: ".contentShape(Rectangle())").count >= 3)
    }

    @Test("终端会话列表项整行空白区域也能点击")
    func terminalSessionRowsMakeEntireRowInteractive() throws {
        for path in [
            "Terminal/TerminalSessionCenterView.swift",
            "Terminal/TerminalSessionListSheet.swift",
        ] {
            let source = try appSource(path)
            #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
            #expect(source.contains(".contentShape(Rectangle())"))
        }
    }

    @Test("持久终端别名通过协调器同步远端而不是直接修改 Store")
    func terminalRenameUsesCoordinatorTransaction() throws {
        let screen = try appSource("Terminal/TerminalScreen.swift")
        let sheet = try appSource("Terminal/TerminalSessionListSheet.swift")

        #expect(screen.contains("await terminalSessions.rename(id, to: alias)"))
        #expect(!screen.contains("terminalSessions.store.updateAlias(id, to: alias)"))
        #expect(sheet.contains("修改持久终端别名会同步重命名远程会话"))
    }

    @Test("新建终端主机列表整行可点击")
    func terminalHostPickerRowsMakeEntireRowInteractive() throws {
        let source = try appSource("Terminal/NewTerminalSheet.swift")
        #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(source.contains(".contentShape(Rectangle())"))
        #expect(source.contains("model.selectHost(host)"))
        #expect(source.contains("Button(L(\"重试\")) { model.start() }"))
    }

    @Test("终端使用沉浸布局并从底部快捷栏打开会话操作")
    func terminalUsesImmersiveLayoutAndKeybarSessionActions() throws {
        let source = try appSource("Terminal/TerminalScreen.swift")
        let host = try packageSource("Sources/ConnTerminal/TerminalHostingView.swift")
        let keybar = try packageSource("Sources/ConnTerminal/TerminalKeybar.swift")

        #expect(!source.contains(".navigationTitle(hostTitle)"))
        #expect(!source.contains("terminalToolbar"))
        #expect(source.contains("TerminalSessionActionsSheet("))
        #expect(source.contains("onShowSessionActions:"))
        #expect(source.contains("isSessionActionsPresented"))
        #expect(host.contains("onShowSessionActions"))
        #expect(keybar.contains("sessionActionsCap"))
        #expect(keybar.contains("terminal.keybar.session-actions"))
    }

    @Test("终端主题使用自定义列表展示完整预览而不是系统 Picker 文本降级")
    func terminalThemesUseCustomPreviewList() throws {
        let settings = try appSource("Me/TerminalSettingsView.swift")
        let previews = try appSource("Me/TerminalSettingsPreviews.swift")

        #expect(settings.contains("@State private var isThemePickerPresented = false"))
        #expect(settings.contains("isThemePickerPresented = true"))
        #expect(settings.contains("TerminalThemePickerLabel(theme: selectedTheme)"))
        #expect(settings.contains("TerminalThemeSelectionSheet("))
        #expect(settings.contains("selection: $settings.terminalThemeID"))
        #expect(!settings.contains("Picker(selection: $settings.terminalThemeID)"))
        #expect(previews.contains("struct TerminalThemeSelectionSheet: View"))
        #expect(previews.contains("Section(L(\"深色\"))"))
        #expect(previews.contains("Section(L(\"浅色\"))"))
        #expect(previews.contains("TerminalThemePreviewCard("))
        #expect(previews.contains("selection = theme.id"))
        #expect(previews.contains("Text(\"Aa\")"))
        #expect(previews.contains("theme.background"))
        #expect(previews.contains("theme.foreground"))
        #expect(previews.contains("theme.cursor"))
        #expect(previews.contains("ForEach(Array(theme.ansi.prefix(8).enumerated())"))
    }

    @Test("终端光标设置显示三种真实形状并直接绑定现有枚举")
    func terminalCursorUsesSelectableShapePreviews() throws {
        let settings = try appSource("Me/TerminalSettingsView.swift")
        let previews = try appSource("Me/TerminalSettingsPreviews.swift")

        #expect(settings.contains("TerminalCursorShapePicker("))
        #expect(settings.contains("selection: $settings.terminalCursorShape"))
        #expect(settings.contains("theme: selectedTheme"))
        #expect(settings.contains("Toggle(isOn: $settings.terminalCursorBlinking)"))
        #expect(!settings.contains(".pickerStyle(.segmented)"))
        #expect(previews.contains("ForEach(TerminalCursorShape.allCases)"))
        #expect(previews.contains("selection = shape"))
        #expect(previews.contains("case .block:"))
        #expect(previews.contains("case .bar:"))
        #expect(previews.contains("case .underline:"))
        #expect(previews.contains(".frame(minHeight: 44)"))
    }

    @Test("终端系统明暗外观跟随当前终端主题")
    func terminalScreenUsesThemeAppearance() throws {
        let source = try appSource("Terminal/TerminalScreen.swift")

        #expect(source.contains("settings.terminalConfiguration.theme.appearance"))
        #expect(source.contains("private var terminalColorScheme: ColorScheme"))
        #expect(source.contains(".preferredColorScheme(terminalColorScheme)"))
        #expect(!source.contains(".toolbarColorScheme("))
        #expect(!source.contains(".preferredColorScheme(.dark)"))
    }

    @Test("全屏终端页提供本地全局 Toast 覆盖层")
    func terminalScreenHostsToastAboveFullScreenPresentation() throws {
        let source = try appSource("Terminal/TerminalScreen.swift")

        #expect(source.contains(".connGlobalToast()"))
    }

    @Test("终端页只传 provider-neutral 交互 facet，不感知 tmux")
    func terminalScreenUsesOptionalInteractionFacet() throws {
        let screen = try appSource("Terminal/TerminalScreen.swift")
        let host = try packageSource("Sources/ConnTerminal/TerminalHostingView.swift")
        let keybar = try packageSource("Sources/ConnTerminal/TerminalKeybar.swift")
        let keys = try packageSource("Sources/ConnTerminal/TerminalKey.swift")
        let swiftTerm = try vendorSource("SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift")

        #expect(screen.contains("as? any PersistentTerminalInteractiveAttachment"))
        #expect(screen.contains(")?.interaction"))
        #expect(screen.contains("terminalGeneration: tab.generation"))
        #expect(!screen.contains("TmuxProvider"))
        #expect(!host.contains("TmuxProvider"))
        #expect(host.contains("hostManagesTouchGestures = true"))
        #expect(host.contains("beginHostSelection("))
        #expect(host.contains("extendHostSelection(to:"))
        #expect(host.contains("finishHostSelection(showMenu: true)"))
        #expect(host.contains("handleHostSelectionPan("))
        #expect(host.contains("terminalView.clearSelection()"))
        #expect(host.contains("if terminalView.hasActiveSelection"))
        #expect(host.contains("historyCaptureTask?.cancel()"))
        #expect(host.contains("guard !Task.isCancelled,"))
        #expect(!host.contains("terminalView.clearSelection()\n                return"))
        #expect(swiftTerm.contains("public func extendHostSelection(to point: CGPoint)"))
        #expect(swiftTerm.contains("selection.dragExtend(bufferPosition:"))
        #expect(!host.contains("capturePersistentHistory(selectionHit:"))
        #expect(host.contains("presentReview(snapshot, selectionOffset: nil)"))
        #expect(!host.contains(".allowsHitTesting(!controller.isReviewActive)"))
        #expect(!host.contains("terminalActions"))
        #expect(!host.contains("terminal.pointerMode"))
        #expect(!host.contains("terminal.actions"))
        #expect(keybar.contains("ScrollView(.horizontal)"))
        #expect(!keybar.contains("onAllowClipboardReadOnce"))
        #expect(!keybar.contains("允许读取剪贴板一次"))
        #expect(!host.contains("allowClipboardReadOnce"))
        #expect(keybar.components(separatedBy: "TerminalDirectionPad(").count == 2)
        #expect(keys.contains("static let compactKeys: [TerminalKey] = ["))
        #expect(keys.contains(".clearLine, .enter, .esc, .tab, .ctrl, .ctrlC"))
        #expect(keys.contains("case .clearLine: \"eraser\""))
        #expect(keys.contains("case .enter: \"return\""))
        #expect(!keys.contains("case .clearLine: \"Clear\""))
        #expect(keys.contains(".ctrl, .ctrlC, .ctrlD, .ctrlZ, .clearScreen, .deleteWord"))
        #expect(!keys.contains(".esc, .ctrl, .tab, .up, .down, .left, .right"))
        #expect(!screen.contains(".ignoresSafeArea(.container, edges: .bottom)"))
        #expect(keybar.contains(".background(Color.connBar.ignoresSafeArea(edges: .bottom))"))
        #expect(host.contains("Button(L(\"保存\"))"))
        #expect(!keybar.contains("Button(L(\"执行\"))"))
    }

    @Test("终端会话操作仅保留切换与关闭页面，关闭页面不释放会话")
    func terminalSessionActionsClosePageWithoutClosingSession() throws {
        let source = try appSource("Terminal/TerminalScreen.swift")

        #expect(!source.contains("onReturnToTerminalList"))
        #expect(!source.contains("terminal.session-actions.return"))
        #expect(!source.contains("closeTerminalAndDismiss"))
        #expect(source.contains("case .closeTerminal:\n            dismiss()"))
        #expect(source.contains("terminal.session-actions.switch"))
        #expect(source.contains("terminal.session-actions.close"))
    }

    @Test("终端会话操作使用紧凑常规字重且仅图标使用主题色")
    func terminalSessionActionsUseConsistentTypographyAndAccentIcons() throws {
        let source = try appSource("Terminal/TerminalScreen.swift")

        #expect(source.contains("Text(title)\n                    .font(.connSubheadline)\n                    .foregroundStyle(.connInk)"))
        #expect(!source.contains("Text(title)\n                    .font(.connBody.weight(.semibold))"))
        #expect(source.contains("Image(systemName: systemName)\n                    .font(.system(size: 18, weight: .medium))\n                    .foregroundStyle(.connAccent)"))
        #expect(!source.contains(".foregroundStyle(destructive ? Color.connCrit : .connInk)"))
    }

    @Test("终端会话操作与会话列表统一居中标题和连接地址")
    func terminalSessionActionsMatchSessionListHeader() throws {
        let source = try appSource("Terminal/TerminalScreen.swift")

        #expect(source.contains("TerminalSessionActionsSheet(\n                        host: host,"))
        #expect(source.contains("NavigationStack"))
        #expect(source.contains(".navigationTitle(L(\"会话操作\"))"))
        #expect(source.contains(".navigationBarTitleDisplayMode(.inline)"))
        #expect(source.contains("Text(host.displayAddress)"))
        #expect(!source.contains("Text(host.name.isEmpty ? host.address : host.name)"))
        #expect(!source.contains("Text(L(\"当前终端\"))"))
    }

    @Test("编辑器与终端字号设置使用一致默认值和语言无关图标")
    func editorAndTerminalFontSettingsAreConsistent() throws {
        let settings = try appSource("Settings/SettingsStore.swift")
        let editorSettings = try appSource("Me/CodeEditorSettingsView.swift")
        let terminalSettings = try appSource("Me/TerminalSettingsView.swift")
        let editorConfiguration = try packageSource(
            "Sources/ConnEditor/CodeEditorConfiguration.swift"
        )

        #expect(settings.contains("? CodeEditorConfiguration.defaultFontSize"))
        #expect(settings.contains(": CodeEditorConfiguration.defaultFontSize"))
        #expect(editorConfiguration.contains("public static let defaultFontSize: Double = 10"))
        #expect(editorSettings.contains("Label(L(\"字体大小\"), systemImage: \"ruler\")"))
        #expect(terminalSettings.contains("Label(L(\"字体大小\"), systemImage: \"ruler\")"))
        #expect(!editorSettings.contains("systemImage: \"textformat.size\""))
        #expect(!terminalSettings.contains("systemImage: \"textformat.size\""))
    }

    @Test("终端真实重连提示立即居中显示并使用紧凑实色背景")
    func terminalReconnectNoticeUsesImmediateCenteredPresentation() throws {
        let source = try appSource("Terminal/TerminalScreen.swift")

        #expect(source.contains("TerminalReconnectingNotice()"))
        #expect(source.contains("alignment: .center"))
        #expect(source.contains("ProgressView()"))
        #expect(source.contains("terminal.reconnecting"))
        #expect(!source.contains("Task.sleep(for: .milliseconds(350))"))
        #expect(source.contains("RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)"))
        #expect(source.contains(".black.opacity(0.82)"))
        #expect(source.contains("maxHeight: .infinity, alignment: .top"))
    }

    @Test("终端会话中心只显示本地活动 Tab 或恢复记录，不探测远端目录")
    func terminalSessionCenterUsesOnlyLocalSessionState() throws {
        let source = try appSource("Terminal/TerminalSessionCenterView.swift")
        #expect(source.contains("sessions.hostGroups"))
        #expect(source.contains("ForEach(group.resumeRecords)"))
        #expect(!source.contains("@State private var hosts: [Host]"))
        #expect(!source.contains("displayedHostGroups"))
        #expect(!source.contains("persistentWorkspaceOptions"))
    }

    @Test("当前页面 tmux 启动流程允许选择已有 Session 或新建 Session")
    func tmuxLaunchPickerSupportsWorkspaceChoice() throws {
        let source = try appSource("Terminal/NewTerminalSheet.swift")
        #expect(source.contains("model.attach(workspace)"))
        #expect(source.contains("model.createWorkspace"))
        #expect(source.contains("Task { await model.refresh() }"))
        #expect(source.contains("accessibilityIdentifier(\"new-terminal.refresh-sessions\")"))

        let createSection = try #require(source.range(of: "Section(L(\"创建 Session\"))"))
        let existingSection = try #require(source.range(of: "Section(L(\"连接现有 Session\"))"))
        #expect(createSection.lowerBound < existingSection.lowerBound)
    }

    @Test("终端内新增会话复用当前页面 NewTerminalSheet")
    func additionalShellSessionReusesBackendChoiceFlow() throws {
        let source = try appSource("Terminal/TerminalScreen.swift")

        #expect(source.contains("NewTerminalSheet("))
        #expect(!source.contains("beginLaunchChoice"))
        #expect(!source.contains("PersistentWorkspacePicker"))
    }

    @Test("会话中心先在当前页面创建 Tab 再进入 existing TerminalScreen")
    func sessionCenterNewTerminalUsesCurrentPageChoiceFlow() throws {
        let source = try appSource("Terminal/TerminalSessionCenterView.swift")

        #expect(source.contains("NewTerminalSheet("))
        #expect(source.contains("tabID: route.tabID"))
        #expect(!source.contains("launchPolicy:"))
    }

    @Test("主机详情和服务器快捷入口优先打开本地 Tab 否则在当前页新建")
    func hostEntriesUseRecentTabOrCurrentPageSheet() throws {
        for path in ["Hosts/HostDetailView.swift", "Servers/ServersView.swift"] {
            let source = try appSource(path)

            #expect(source.contains("recentTab(forHost:"), "\(path) 没有优先复用本地 Tab")
            #expect(source.contains("NewTerminalSheet("), "\(path) 没有在源页面呈现新建流程")
            #expect(source.contains("fixedHost:"), "\(path) 未固定当前主机")
            #expect(source.contains("tabID: route.tabID"), "\(path) 没有按 existing Tab 打开")
            #expect(!source.contains("launchPolicy:"), "\(path) 仍让终端页负责创建")
        }
    }

    @Test("会话中心展开收起没有远端 Catalog 或管理副作用")
    func sessionCenterHasNoRemoteCatalogLifecycle() throws {
        let source = try appSource("Terminal/TerminalSessionCenterView.swift")

        #expect(!source.contains("remoteCatalogs"))
        #expect(!source.contains("openPersistentCatalog"))
        #expect(!source.contains("RemoteWorkspaceSummary"))
        #expect(!source.contains("TmuxWorkspaceManagementView"))
    }

    @Test("新建终端 Sheet 禁止下滑绕过关闭并在消失时兜底取消")
    func newTerminalSheetHasUnskippableCancellation() throws {
        let source = try appSource("Terminal/NewTerminalSheet.swift")

        #expect(source.contains(".interactiveDismissDisabled()"))
        #expect(source.contains(".onDisappear"))
        #expect(source.contains("model.closeImmediately()"))
        #expect(!source.contains("Task { await model.close() }"))
        #expect(source.contains("Button(L(\"关闭\")"))
    }

    @Test("所有终端创建入口复用同一 Sheet Loading")
    func terminalCreationReusesSharedSheetLoading() throws {
        let sheet = try appSource("Terminal/NewTerminalSheet.swift")
        let center = try appSource("Terminal/TerminalSessionCenterView.swift")
        let loading = try appSource("Terminal/TerminalCreationLoadingView.swift")

        #expect(sheet.contains("TerminalCreationLoadingView(title: L(\"正在创建终端…\"))"))
        #expect(center.contains("TerminalCreationLoadingView(title: L(\"正在创建终端…\"))"))
        #expect(center.contains("isPresented: $isCreatingReplacement"))
        #expect(center.contains(".presentationDetents([.medium, .large])"))
        #expect(center.contains("Button(L(\"关闭\")) { cancelReplacement() }"))
        #expect(!center.contains("ProgressView(L(\"正在创建终端…\"))"))
        #expect(loading.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        #expect(loading.contains(".accessibilityIdentifier(\"terminal.creation.loading\")"))
        #expect(!loading.contains(".background(Color.connBg)"))
    }

    @Test("非固定主机的新建流程可以返回重新选择主机")
    func newTerminalSheetCanReturnToHostSelection() throws {
        let source = try appSource("Terminal/NewTerminalSheet.swift")

        #expect(source.contains("case .terminalTypeSelection:\n            !model.hosts.isEmpty"))
        #expect(source.contains("await model.back()"))
    }

    @Test("终端列表使用系统左滑删除而不是行内关闭按钮")
    func terminalListsUseNativeSwipeToDelete() throws {
        let source = try appSource("Terminal/TerminalSessionCenterView.swift")
        let sheet = try appSource("Terminal/TerminalSessionListSheet.swift")

        #expect(source.contains("List {"))
        #expect(source.contains("hostRow(group)"))
        #expect(source.contains("if expandedHostIDs.contains(group.hostID)"))
        #expect(!source.contains("DisclosureGroup("))
        #expect(source.contains("Button { open(tab) } label: {\n            terminalRowContent(tab)"))
        #expect(source.contains("private func terminalRowContent(_ tab: TerminalTab)"))
        #expect(source.contains(".swipeActions(edge: .trailing, allowsFullSwipe: true)"))
        #expect(source.contains("Label(L(\"删除\"), systemImage: \"trash\")"))
        #expect(!source.contains("Image(systemName: \"xmark.circle\")"))
        #expect(source.contains("private static let compactRowInsets = EdgeInsets("))
        #expect(source.contains("top: ConnSpacing.xs"))
        #expect(!source.contains(".connSurface(cornerRadius: ConnRadius.listCard)"))
        #expect(!source.contains("cardListInsets"))
        #expect(source.contains(".listRowBackground(Color.connSurface)"))
        #expect(source.contains(".accessibilityIdentifier(\"terminal.session.\\(tab.id)\")"))
        #expect(source.contains(".accessibilityIdentifier(\"terminal.resume.\\(record.id)\")"))
        #expect(source.contains(".environment(\\.defaultMinListRowHeight, ConnSize.minTouchTarget)"))
        #expect(source.components(separatedBy: ".listRowInsets(Self.compactRowInsets)").count == 4)
        #expect(sheet.contains(".swipeActions(edge: .trailing, allowsFullSwipe: true)"))
        #expect(sheet.contains("Label(L(\"删除\"), systemImage: \"trash\")"))
        #expect(!sheet.contains("Label(L(\"关闭会话\"), systemImage: \"xmark.circle\")"))
    }

    @Test("Docker 与脚本入口先创建本地 Tab 再打开 existing TerminalScreen")
    func explicitTerminalEntriesUsePreparedLocalTabs() throws {
        for path in [
            "Hosts/DockerView.swift",
            "Hosts/ContainerDetailView.swift",
            "Commands/SnippetRunView.swift",
        ] {
            let source = try appSource(path)
            #expect(source.contains("TerminalLaunchPresentation"), "\(path) 未复用显式启动协调器")
            #expect(source.contains("TerminalLaunchRequest("), "\(path) 未保留来源启动请求")
            #expect(source.contains("$terminalLauncher.route"), "\(path) 没有在提交 Tab 后再打开终端页")
            #expect(source.contains("tabID: route.tabID"), "\(path) 仍可能让终端页自行创建连接")
            #expect(!source.contains("launchPolicy:"), "\(path) 仍在终端页内触发创建")
        }

        let screen = try appSource("Terminal/TerminalScreen.swift")
        #expect(screen.contains("@State private var tabID: String"))
        #expect(screen.contains("host: Host,\n        tabID: String,"))
        #expect(!screen.contains("TerminalLaunchRequest("))
        #expect(!screen.contains("persistentBackendCandidates"))
    }

    @Test("Docker 首页控制台启动失败会显示给用户")
    func dockerConsoleLaunchFailureIsPresented() throws {
        let source = try appSource("Hosts/DockerView.swift")

        #expect(source.contains(".onChange(of: terminalLauncher.errorMessage)"))
        #expect(source.contains("viewModel.actionMessage = message"))
    }

    @Test("显式终端入口同步失效当前 launch 并拒绝迟到完成")
    func explicitTerminalPresentationGuardsCancellationRace() throws {
        let source = try appSource("Terminal/TerminalLaunchPresentation.swift")

        #expect(source.contains("activeLaunchToken"))
        #expect(source.contains("activeLaunchToken == launchToken"))
        #expect(source.contains("model.closeImmediately()"))
        #expect(!source.contains("Task { await model.close() }"))
    }

    @Test("保存主机不创建或查询持久终端 provider 配置")
    func savedHostsStayIndependentFromPersistentTerminalProviders() throws {
        let source = try appSource("ConnApp.swift")
        let hostStore = try packageSource("Sources/ConnStore/DAO/HostStore.swift")
        let coordinator = try packageSource("Sources/ConnTerminal/TerminalSessionCoordinator.swift")

        #expect(source.contains("HostStore(database: database)"))
        #expect(!source.contains("TerminalBackendProfile"))
        #expect(!source.contains("defaultTerminalProfiles"))
        #expect(!source.contains("provisionDefaultTerminalProfiles"))
        #expect(!hostStore.contains("TerminalBackendProfile"))
        #expect(!hostStore.contains("terminal_backend_profile"))
        #expect(coordinator.contains("PersistentProviderBackend(registry: providerRegistry)"))
        #expect(!coordinator.contains("profileRepository"))
    }

    @Test("tmux 管理页只提交 typed operation 并使用破坏性确认")
    func tmuxManagementViewUsesTypedOperations() throws {
        let source = try appSource("Terminal/TmuxWorkspaceManagementView.swift")
        let hosting = try packageSource("Sources/ConnTerminal/TerminalHostingView.swift")
        #expect(source.contains("TmuxWorkspaceCatalogManaging"))
        #expect(source.contains("TmuxOperation"))
        #expect(source.contains("prepareDestructive"))
        #expect(source.contains("executeDestructive"))
        #expect(source.contains(".alert(\n                destructiveTitle,"))
        #expect(!source.contains(".confirmationDialog(\n                destructiveTitle,"))
        #expect(hosting.contains(".alert(\n                pendingConfirmationAction?.confirmation"))
        #expect(!hosting.contains(".confirmationDialog(\n                pendingConfirmationAction?.confirmation"))
    }

    @Test("tmux 管理页展示协商降级并提示共享的非破坏性影响")
    func tmuxManagementShowsDegradationAndSharedImpact() throws {
        let source = try appSource("Terminal/TmuxWorkspaceManagementView.swift")

        #expect(source.contains("catalog.controlCapabilities"))
        #expect(source.contains("catalog.controlConfiguration"))
        #expect(source.contains("metadataFreshnessWarning"))
        #expect(source.contains("previewImpact"))
        #expect(source.contains("pendingSharedOperation"))
        #expect(source.contains("pendingClientSelection"))
        #expect(!source.contains("snapshot.clients.values.first(where:"))
    }

    @Test("tmux 运行时交互由 Hub 排队且不使用瞬时 readiness 拦截")
    func tmuxRuntimeInteractionsDelegateBusyStateToHub() throws {
        let source = try packageSource("Sources/ConnMultiplexer/TmuxInteraction.swift")
        let hosting = try packageSource("Sources/ConnTerminal/TerminalHostingView.swift")
        let keybar = try packageSource("Sources/ConnTerminal/TerminalKeybar.swift")
        let facetStart = try #require(source.range(of: "package actor TmuxInteractionFacet"))
        let facet = source[facetStart.lowerBound...]

        #expect(!facet.contains("hasReadyControlRuntime"))
        #expect(facet.contains("controlLease.registry.performQuickAction("))
        #expect(facet.contains("controlLease.registry.scrollInteraction("))
        #expect(facet.contains("controlLease.registry.resolveInteraction("))
        #expect(hosting.contains("TerminalProviderActionQueue()"))
        #expect(hosting.contains("resolution: .currentAtExecution"))
        #expect(!hosting.contains("providerNavigationTask"))
        #expect(!hosting.contains("providerNavigationQueue"))
        #expect(!keybar.contains(".disabled(performingProviderQuickActionID != nil)"))
    }

    @Test("tmux 快捷键通过系统确认关闭当前 Session 并结束 Workspace")
    func tmuxQuickActionsCloseCurrentSessionThroughConfirmedQueue() throws {
        let interaction = try packageSource("Sources/ConnMultiplexer/TmuxInteraction.swift")
        let hub = try packageSource("Sources/ConnMultiplexer/TmuxControlHub.swift")
        let hosting = try packageSource("Sources/ConnTerminal/TerminalHostingView.swift")

        #expect(interaction.contains("case closeSession = \"tmux.session.close\""))
        #expect(interaction.contains("descriptor(\n                    .closeSession,\n                    \"关闭 Session\""))
        #expect(interaction.contains("confirmation: .init(titleKey: \"关闭当前 Session？\")"))
        #expect(interaction.contains("case .closeSession:\n            .killSession(state.sessionID)"))
        #expect(hub.contains("case .closeSession:\n            true"))
        #expect(hosting.contains("confirmsDestructiveAction: true"))
        #expect(hosting.contains("resolution: .currentAtExecution"))
        #expect(hosting.contains("case .workspaceClosed:"))
    }

    @Test("创建 Docker 命令保存成功后锁定按钮并防止重复保存")
    func dockerCommandSaveLocksAfterSuccess() throws {
        let runForm = try appSource("Hosts/DockerRunFormView.swift")
        let resourceForms = try appSource("Hosts/DockerResourceFormViews.swift")
        let viewModel = try appSource("Hosts/DockerViewModel.swift")

        for source in [runForm, resourceForms] {
            #expect(source.contains("@State private var isCommandSaved = false"))
            #expect(source.contains(".disabled(!state.isValid || isCommandSaved)"))
            #expect(source.contains("guard !isCommandSaved else { return }"))
            #expect(source.contains("isCommandSaved = true"))
        }
        #expect(runForm.contains("try onSave(title, command)"))
        #expect(resourceForms.contains("try onSave(title, previewCommand)"))
        #expect(!viewModel.contains("platforms:"))
        #expect(viewModel.contains("requiredCapabilities: [.docker]"))
        #expect(viewModel.contains("$0.builtinKey == \"docker\""))
    }

    @Test("密钥详情支持重命名并同步保存")
    func keyDetailsCanRename() throws {
        let view = try appSource("Keys/KeyManagerView.swift")
        let viewModel = try appSource("Keys/KeyManagerViewModel.swift")

        #expect(view.contains("重命名"))
        #expect(view.contains("isRenamePresented"))
        #expect(viewModel.contains("func rename"))
    }

    @Test("主机认证只提供密码与密钥，密钥管家使用导航栏新增")
    func sshAuthAndKeyManagerUseCurrentDesign() throws {
        let hostForm = try appSource("Hosts/HostFormView.swift")
        let keyManager = try appSource("Keys/KeyManagerView.swift")
        #expect(!hostForm.contains("keyPassphrase"))
        #expect(!hostForm.contains("密码短语"))
        #expect(keyManager.contains("ToolbarItem(placement: .topBarTrailing)"))
        #expect(keyManager.contains("ForEach(SSHKey.Kind.allCases"))
        #expect(keyManager.contains("导入私钥"))
    }

    @Test("主机展示只使用名称，不再暴露备注字段")
    func hostPresentationUsesNameOnly() throws {
        let form = try appSource("Hosts/HostFormView.swift")
        let servers = try appSource("Servers/ServersViewModel.swift")
        let detail = try appSource("Hosts/HostDetailView.swift")
        let docker = try appSource("Hosts/DockerView.swift")
        let card = try packageSource("Sources/ConnUI/Components/HealthCard.swift")

        #expect(!form.contains("备注"))
        #expect(!form.contains("noteSection"))
        #expect(!servers.contains("note:"))
        #expect(detail.contains("private var displayTitle: String { host.name }"))
        #expect(docker.contains("private var hostTitle: String { host.name }"))
        #expect(card.contains("var title: String { name }"))
        #expect(!card.contains("public let note: String?"))
    }

    @Test("主机登录密码支持显示与隐藏切换")
    func hostPasswordCanToggleVisibility() throws {
        let hostForm = try appSource("Hosts/HostFormView.swift")

        #expect(hostForm.contains("@State private var isPasswordVisible = false"))
        #expect(hostForm.contains("isPasswordVisible.toggle()"))
        #expect(hostForm.contains("SecureField(L(\"选填\"), text: text)"))
        #expect(hostForm.contains("TextField(L(\"选填\"), text: text)"))
        #expect(hostForm.contains("L(\"显示密码\")"))
        #expect(hostForm.contains("L(\"隐藏密码\")"))
    }

    @Test("服务器和命令表单的分组选择默认收起")
    func groupSelectionFormsUseCollapsedDisclosureGroups() throws {
        let hostForm = try appSource("Hosts/HostFormView.swift")
        let snippetForm = try appSource("Commands/SnippetFormView.swift")

        #expect(hostForm.contains("@State private var isGroupExpanded = false"))
        #expect(hostForm.contains("DisclosureGroup(isExpanded: $isGroupExpanded)"))
        #expect(snippetForm.contains("@State private var isGroupsExpanded = false"))
        #expect(snippetForm.contains("DisclosureGroup(isExpanded: $isGroupsExpanded)"))
    }

    @Test("服务器首页在短列表和空列表时仍可下拉刷新")
    func serverHomeAlwaysSupportsPullToRefresh() throws {
        let source = try appSource("Servers/ServersView.swift")

        #expect(
            source.contains(
                "private var hostsContent: some View {\n        ScrollView {\n            if viewModel.hosts.isEmpty {"
            )
        )
        #expect(source.contains(".containerRelativeFrame(.vertical)"))
        #expect(source.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
        #expect(source.contains(".refreshable { await viewModel.refresh() }"))
        #expect(!source.contains(".scrollBounceBehavior(.basedOnSize)"))
    }

    @Test("服务器卡片的内存和磁盘显示已用与总量")
    func serverCardsShowUsedAndTotalStorage() throws {
        let source = try appSource("Servers/ServersViewModel.swift")
        let healthCard = try packageSource("Sources/ConnUI/Components/HealthCard.swift")

        #expect(source.contains("memTotalText: MetricFormat.compactPair(used: metrics?.memUsedBytes, total: metrics?.memTotalBytes)"))
        #expect(source.contains("diskTotalText: MetricFormat.compactPair(used: metrics?.diskUsedBytes, total: metrics?.diskTotalBytes)"))
        #expect(!source.contains("memTotalText: MetricFormat.pair(used: metrics?.memUsedBytes, total: metrics?.memTotalBytes)"))
        #expect(!source.contains("diskTotalText: MetricFormat.pair(used: metrics?.diskUsedBytes, total: metrics?.diskTotalBytes)"))
        #expect(healthCard.contains("VStack(alignment: .center, spacing: 3)"))
        #expect(healthCard.contains(".frame(maxWidth: .infinity, alignment: .center)"))
        #expect(healthCard.contains(".multilineTextAlignment(.center)"))
    }

    @Test("Swap 只显示用量摘要和进度条，不采集独立趋势")
    func swapUsesCompactSummaryWithoutTrendChart() throws {
        let view = try appSource("Hosts/HostOverviewView.swift")
        let viewModel = try appSource("Hosts/HostOverviewViewModel.swift")

        #expect(view.contains("private var swapSummary"))
        #expect(view.contains("ConnLoadBar(percent: percent"))
        #expect(!view.contains("viewModel.swapUsedHistory"))
        #expect(!view.contains("hasSwapHistory"))
        #expect(!viewModel.contains("swapUsedHistory"))
    }

    @Test("文件管理页使用导航栏下方固定系统搜索")
    func fileBrowserUsesPersistentNavigationSearch() throws {
        let source = try appSource("Files/FileBrowserView.swift")

        #expect(source.contains("placement: .navigationBarDrawer(displayMode: .always)"))
        #expect(source.contains("prompt: L(\"搜索当前目录\")"))
        #expect(!source.contains("ConnSearchField(L(\"搜索当前目录\")"))
        #expect(!source.contains("private var searchField"))
    }

    @Test("文件管理操作移至导航栏并替代终端入口")
    func fileBrowserUsesNavigationActionsWithoutTerminal() throws {
        let fileBrowser = try appSource("Files/FileBrowserView.swift")
        let hostDetail = try appSource("Hosts/HostDetailView.swift")

        #expect(fileBrowser.contains(".toolbar { fileActionsToolbar }"))
        #expect(fileBrowser.contains("private var fileActionsToolbar: some ToolbarContent"))
        #expect(fileBrowser.contains("ToolbarItem(placement: .topBarTrailing)"))
        #expect(fileBrowser.contains("Image(systemName: \"ellipsis.circle\")"))
        #expect(!fileBrowser.contains("ConnMoreActionsIcon()"))
        #expect(hostDetail.contains("case .files:\n            modulePage(showsTerminal: false)"))
    }

    @Test("进程列表使用导航栏下方固定系统搜索")
    func processListUsesPersistentNavigationSearch() throws {
        let source = try appSource("Hosts/ProcessListView.swift")

        #expect(source.contains("placement: .navigationBarDrawer(displayMode: .always)"))
        #expect(source.contains("prompt: L(\"搜索进程 / PID / 用户\")"))
        #expect(!source.contains("ConnSearchField(L(\"搜索进程 / PID / 用户\")"))
        #expect(!source.contains("private var searchField"))
    }

    @Test("模块整页失败统一走恢复加载而非静默刷新")
    func featureFailureRetriesUseRecoveryLoads() throws {
        let cases = [
            ("Hosts/ProcessListView.swift", "await viewModel.retryProcesses()"),
            ("Files/FileBrowserView.swift", "await viewModel.load()"),
            ("Hosts/DockerView.swift", "await viewModel.load()"),
            ("Hosts/LogCenterView.swift", "await viewModel.load()"),
        ]

        for (path, expectedAction) in cases {
            let block = try failureBlock(in: appSource(path))
            #expect(block.contains("ConnRetryState("), "\(path) 未使用统一错误状态")
            #expect(block.contains(expectedAction), "\(path) 的重试没有执行恢复加载")
        }

        let fileBlock = try failureBlock(in: appSource("Files/FileBrowserView.swift"))
        #expect(!fileBlock.contains("viewModel.refresh()"), "文件整页失败不能走仅适用于已有列表的静默刷新")
    }

    @Test("文件与日志子页面失败同样提供内联恢复入口")
    func fileAndLogDetailFailuresAreRecoverableInline() throws {
        let editor = try appSource("Files/FileEditorView.swift")
        #expect(editor.contains("ConnRetryState(message, retryTitle: L(\"重试\"))"))
        #expect(editor.contains("Task { await viewModel.load() }"))
        #expect(editor.contains("cachedFileSystem = nil"), "文件读取失败后必须丢弃可能已坏的 SFTP 通道")

        let logView = try appSource("Hosts/LogStreamView.swift")
        let logModel = try appSource("Hosts/LogStreamViewModel.swift")
        #expect(logView.contains("ConnRetryState(error, retryTitle: L(\"重试\"))"))
        #expect(logView.contains("viewModel.retry()"))
        #expect(logModel.contains("func retry()"))
        #expect(logModel.contains("stop()\n        start()"))
    }

    @Test("目录选择器失败后丢弃旧 SFTP 通道再重试")
    func directoryPickerDropsFailedFileSystem() throws {
        let source = try appSource("Files/DirectoryPickerView.swift")
        #expect(source.contains(
            "        } catch {\n            fileSystem = nil\n            errorText = error.friendlyDiagnosis"
        ))
    }

    private func failureBlock(in source: String) throws -> String {
        let start = try #require(source.range(of: "case let .failed(message):"))
        let end = try #require(source.range(of: "case .ready:", range: start.upperBound ..< source.endIndex))
        return String(source[start.lowerBound ..< end.lowerBound])
    }

    private func appSource(_ relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectURL.appending(path: "Conn/\(relativePath)"),
            encoding: .utf8
        )
    }

    private func packageSource(_ relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectURL.appending(path: "Packages/ConnPackages/\(relativePath)"),
            encoding: .utf8
        )
    }

    private func vendorSource(_ relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectURL.appending(path: "Packages/Vendor/\(relativePath)"),
            encoding: .utf8
        )
    }
}
