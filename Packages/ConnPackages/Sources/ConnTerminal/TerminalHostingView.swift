#if canImport(UIKit)
    import ConnMultiplexer
    import ConnSSH
    import ConnUI
    import OSLog
    import SwiftTerm
    import SwiftUI
    import UIKit

    private let terminalInteractionLogger = Logger(
        subsystem: "com.crazyball.Conn",
        category: "TerminalInteraction"
    )

    private struct TerminalInteractionNotice: Equatable {
        let id = UUID()
        let text: String
        let style: ConnToastStyle
    }

    /// SwiftUI 终端容器。
    ///
    /// 终端视口与快捷键栏是同一个 `VStack` 里的相邻区域；系统键盘位于两者下方。
    /// 快捷键栏展开时会真实压缩终端视口，不再通过 `inputAccessoryView` 悬浮覆盖内容。
    public struct TerminalHostingView: View {
        private let session: TerminalSession
        private let transcript: TerminalTranscript
        private let persistentAttachment: (any PersistentTerminalAttachment)?
        private let persistentInteraction: (any PersistentTerminalInteractionFacet)?
        private let tabID: String
        private let terminalGeneration: UInt64
        private let insertionMailbox: TerminalTextInsertionMailbox?
        private let configuration: TerminalConfiguration
        private let onShowSessionActions: () -> Void
        private let onChooseCommand: () -> Void
        private let onReconnect: () -> Void
        private let onPersistentWorkspaceRenamed: (String) -> Void
        private let onPersistentWorkspaceChanged: (String, String?) -> Void
        private let onPersistentWorkspaceClosed: () -> Void
        private let attachmentState: TerminalAttachmentPanelState
        private let onAttachmentAction: (TerminalAttachmentAction) -> Void
        private let onPersistentWorkingDirectoryChanged: (String?) -> Void
        private let onTerminalWorkingDirectoryChanged:
            (TerminalWorkingDirectorySource, UInt64, String?) -> Void

        public init(
            session: TerminalSession,
            transcript: TerminalTranscript,
            persistentAttachment: (any PersistentTerminalAttachment)? = nil,
            persistentInteraction: (any PersistentTerminalInteractionFacet)? = nil,
            tabID: String = "",
            terminalGeneration: UInt64 = 0,
            insertionMailbox: TerminalTextInsertionMailbox? = nil,
            configuration: TerminalConfiguration = .init(),
            onShowSessionActions: @escaping () -> Void = {},
            onChooseCommand: @escaping () -> Void = {},
            onReconnect: @escaping () -> Void = {},
            onPersistentWorkspaceRenamed: @escaping (String) -> Void = { _ in },
            onPersistentWorkspaceChanged: @escaping (String, String?) -> Void = { _, _ in },
            onPersistentWorkspaceClosed: @escaping () -> Void = {},
            attachmentState: TerminalAttachmentPanelState = .idle,
            onAttachmentAction: @escaping (TerminalAttachmentAction) -> Void = { _ in },
            onPersistentWorkingDirectoryChanged: @escaping (String?) -> Void = { _ in },
            onTerminalWorkingDirectoryChanged: @escaping (
                TerminalWorkingDirectorySource, UInt64, String?
            ) -> Void = { _, _, _ in }
        ) {
            self.session = session
            self.transcript = transcript
            self.persistentAttachment = persistentAttachment
            self.persistentInteraction = persistentInteraction
            self.tabID = tabID
            self.terminalGeneration = terminalGeneration
            self.insertionMailbox = insertionMailbox
            self.configuration = configuration
            self.onShowSessionActions = onShowSessionActions
            self.onChooseCommand = onChooseCommand
            self.onReconnect = onReconnect
            self.onPersistentWorkspaceRenamed = onPersistentWorkspaceRenamed
            self.onPersistentWorkspaceChanged = onPersistentWorkspaceChanged
            self.onPersistentWorkspaceClosed = onPersistentWorkspaceClosed
            self.attachmentState = attachmentState
            self.onAttachmentAction = onAttachmentAction
            self.onPersistentWorkingDirectoryChanged = onPersistentWorkingDirectoryChanged
            self.onTerminalWorkingDirectoryChanged = onTerminalWorkingDirectoryChanged
        }

        public var body: some View {
            TerminalHostContent(
                session: session,
                transcript: transcript,
                persistentAttachment: persistentAttachment,
                persistentInteraction: persistentInteraction,
                tabID: tabID,
                terminalGeneration: terminalGeneration,
                insertionMailbox: insertionMailbox,
                configuration: configuration,
                onShowSessionActions: onShowSessionActions,
                onChooseCommand: onChooseCommand,
                onReconnect: onReconnect,
                onPersistentWorkspaceRenamed: onPersistentWorkspaceRenamed,
                onPersistentWorkspaceChanged: onPersistentWorkspaceChanged,
                onPersistentWorkspaceClosed: onPersistentWorkspaceClosed,
                attachmentState: attachmentState,
                onAttachmentAction: onAttachmentAction,
                onPersistentWorkingDirectoryChanged: onPersistentWorkingDirectoryChanged,
                onTerminalWorkingDirectoryChanged: onTerminalWorkingDirectoryChanged
            )
            // 重连会换一个 TerminalSession；显式换身份，避免 @StateObject 继续持有旧会话。
            .id(ObjectIdentifier(session))
        }
    }

    private struct TerminalHostContent: View {
        @StateObject private var controller: TerminalInputController
        @State private var isKeybarExpanded: Bool
        /// 收起系统键盘后仍保留快捷键栏。键盘响应者状态和快捷键栏展示状态
        /// 是两个独立的交互状态，不能用同一个 focus 信号驱动。
        @State private var keepsKeybarVisible = false
        /// Provider 快捷操作弹窗必须由稳定的终端宿主持有。若状态放在快捷键栏中，
        /// Alert 输入框抢走终端焦点时快捷键栏会被移除，Alert 也会随之销毁。
        @State private var pendingTextInputAction: PersistentTerminalQuickActionDescriptor?
        @State private var pendingConfirmationAction: PersistentTerminalQuickActionDescriptor?
        @State private var quickActionText = ""
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.connToastCenter) private var toastCenter

        private let configuration: TerminalConfiguration
        private let tabID: String
        private let terminalGeneration: UInt64
        private let insertionMailbox: TerminalTextInsertionMailbox?
        private let onShowSessionActions: () -> Void
        private let onChooseCommand: () -> Void
        private let onReconnect: () -> Void
        private let attachmentState: TerminalAttachmentPanelState
        private let onAttachmentAction: (TerminalAttachmentAction) -> Void
        private let onPersistentWorkingDirectoryChanged: (String?) -> Void
        private let onTerminalWorkingDirectoryChanged:
            (TerminalWorkingDirectorySource, UInt64, String?) -> Void

        init(
            session: TerminalSession,
            transcript: TerminalTranscript,
            persistentAttachment: (any PersistentTerminalAttachment)?,
            persistentInteraction: (any PersistentTerminalInteractionFacet)?,
            tabID: String,
            terminalGeneration: UInt64,
            insertionMailbox: TerminalTextInsertionMailbox?,
            configuration: TerminalConfiguration,
            onShowSessionActions: @escaping () -> Void,
            onChooseCommand: @escaping () -> Void,
            onReconnect: @escaping () -> Void,
            onPersistentWorkspaceRenamed: @escaping (String) -> Void,
            onPersistentWorkspaceChanged: @escaping (String, String?) -> Void,
            onPersistentWorkspaceClosed: @escaping () -> Void,
            attachmentState: TerminalAttachmentPanelState,
            onAttachmentAction: @escaping (TerminalAttachmentAction) -> Void,
            onPersistentWorkingDirectoryChanged: @escaping (String?) -> Void,
            onTerminalWorkingDirectoryChanged: @escaping (
                TerminalWorkingDirectorySource, UInt64, String?
            ) -> Void
        ) {
            _controller = StateObject(wrappedValue: TerminalInputController(
                session: session,
                transcript: transcript,
                persistentAttachment: persistentAttachment,
                persistentInteraction: persistentInteraction,
                terminalGeneration: terminalGeneration,
                onPersistentWorkspaceRenamed: onPersistentWorkspaceRenamed,
                onPersistentWorkspaceChanged: onPersistentWorkspaceChanged,
                onPersistentWorkspaceClosed: onPersistentWorkspaceClosed,
                onPersistentWorkingDirectoryChanged: onPersistentWorkingDirectoryChanged,
                onTerminalWorkingDirectoryChanged: onTerminalWorkingDirectoryChanged
            ))
            _isKeybarExpanded = State(initialValue: false)
            self.configuration = configuration
            self.tabID = tabID
            self.terminalGeneration = terminalGeneration
            self.insertionMailbox = insertionMailbox
            self.onShowSessionActions = onShowSessionActions
            self.onChooseCommand = onChooseCommand
            self.onReconnect = onReconnect
            self.attachmentState = attachmentState
            self.onAttachmentAction = onAttachmentAction
            self.onPersistentWorkingDirectoryChanged = onPersistentWorkingDirectoryChanged
            self.onTerminalWorkingDirectoryChanged = onTerminalWorkingDirectoryChanged
        }

        var body: some View {
            VStack(spacing: 0) {
                TerminalViewportRepresentable(
                    configuration: configuration,
                    controller: controller
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if TerminalKeybarVisibilityPolicy.shouldShow(
                    configurationShowsKeybar: configuration.showsKeybar,
                    terminalFocused: controller.isTerminalFocused,
                    reviewActive: controller.isReviewActive,
                    userPinned: keepsKeybarVisible,
                    providerActionPresented: isProviderActionPresented
                ) {
                    TerminalKeybar(
                        ctrlActive: controller.ctrlActive,
                        isExpanded: isKeybarExpanded,
                        onKey: controller.handleKey,
                        onPaste: { controller.handlePaste($0) },
                        onInsertToolCommand: insertToolCommand,
                        onShowSessionActions: showSessionActions,
                        onChooseCommand: onChooseCommand,
                        onReconnect: onReconnect,
                        pointerAvailable: controller.pointerAvailable,
                        pointerActive: controller.pointerActive,
                        onTogglePointer: controller.togglePointer,
                        providerQuickActionGroup: controller.providerQuickActionGroup,
                        performingProviderQuickActionID: controller.performingProviderQuickActionID,
                        onProviderQuickAction: selectProviderQuickAction,
                        keyboardVisible: controller.isTerminalFocused,
                        onToggleKeyboard: {
                            keepsKeybarVisible = true
                            controller.toggleKeyboard()
                        },
                        onExpansionChange: setKeybarExpanded,
                        attachmentState: attachmentState,
                        onAttachmentAction: onAttachmentAction
                    )
                    .frame(
                        height: isKeybarExpanded
                            ? TerminalKeybarMetrics.expandedHeight
                            : TerminalKeybarMetrics.compactHeight
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("terminal.keybar")
                } else {
                    TerminalSessionActionsBar(onShowSessionActions: showSessionActions)
                        .frame(height: TerminalKeybarMetrics.compactHeight)
                }
            }
            .alert(
                pendingTextInputAction.map { L($0.textInput?.titleKey ?? $0.titleKey) } ?? "",
                isPresented: Binding(
                    get: { pendingTextInputAction != nil },
                    set: {
                        if !$0 {
                            pendingTextInputAction = nil
                        }
                    }
                )
            ) {
                if let input = pendingTextInputAction?.textInput {
                    TextField(L(input.placeholderKey), text: $quickActionText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button(L("取消"), role: .cancel) {
                    pendingTextInputAction = nil
                }
                Button(L("保存")) {
                    guard let action = pendingTextInputAction else { return }
                    let value = quickActionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    controller.performQuickAction(
                        action.id,
                        argument: value,
                        confirmsDestructiveAction: false
                    )
                    pendingTextInputAction = nil
                }
                .disabled(quickActionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert(
                pendingConfirmationAction?.confirmation.map { L($0.titleKey) } ?? "",
                isPresented: Binding(
                    get: { pendingConfirmationAction != nil },
                    set: {
                        if !$0 {
                            pendingConfirmationAction = nil
                        }
                    }
                ),
            ) {
                if let action = pendingConfirmationAction {
                    Button(L(action.titleKey), role: .destructive) {
                        pendingConfirmationAction = nil
                        controller.performQuickAction(
                            action.id,
                            argument: nil,
                            confirmsDestructiveAction: true
                        )
                    }
                }
                Button(L("取消"), role: .cancel) {
                    pendingConfirmationAction = nil
                }
            }
            .onChange(of: controller.isTerminalFocused) { _, isFocused in
                if !isFocused,
                   !controller.isReviewActive,
                   !keepsKeybarVisible,
                   !isProviderActionPresented {
                    isKeybarExpanded = false
                }
            }
            .onChange(of: controller.providerQuickActionGroup?.id) { _, groupID in
                if groupID == nil {
                    pendingTextInputAction = nil
                    pendingConfirmationAction = nil
                }
            }
            .onChange(of: controller.interactionNotice) { _, notice in
                guard let notice else { return }
                toastCenter.show(notice.text, style: notice.style)
            }
            .onChange(of: controller.inputEpoch) { _, _ in synchronizeInsertionContext() }
            .onChange(of: controller.persistentTarget) { _, _ in synchronizeInsertionContext() }
            .onChange(of: insertionMailbox?.pending?.id) { _, _ in
                guard let text = insertionMailbox?.consumeIfCurrent() else { return }
                controller.handlePaste(text, source: .programmatic)
            }
            .onAppear {
                controller.setApplicationActive(scenePhase == .active)
                synchronizeInsertionContext()
            }
            .onChange(of: scenePhase) { _, phase in
                controller.setApplicationActive(phase == .active)
            }
            .onDisappear { controller.detach() }
        }

        private func setKeybarExpanded(_ expanded: Bool) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isKeybarExpanded = expanded
            }
        }

        private var isProviderActionPresented: Bool {
            pendingTextInputAction != nil || pendingConfirmationAction != nil
        }

        private func showSessionActions() {
            // The page-level entry remains reachable after a sheet temporarily takes
            // terminal focus and dismisses the software keyboard.
            keepsKeybarVisible = true
            onShowSessionActions()
        }

        private func synchronizeInsertionContext() {
            insertionMailbox?.updateContext(.init(
                tabID: tabID,
                generation: terminalGeneration,
                inputEpoch: controller.inputEpoch,
                persistentTarget: controller.persistentTarget
            ))
        }

        /// Tool shortcuts use the same generation- and target-aware insertion path as
        /// uploaded attachment paths. Falling back to the controller keeps previews and
        /// embedders without a mailbox functional.
        private func insertToolCommand(_ command: String) {
            guard let insertionMailbox,
                  let context = insertionMailbox.currentContext else {
                controller.handlePaste(command, source: .programmatic)
                return
            }
            insertionMailbox.enqueue(command, expectedContext: context)
        }

        private func selectProviderQuickAction(
            _ action: PersistentTerminalQuickActionDescriptor
        ) {
            if action.confirmation != nil {
                pendingTextInputAction = nil
                pendingConfirmationAction = action
            } else if action.textInput != nil {
                pendingConfirmationAction = nil
                quickActionText = ""
                pendingTextInputAction = action
            } else {
                controller.performQuickAction(
                    action.id,
                    argument: nil,
                    confirmsDestructiveAction: false
                )
            }
        }
    }

    /// 只包装 SwiftTerm 视口；快捷键栏由上层 SwiftUI 布局负责。
    private struct TerminalViewportRepresentable: UIViewRepresentable {
        let configuration: TerminalConfiguration
        let controller: TerminalInputController

        func makeUIView(context _: Context) -> KeybarTerminalView {
            let terminalView = KeybarTerminalView(frame: .zero)
            terminalView.accessibilityIdentifier = "terminal.viewport"
            terminalView.terminalDelegate = controller
            terminalView.onFirstResponderChange = controller.setTerminalFocused
            terminalView.onSystemPaste = { controller.handlePaste($0, source: .systemMenu) }
            applyConfiguration(to: terminalView)
            terminalView.configureContentPadding(horizontal: ConnSpacing.sm)
            controller.attach(terminalView)
            return terminalView
        }

        func updateUIView(_ terminalView: KeybarTerminalView, context _: Context) {
            applyConfiguration(to: terminalView)
            terminalView.configureContentPadding(horizontal: ConnSpacing.sm)
        }

        static func dismantleUIView(_ terminalView: KeybarTerminalView, coordinator _: Void) {
            terminalView.onFirstResponderChange = nil
            terminalView.onSystemPaste = nil
            terminalView.removeInteractionHost()
        }

        private func applyConfiguration(to terminalView: KeybarTerminalView) {
            let fontSize = CGFloat(configuration.fontSize)
            if abs(terminalView.font.pointSize - fontSize) > 0.01 {
                terminalView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }

            let terminal = terminalView.getTerminal()
            if terminal.options.scrollback != configuration.scrollback {
                terminalView.changeScrollback(configuration.scrollback)
            }

            let cursorStyle = swiftTermCursorStyle
            if terminalView.configuredCursorShape != configuration.cursorShape
                || terminalView.configuredCursorBlinking != configuration.cursorBlinking {
                terminal.options.cursorStyle = cursorStyle
                terminalView.cursorStyleChanged(source: terminal, newStyle: cursorStyle)
                terminalView.configuredCursorShape = configuration.cursorShape
                terminalView.configuredCursorBlinking = configuration.cursorBlinking
            }

            func color(_ rgb: TerminalTheme.RGB) -> SwiftTerm.Color {
                // 主题数据转 SwiftTerm 调色板类型——数据转换，非 UI 样式硬编码。
                // swiftlint:disable:next no_hardcoded_hex
                SwiftTerm.Color(red: UInt16(rgb.r) * 257, green: UInt16(rgb.g) * 257, blue: UInt16(rgb.b) * 257)
            }
            let theme = configuration.theme
            terminal.installPalette(colors: theme.ansi.map(color))
            terminalView.nativeBackgroundColor = uiColor(theme.background)
            terminalView.nativeForegroundColor = uiColor(theme.foreground)
            terminalView.caretColor = uiColor(theme.cursor)
        }

        private var swiftTermCursorStyle: SwiftTerm.CursorStyle {
            switch (configuration.cursorShape, configuration.cursorBlinking) {
            case (.block, true): .blinkBlock
            case (.block, false): .steadyBlock
            case (.bar, true): .blinkBar
            case (.bar, false): .steadyBar
            case (.underline, true): .blinkUnderline
            case (.underline, false): .steadyUnderline
            }
        }

        private func uiColor(_ rgb: TerminalTheme.RGB) -> UIColor {
            UIColor(
                red: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: 1
            )
        }
    }

    /// SwiftTerm delegate、会话输入和 SwiftUI 键条共享的单一状态源。
    @MainActor
    private final class TerminalInputController: NSObject, @preconcurrency TerminalViewDelegate, ObservableObject {
        private let session: TerminalSession
        private let transcript: TerminalTranscript
        private let persistentAttachment: (any PersistentTerminalAttachment)?
        private let persistentInteraction: (any PersistentTerminalInteractionFacet)?
        private let terminalGeneration: UInt64
        private let onPersistentWorkspaceRenamed: (String) -> Void
        private let onPersistentWorkspaceChanged: (String, String?) -> Void
        private let onPersistentWorkspaceClosed: () -> Void
        private let onPersistentWorkingDirectoryChanged: (String?) -> Void
        private let onTerminalWorkingDirectoryChanged:
            (TerminalWorkingDirectorySource, UInt64, String?) -> Void
        private let replayOutboundGate = TerminalReplayOutboundGate()
        private let interactionController = TerminalInteractionController()
        private let typedInputPlanner = TerminalTypedInputPlanner()

        private var renderTask: Task<Void, Never>?
        private var persistentStateTask: Task<Void, Never>?
        private var historyCaptureTask: Task<Void, Never>?
        private var historyCaptureID: UUID?
        private var historyCaptureToken: TerminalRouteToken?
        private var stateResolutionTask: Task<Void, Never>?
        private var providerScrollTask: Task<Void, Never>?
        private var quickActionDiscoveryTask: Task<Void, Never>?
        private var quickActionExecutionTask: Task<Void, Never>?
        private var noticeTask: Task<Void, Never>?
        private var viewportTask: Task<Void, Never>?
        private var attachmentID: UUID?
        private var protocolState: TerminalProtocolState?
        private var persistentState: PersistentTerminalInteractionState?
        private var scrollAccumulator = TerminalScrollAccumulator(rowHeight: 18)
        private var scrollHit = TerminalInteractionHit(column: 0, row: 0, pixelX: 0, pixelY: 0)
        private var providerPendingRows = 0
        private var providerActionQueue = TerminalProviderActionQueue()
        private var clipboardPolicy = TerminalClipboardPolicy()
        private var focusState = TerminalFocusState()
        private var isTypedPaste = false
        private var isHostProtocolEmission = false
        private var applicationActive = true
        private var rendererReadyForRemoteViewport = false
        private var lastViewportSize: TermSize?
        private var requestedProviderViewport: PersistentTerminalViewportState?
        private var viewportRequestID: UUID?
        weak var terminalView: KeybarTerminalView?

        @Published var ctrlActive = false
        @Published private(set) var isTerminalFocused = false
        @Published private(set) var pointerAvailable = false
        @Published private(set) var pointerActive = false
        @Published private(set) var isReviewActive = false
        @Published private(set) var interactionNotice: TerminalInteractionNotice?
        @Published private(set) var providerQuickActionGroup: PersistentTerminalQuickActionGroup?
        @Published private(set) var performingProviderQuickActionID: String?
        @Published private(set) var inputEpoch: UInt64 = 0
        @Published private(set) var persistentTarget: PersistentTerminalInteractionTarget?
        @Published private(set) var persistentWorkingDirectory: String?

        init(
            session: TerminalSession,
            transcript: TerminalTranscript,
            persistentAttachment: (any PersistentTerminalAttachment)?,
            persistentInteraction: (any PersistentTerminalInteractionFacet)?,
            terminalGeneration: UInt64,
            onPersistentWorkspaceRenamed: @escaping (String) -> Void,
            onPersistentWorkspaceChanged: @escaping (String, String?) -> Void,
            onPersistentWorkspaceClosed: @escaping () -> Void,
            onPersistentWorkingDirectoryChanged: @escaping (String?) -> Void,
            onTerminalWorkingDirectoryChanged: @escaping (
                TerminalWorkingDirectorySource, UInt64, String?
            ) -> Void
        ) {
            self.session = session
            self.transcript = transcript
            self.persistentAttachment = persistentAttachment
            self.persistentInteraction = persistentInteraction
            self.terminalGeneration = terminalGeneration
            self.onPersistentWorkspaceRenamed = onPersistentWorkspaceRenamed
            self.onPersistentWorkspaceChanged = onPersistentWorkspaceChanged
            self.onPersistentWorkspaceClosed = onPersistentWorkspaceClosed
            self.onPersistentWorkingDirectoryChanged = onPersistentWorkingDirectoryChanged
            self.onTerminalWorkingDirectoryChanged = onTerminalWorkingDirectoryChanged
        }

        func attach(_ terminalView: KeybarTerminalView) {
            detach()
            self.terminalView = terminalView
            rendererReadyForRemoteViewport = false
            requestedProviderViewport = nil
            terminalView.onHostProtocolStateChanged = { [weak self] state in
                Task { @MainActor in self?.acceptHostProtocolState(state) }
            }
            terminalView.installInteractionHost(
                shouldBeginProviderNavigation: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return false }
                    return shouldBeginProviderNavigation(gesture, in: terminalView)
                },
                onProviderNavigation: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    handleProviderNavigation(gesture, in: terminalView)
                },
                shouldBeginRemoteScroll: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return false }
                    return shouldBeginRemoteScroll(gesture, in: terminalView)
                },
                onRemoteScroll: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    handleRemoteScroll(gesture, in: terminalView)
                },
                onSelectionLongPress: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    handleSelectionLongPress(gesture, in: terminalView)
                },
                onSelectionPan: { [weak terminalView] gesture in
                    terminalView?.handleHostSelectionPan(gesture)
                },
                shouldBeginDirectPointer: { [weak self] in self?.pointerActive == true },
                shouldBeginIndirectPointer: { [weak self] in
                    self?.protocolState?.mouseTracking.reportsMouse == true
                },
                onDirectPointer: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    handlePointerPan(gesture, in: terminalView)
                },
                onDirectTap: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    handleDirectTap(gesture, in: terminalView)
                },
                onIndirectPointer: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    handleIndirectPointer(gesture, in: terminalView)
                }
            )
            acceptHostProtocolState(terminalView.hostProtocolState)
            replayOutboundGate.beginReplay()
            renderTask = Task { @MainActor [weak self] in
                await self?.renderTranscript()
            }
            if let persistentInteraction {
                persistentStateTask = Task { @MainActor [weak self] in
                    for await state in persistentInteraction.states {
                        guard !Task.isCancelled else { return }
                        self?.acceptPersistentState(state)
                    }
                }
                discoverProviderQuickActions(using: persistentInteraction)
                // State streams carry provider updates but are not required to replay an
                // initial value. Resolve once when attaching so the view starts from the
                // exact provider-owned state. Required-component failures are handled by
                // attachment lifecycle/rebuild rather than by this presentation adapter.
                stateResolutionTask = Task { @MainActor [weak self] in
                    defer { self?.stateResolutionTask = nil }
                    guard let state = try? await persistentInteraction.resolveState(),
                          !Task.isCancelled
                    else { return }
                    self?.acceptPersistentState(state)
                }
            }
        }

        func detach() {
            renderTask?.cancel()
            persistentStateTask?.cancel()
            historyCaptureTask?.cancel()
            stateResolutionTask?.cancel()
            providerScrollTask?.cancel()
            quickActionDiscoveryTask?.cancel()
            quickActionExecutionTask?.cancel()
            noticeTask?.cancel()
            viewportTask?.cancel()
            renderTask = nil
            persistentStateTask = nil
            historyCaptureTask = nil
            historyCaptureID = nil
            historyCaptureToken = nil
            stateResolutionTask = nil
            providerScrollTask = nil
            quickActionDiscoveryTask = nil
            quickActionExecutionTask = nil
            noticeTask = nil
            viewportTask = nil
            providerPendingRows = 0
            providerActionQueue.removeAll()
            interactionController.invalidate()
            terminalView?.onHostProtocolStateChanged = nil
            terminalView?.dismissReview(restoringTerminalFocus: false)
            terminalView?.removeInteractionHost()
            terminalView = nil
            pointerActive = false
            pointerAvailable = false
            isReviewActive = false
            providerQuickActionGroup = nil
            performingProviderQuickActionID = nil
            persistentTarget = nil
            persistentWorkingDirectory = nil
            onPersistentWorkingDirectoryChanged(nil)
            rendererReadyForRemoteViewport = false
            requestedProviderViewport = .hidden
            viewportRequestID = nil
            lastViewportSize = nil
            if persistentAttachment?.viewportAuthority == .remoteProvider {
                Task { [persistentAttachment] in
                    try? await persistentAttachment?.updateViewport(.hidden)
                }
            }
            guard let attachmentID else { return }
            self.attachmentID = nil
            Task { [transcript] in
                await transcript.detach(attachmentID)
            }
        }

        private func renderTranscript() async {
            var isReplayGateActive = true
            defer {
                if isReplayGateActive {
                    replayOutboundGate.finishReplay()
                }
            }

            let replayPolicy: TerminalTranscriptReplayPolicy =
                persistentAttachment?.viewportAuthority == .remoteProvider
                    ? .authoritativeRemote
                    : .buffered
            let attachment = await transcript.attach(replayPolicy: replayPolicy)
            attachmentID = attachment.id
            guard !Task.isCancelled else {
                await transcript.detach(attachment.id)
                attachmentID = nil
                return
            }
            for await event in attachment.events {
                guard !Task.isCancelled else { break }
                guard let terminalView else { continue }
                switch event {
                case let .replayStarted(requiresReset):
                    if replayPolicy == .authoritativeRemote {
                        rendererReadyForRemoteViewport = false
                    }
                    if requiresReset {
                        terminalView.getTerminal().resetToInitialState()
                    }
                case let .replayBytes(bytes):
                    replayOutboundGate.withFeed(.replay) {
                        terminalView.feedFollowingLiveOutput(byteArray: bytes[...])
                    }
                case let .liveBytes(bytes):
                    replayOutboundGate.withFeed(.live(generation: terminalGeneration)) {
                        terminalView.feedFollowingLiveOutput(byteArray: bytes[...])
                    }
                case let .replayFinished(viewport):
                    replayOutboundGate.finishReplay()
                    isReplayGateActive = false
                    // Historical replay suppresses delegate callbacks; publish the
                    // terminal's final parsed OSC 7 value once replay is complete.
                    if let directory = terminalView.getTerminal().hostCurrentDirectory {
                        hostCurrentDirectoryUpdate(source: terminalView, directory: directory)
                    }
                    terminalView.scroll(toPosition: viewport.followsLiveOutput ? 1 : viewport.scrollPosition)
                    if replayPolicy == .authoritativeRemote {
                        rendererReadyForRemoteViewport = true
                        scheduleProviderViewport(force: true)
                    }
                case .generationBoundary:
                    replayOutboundGate.withFeed(.generationBoundary) {
                        terminalView.feedFollowingLiveOutput(
                            byteArray: TerminalTranscript.generationBoundaryBytes[...]
                        )
                    }
                }
            }
            await transcript.detach(attachment.id)
            if attachmentID == attachment.id {
                attachmentID = nil
            }
        }

        func setTerminalFocused(_ isFocused: Bool) {
            guard isTerminalFocused != isFocused else { return }
            isTerminalFocused = isFocused
            // Local selection temporarily owns UIKit first responder while the terminal
            // screen remains logically focused. Do not emit an artificial CSI focus-out
            // event to vim/tmux/Claude Code merely because the user selected text.
            let hasTerminalScreenFocus = isFocused || isReviewActive
            if let report = focusState.setFirstResponder(hasTerminalScreenFocus) {
                emitHostProtocolOutput {
                    terminalView?.setHostFocus(report)
                }
            }
        }

        func setApplicationActive(_ isActive: Bool) {
            applicationActive = isActive
            if !isActive {
                interactionController.deactivatePointer()
                syncInteractionPresentation()
            }
            if let report = focusState.setApplicationActive(isActive) {
                emitHostProtocolOutput {
                    terminalView?.setHostFocus(report)
                }
            }
            scheduleProviderViewport(force: isActive)
        }

        /// SwiftTerm uses this delegate for user input and live protocol responses. Replay and
        /// generation-boundary responses are denied, while sticky Ctrl applies only to actual
        /// user input outside a terminal feed.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard replayOutboundGate.allowsTerminalDelegateOutput else { return }
            let isUserInput = replayOutboundGate.currentFeedProvenance == .outsideFeed
                && !isHostProtocolEmission
            if isUserInput {
                dismissHistoryReviewIfNeeded()
                source.clearSelection()
            }
            let bytes = [UInt8](data)
            if isUserInput,
               !isTypedPaste,
               bytes == TerminalKey.esc.bytes,
               interactionController.handleEscape() == .consumedLocally {
                syncInteractionPresentation()
                return
            }

            let encoded: [UInt8]
            if isUserInput, !isTypedPaste {
                inputEpoch &+= 1
                let result = TerminalKeyEncoder.encode(bytes, ctrlActive: ctrlActive)
                encoded = result.bytes
                ctrlActive = result.ctrlStillActive
            } else {
                encoded = bytes
            }
            if isUserInput {
                enqueueUserInput(encoded)
            } else {
                session.enqueue(encoded)
            }
        }

        private func emitHostProtocolOutput(_ body: () -> Void) {
            let previous = isHostProtocolEmission
            isHostProtocolEmission = true
            body()
            isHostProtocolEmission = previous
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let size = TermSize(cols: newCols, rows: newRows)
            lastViewportSize = size
            if persistentAttachment?.viewportAuthority == .remoteProvider {
                scheduleProviderViewport()
            } else {
                Task { try? await session.resize(cols: newCols, rows: newRows) }
            }
            acceptHostProtocolState(source.hostProtocolState)
        }

        private func scheduleProviderViewport(force: Bool = false) {
            guard let persistentAttachment,
                  persistentAttachment.viewportAuthority == .remoteProvider
            else { return }

            let state: PersistentTerminalViewportState
            if applicationActive,
               rendererReadyForRemoteViewport,
               terminalView != nil,
               let lastViewportSize {
                state = .visible(lastViewportSize)
            } else {
                state = .hidden
            }
            guard force || requestedProviderViewport != state else { return }
            requestedProviderViewport = state
            viewportTask?.cancel()
            let requestID = UUID()
            viewportRequestID = requestID
            viewportTask = Task { [weak self, persistentAttachment] in
                if case .visible = state {
                    try? await Task.sleep(for: .milliseconds(60))
                }
                guard !Task.isCancelled else { return }
                var didSucceed = false
                do {
                    try await persistentAttachment.updateViewport(state)
                    didSucceed = true
                } catch is CancellationError {
                    return
                } catch {
                    terminalInteractionLogger.error(
                        "Persistent viewport update failed; type=\(String(reflecting: type(of: error)), privacy: .public)"
                    )
                }
                guard self?.viewportRequestID == requestID else { return }
                self?.viewportTask = nil
                if !didSucceed || Task.isCancelled {
                    self?.requestedProviderViewport = nil
                }
            }
        }

        func handleKey(_ key: TerminalKey) {
            dismissHistoryReviewIfNeeded()
            terminalView?.clearSelection()
            if key.isSticky {
                ctrlActive.toggle()
                return
            }
            if key == .esc, interactionController.handleEscape() == .consumedLocally {
                syncInteractionPresentation()
                return
            }
            inputEpoch &+= 1
            let (encoded, stillActive) = TerminalKeyEncoder.encode(key.bytes, ctrlActive: ctrlActive)
            ctrlActive = stillActive
            enqueueUserInput(encoded)
        }

        private func enqueueUserInput(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            // Provider modes such as tmux copy mode consume their own keyboard input on
            // the attached PTY. Typed bytes must never be coupled to Control Mode.
            session.enqueue(bytes)
        }

        func handlePaste(_ text: String, source: TerminalPasteSource = .keybar) {
            dismissHistoryReviewIfNeeded()
            guard let terminalView else { return }
            terminalView.clearSelection()
            if source != .programmatic {
                inputEpoch &+= 1
            }
            switch typedInputPlanner.paste(text, source: source) {
            case let .paste(value):
                isTypedPaste = true
                terminalView.paste(text: value)
                isTypedPaste = false
            }
        }

        func toggleKeyboard() {
            guard let terminalView else { return }
            if terminalView.isFirstResponder {
                _ = terminalView.resignFirstResponder()
            } else {
                _ = terminalView.becomeFirstResponder()
            }
        }

        func togglePointer() {
            if interactionController.mode == .pointer {
                interactionController.deactivatePointer()
            } else {
                _ = interactionController.activatePointer()
            }
            syncInteractionPresentation()
        }

        private func acceptHostProtocolState(_ state: TerminalHostProtocolState) {
            protocolState = TerminalProtocolState(state)
            updateInteractionContext()
        }

        private func acceptPersistentState(_ state: PersistentTerminalInteractionState) {
            persistentState = state
            persistentTarget = state.target
            onPersistentWorkspaceChanged(state.target.workspaceID, state.workspaceName)
            persistentWorkingDirectory = state.workingDirectory
            onPersistentWorkingDirectoryChanged(
                state.freshness == .live ? state.workingDirectory : nil
            )
            let providerPath = state.freshness == .live
                ? state.workingDirectory.flatMap(TerminalWorkingDirectoryPath.providerPath)
                : nil
            onTerminalWorkingDirectoryChanged(.provider, terminalGeneration, providerPath)
            refreshProviderQuickActions(for: state)
            updateInteractionContext()
            drainProviderActionQueue()
        }

        private func refreshProviderQuickActions(
            for state: PersistentTerminalInteractionState
        ) {
            quickActionDiscoveryTask?.cancel()
            guard let persistentInteraction else {
                providerQuickActionGroup = nil
                return
            }
            quickActionDiscoveryTask = Task { @MainActor [weak self] in
                let group = await persistentInteraction.quickActionGroup
                guard !Task.isCancelled,
                      let self,
                      persistentState?.target == state.target,
                      persistentState?.attachmentGeneration == state.attachmentGeneration,
                      persistentState?.revision == state.revision
                else { return }
                providerQuickActionGroup = group
                quickActionDiscoveryTask = nil
            }
        }

        private func discoverProviderQuickActions(
            using persistentInteraction: any PersistentTerminalInteractionFacet
        ) {
            quickActionDiscoveryTask?.cancel()
            quickActionDiscoveryTask = Task { @MainActor [weak self] in
                let group = await persistentInteraction.quickActionGroup
                guard !Task.isCancelled, let self else { return }
                providerQuickActionGroup = group
                quickActionDiscoveryTask = nil
            }
        }

        func performQuickAction(
            _ actionID: String,
            argument: String?,
            confirmsDestructiveAction: Bool = false
        ) {
            let descriptor = providerQuickActionGroup?.actions.first {
                $0.id == actionID
            }
            let successNoticeKey = descriptor?.textInput == nil ? nil : "已保存"
            executeQuickAction(
                actionID,
                argument: argument,
                confirmsDestructiveAction: confirmsDestructiveAction,
                successNoticeKey: successNoticeKey,
                completionEffect: descriptor?.completionEffect
            )
        }

        private func executeQuickAction(
            _ actionID: String,
            argument: String?,
            confirmsDestructiveAction: Bool = false,
            successNoticeKey: String?,
            completionEffect: PersistentTerminalActionEffect? = nil
        ) {
            guard providerQuickActionGroup?.actions.contains(where: { $0.id == actionID }) == true,
                  persistentInteraction != nil,
                  persistentState != nil
            else { return }
            let intent = TerminalProviderActionIntent(
                actionID: actionID,
                argument: argument,
                confirmsDestructiveAction: confirmsDestructiveAction,
                successNoticeKey: successNoticeKey,
                unavailableNoticeKey: nil,
                completionEffect: completionEffect,
                repeatCount: 1
            )
            guard providerActionQueue.enqueue(intent) else {
                terminalInteractionLogger.error(
                    "Provider action queue is full: action=\(actionID, privacy: .public)"
                )
                return
            }
            terminalInteractionLogger.info(
                "Provider action queued: action=\(actionID, privacy: .public), pending=\(self.providerActionQueue.count, privacy: .public)"
            )
            drainProviderActionQueue()
        }

        /// Buttons and swipe gestures share one ordered lane. A request is built only after
        /// its intent reaches the head, and execution-time resolution tells the provider to
        /// use the attachment's current Pane/Window instead of the state seen by an older tap.
        private func drainProviderActionQueue() {
            guard quickActionExecutionTask == nil,
                  let persistentInteraction,
                  let state = persistentState,
                  let intent = providerActionQueue.dequeue()
            else { return }
            let request = PersistentTerminalQuickActionRequest(
                actionID: intent.actionID,
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                expectedStateRevision: state.revision,
                argument: intent.argument,
                repeatCount: intent.repeatCount,
                confirmsDestructiveAction: intent.confirmsDestructiveAction,
                resolution: .currentAtExecution
            )
            performingProviderQuickActionID = intent.actionID
            quickActionExecutionTask = Task { @MainActor [weak self] in
                terminalInteractionLogger.info(
                    "Provider action started: action=\(intent.actionID, privacy: .public), observedRevision=\(state.revision, privacy: .public), repeat=\(intent.repeatCount, privacy: .public)"
                )
                do {
                    let outcome = try await persistentInteraction.performQuickAction(request)
                    switch outcome {
                    case .performed:
                        terminalInteractionLogger.info(
                            "Provider action completed: action=\(intent.actionID, privacy: .public), repeat=\(intent.repeatCount, privacy: .public)"
                        )
                        if intent.completionEffect == .workspaceRenamed,
                           let name = intent.argument?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !name.isEmpty {
                            self?.onPersistentWorkspaceRenamed(name)
                        }
                        if let successNoticeKey = intent.successNoticeKey {
                            self?.showNotice(L(successNoticeKey), style: .success)
                        }
                    case .unavailable:
                        if let noticeKey = intent.unavailableNoticeKey {
                            self?.showNotice(L(noticeKey), style: .warning)
                        }
                    case .workspaceClosed:
                        terminalInteractionLogger.info(
                            "Provider workspace closed by action: action=\(intent.actionID, privacy: .public)"
                        )
                        self?.providerActionQueue.removeAll()
                        self?.onPersistentWorkspaceClosed()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    terminalInteractionLogger.error(
                        "Provider action failed: action=\(intent.actionID, privacy: .public), error=\(String(reflecting: error), privacy: .public)"
                    )
                    self?.providerActionQueue.removeAll()
                    self?.showNotice(L("持久终端操作失败，请重试"), style: .error)
                }
                self?.performingProviderQuickActionID = nil
                self?.quickActionExecutionTask = nil
                self?.drainProviderActionQueue()
            }
        }

        private func updateInteractionContext() {
            guard let protocolState else { return }
            let persistentRoute: TerminalPersistentRouteState? = if let persistentState {
                TerminalPersistentRouteState(
                    persistentState,
                    historyOwnership: persistentInteraction?.historyOwnership ?? .local
                )
            } else if persistentInteraction != nil {
                .init(
                    revision: 0,
                    freshness: .stale,
                    isAlternateBuffer: protocolState.isAlternateBuffer,
                    modeCapability: .none,
                    historyOwnership: persistentInteraction?.historyOwnership ?? .local,
                    historyAvailable: false
                )
            } else {
                nil
            }
            interactionController.update(.init(
                mode: interactionController.mode,
                protocolState: protocolState,
                terminalGeneration: terminalGeneration,
                attachmentGeneration: persistentState?.attachmentGeneration ?? terminalGeneration,
                persistent: persistentRoute,
                localHistoryAvailable: terminalView?.canScroll == true
            ))
            if let historyCaptureToken,
               !interactionController.canPublishHistory(capturedWith: historyCaptureToken) {
                cancelHistoryCapture()
            }
            syncInteractionPresentation()
        }

        private func syncInteractionPresentation() {
            pointerAvailable = interactionController.pointerAvailable
            pointerActive = interactionController.mode == .pointer
            isReviewActive = interactionController.review != nil
            if !isReviewActive {
                terminalView?.dismissReview()
            }
        }

        private func shouldBeginProviderNavigation(
            _ gesture: UIPanGestureRecognizer,
            in terminalView: KeybarTerminalView
        ) -> Bool {
            guard interactionController.mode == .live,
                  persistentState != nil,
                  let group = providerQuickActionGroup
            else { return false }
            let velocity = gesture.velocity(in: terminalView)
            guard TerminalHorizontalSwipeClassifier().canBegin(
                velocityX: Double(velocity.x),
                velocityY: Double(velocity.y)
            ) else { return false }
            let direction: PersistentTerminalHorizontalSwipeDirection =
                velocity.x < 0 ? .left : .right
            guard let binding = group.swipeAction(for: direction) else { return false }
            return group.actions.contains { $0.id == binding.actionID }
        }

        private func handleProviderNavigation(
            _ gesture: UIPanGestureRecognizer,
            in terminalView: KeybarTerminalView
        ) {
            guard gesture.state == .ended,
                  let group = providerQuickActionGroup
            else { return }
            let translation = gesture.translation(in: terminalView)
            let velocity = gesture.velocity(in: terminalView)
            guard let direction = TerminalHorizontalSwipeClassifier().completedDirection(
                translationX: Double(translation.x),
                translationY: Double(translation.y),
                velocityX: Double(velocity.x),
                velocityY: Double(velocity.y)
            ) else { return }
            let providerDirection: PersistentTerminalHorizontalSwipeDirection = switch direction {
            case .left: .left
            case .right: .right
            }
            guard let binding = group.swipeAction(for: providerDirection) else { return }

            ConnHapticFeedback.performHighImpact()
            enqueueProviderNavigation(binding)
        }

        private func enqueueProviderNavigation(
            _ binding: PersistentTerminalSwipeActionDescriptor
        ) {
            let intent = TerminalProviderActionIntent(
                actionID: binding.actionID,
                argument: nil,
                confirmsDestructiveAction: false,
                successNoticeKey: binding.successNoticeKey,
                unavailableNoticeKey: binding.unavailableNoticeKey,
                completionEffect: nil,
                repeatCount: 1
            )
            guard providerActionQueue.enqueue(intent, coalescesRepeatCount: true) else {
                terminalInteractionLogger.error(
                    "Provider action queue is full: action=\(binding.actionID, privacy: .public)"
                )
                return
            }
            terminalInteractionLogger.info(
                "Provider navigation queued: action=\(binding.actionID, privacy: .public), pending=\(self.providerActionQueue.count, privacy: .public)"
            )
            drainProviderActionQueue()
        }

        private func dismissHistoryReviewIfNeeded() {
            // A provider-history request may still be in flight when the user resumes
            // interacting with the live terminal. Cancel it even before a review exists,
            // otherwise its late completion can cover the renderer after input has resumed.
            cancelHistoryCapture()
            guard isReviewActive else { return }
            interactionController.dismissReview()
            syncInteractionPresentation()
        }

        private func shouldBeginRemoteScroll(
            _ gesture: UIPanGestureRecognizer,
            in terminalView: KeybarTerminalView
        ) -> Bool {
            acceptHostProtocolState(terminalView.hostProtocolState)
            let pointerWheel = interactionController.mode == .pointer
            guard !pointerWheel || gesture.numberOfTouches >= 2 else { return false }
            let action = interactionController.beginScroll(
                modeOverride: pointerWheel ? .live : nil
            )
            guard action.isRemoteScroll else {
                interactionController.endScroll()
                return false
            }
            scrollAccumulator = TerminalScrollAccumulator(rowHeight: terminalView.estimatedRowHeight)
            scrollHit = terminalView.interactionHit(at: gesture.location(in: terminalView))
            return true
        }

        private func handleRemoteScroll(
            _ gesture: UIPanGestureRecognizer,
            in terminalView: KeybarTerminalView
        ) {
            switch gesture.state {
            case .changed:
                let delta = gesture.translation(in: terminalView).y
                gesture.setTranslation(.zero, in: terminalView)
                let rows = scrollAccumulator.consume(
                    deltaPixels: Double(delta),
                    source: .touch,
                    generation: terminalGeneration
                )
                guard rows != 0 else { return }
                executeScroll(interactionController.continueScroll(), rows: rows, in: terminalView)
            case .ended, .cancelled, .failed:
                interactionController.endScroll()
                scrollAccumulator.reset()
            default:
                break
            }
        }

        private func executeScroll(
            _ action: TerminalScrollAction,
            rows: Int,
            in terminalView: KeybarTerminalView
        ) {
            guard rows != 0 else { return }
            let direction: TerminalCursorDirection = rows > 0 ? .up : .down
            switch action.transport {
            case .remoteMouse:
                terminalView.sendHostWheel(
                    direction: rows > 0 ? .up : .down,
                    count: abs(rows),
                    at: scrollHit,
                    modifiers: []
                )
            case .terminalCursorKeys:
                terminalView.sendHostCursorKey(direction, count: abs(rows))
            case .terminalScrollKeys:
                terminalView.sendHostCursorKey(
                    direction,
                    count: abs(rows),
                    modifiers: .control
                )
            case .providerControl:
                enqueueProviderScroll(rows)
            case .resolvePersistentState:
                resolvePersistentState(replayingRows: rows)
            case .none:
                break
            }
        }

        private func resolvePersistentState(replayingRows rows: Int) {
            guard stateResolutionTask == nil, let persistentInteraction else { return }
            let generation = terminalGeneration
            stateResolutionTask = Task { @MainActor [weak self] in
                defer { self?.stateResolutionTask = nil }
                do {
                    let state = try await persistentInteraction.resolveState()
                    guard let self, terminalGeneration == generation,
                          let terminalView else { return }
                    acceptPersistentState(state)
                    let action = interactionController.beginScroll(modeOverride: .live)
                    executeScroll(action, rows: rows, in: terminalView)
                } catch {
                    self?.showNotice(L("远程终端状态暂不可用，请重试"), style: .warning)
                }
            }
        }

        private func enqueueProviderScroll(_ rows: Int) {
            if providerPendingRows != 0, (providerPendingRows > 0) != (rows > 0) {
                providerPendingRows = 0
            }
            providerPendingRows = min(max(providerPendingRows + rows, -64), 64)
            drainProviderScroll()
        }

        private func drainProviderScroll() {
            guard providerScrollTask == nil,
                  providerPendingRows != 0,
                  let persistentInteraction,
                  let state = persistentState
            else { return }
            let rows = providerPendingRows
            providerPendingRows = 0
            guard let request = try? PersistentTerminalModeScrollRequest(
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                direction: rows > 0 ? .up : .down,
                rows: abs(rows)
            ) else { return }
            terminalInteractionLogger.info(
                "Provider scroll started: mode=\(String(describing: state.modeCapability), privacy: .public), alternate=\(String(describing: state.isAlternateBuffer), privacy: .public), history=\(state.historyAvailable, privacy: .public), rows=\(rows, privacy: .public)"
            )
            providerScrollTask = Task { @MainActor [weak self] in
                do {
                    try await persistentInteraction.scrollProviderMode(request)
                    // The first provider command has now entered copy mode. Motion that
                    // accumulated while it was in flight must use the attached terminal
                    // channel; issuing more Control Mode commands for one finger gesture
                    // overloads the management lane and can turn a harmless scroll into a
                    // terminal reconnect.
                    if let pendingRows = self?.providerPendingRows,
                       pendingRows != 0,
                       let terminalView = self?.terminalView {
                        self?.providerPendingRows = 0
                        terminalView.sendHostCursorKey(
                            pendingRows > 0 ? .up : .down,
                            count: abs(pendingRows),
                            modifiers: .control
                        )
                    }
                } catch {
                    terminalInteractionLogger.error(
                        "Provider scroll failed: error=\(String(reflecting: error), privacy: .public)"
                    )
                    self?.providerPendingRows = 0
                    self?.showNotice(L("当前远程模式不支持滚动"), style: .warning)
                }
                self?.providerScrollTask = nil
            }
        }

        private func handleSelectionLongPress(
            _ gesture: UILongPressGestureRecognizer,
            in terminalView: KeybarTerminalView
        ) {
            let point = gesture.location(in: terminalView)
            switch gesture.state {
            case .began:
                dismissHistoryReviewIfNeeded()
                interactionController.deactivatePointer()
                syncInteractionPresentation()
                terminalView.clearSelection()
                terminalView.beginHostSelection(at: point, granularity: .word)
            case .changed:
                terminalView.extendHostSelection(to: point)
            case .ended:
                terminalView.finishHostSelection(showMenu: true)
            case .cancelled, .failed:
                terminalView.clearSelection()
            default:
                break
            }
        }

        private func capturePersistentHistory(routeToken: TerminalRouteToken) {
            guard historyCaptureTask == nil,
                  interactionController.canPublishHistory(capturedWith: routeToken),
                  let persistentInteraction,
                  let state = persistentState,
                  let request = try? PersistentTerminalHistoryRequest(
                      target: state.target,
                      attachmentGeneration: state.attachmentGeneration,
                      maxLines: 20000,
                      maxBytes: 1_048_576
                  )
            else { return }
            let generation = terminalGeneration
            let captureID = UUID()
            historyCaptureID = captureID
            historyCaptureToken = routeToken
            historyCaptureTask = Task { @MainActor [weak self] in
                defer {
                    if self?.historyCaptureID == captureID {
                        self?.historyCaptureTask = nil
                        self?.historyCaptureID = nil
                        self?.historyCaptureToken = nil
                    }
                }
                do {
                    let captured = try await persistentInteraction.captureHistory(request)
                    guard !Task.isCancelled,
                          let self,
                          historyCaptureID == captureID,
                          interactionController.canPublishHistory(capturedWith: routeToken),
                          terminalGeneration == generation,
                          persistentState?.target == captured.target,
                          persistentState?.attachmentGeneration == captured.attachmentGeneration
                    else { return }
                    let snapshot = TerminalReviewSnapshot(
                        persistent: captured,
                        terminalGeneration: generation
                    )
                    presentReview(snapshot, selectionOffset: nil)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.showNotice(L("远程历史记录暂不可用，请重试"), style: .warning)
                }
            }
        }

        private func cancelHistoryCapture() {
            historyCaptureTask?.cancel()
            historyCaptureTask = nil
            historyCaptureID = nil
            historyCaptureToken = nil
        }

        private func presentReview(
            _ snapshot: TerminalReviewSnapshot,
            selectionOffset: Int?
        ) {
            if let selectionOffset {
                interactionController.beginSelection(
                    snapshot,
                    utf16Offset: selectionOffset,
                    granularity: .character
                )
            } else {
                interactionController.presentReview(snapshot)
            }
            // Publish review ownership before UIKit transfers first responder. This keeps
            // the SwiftUI keybar mounted throughout the responder handoff.
            syncInteractionPresentation()
            terminalView?.presentReview(
                snapshot,
                selectingUTF16Offset: selectionOffset,
                onClose: { [weak self] in
                    self?.interactionController.dismissReview()
                    self?.syncInteractionPresentation()
                }
            )
        }

        private func handlePointerPan(
            _ gesture: UIPanGestureRecognizer,
            in terminalView: KeybarTerminalView
        ) {
            let hit = terminalView.interactionHit(at: gesture.location(in: terminalView))
            switch gesture.state {
            case .began:
                terminalView.sendHostPointer(.press(button: 0), at: hit, modifiers: [])
            case .changed:
                terminalView.sendHostPointer(.motion(button: 0), at: hit, modifiers: [])
            case .ended, .cancelled:
                terminalView.sendHostPointer(.release(button: 0), at: hit, modifiers: [])
            default:
                break
            }
        }

        private func handleDirectTap(
            _ gesture: UITapGestureRecognizer,
            in terminalView: KeybarTerminalView
        ) {
            guard gesture.state == .ended else { return }
            if terminalView.hasActiveSelection {
                terminalView.clearSelection()
                _ = terminalView.becomeFirstResponder()
                return
            }
            _ = terminalView.becomeFirstResponder()
            acceptHostProtocolState(terminalView.hostProtocolState)
            if interactionController.directTapAction() == .remotePrimaryClick {
                let hit = terminalView.interactionHit(at: gesture.location(in: terminalView))
                terminalView.sendHostPointer(.press(button: 0), at: hit, modifiers: [])
                terminalView.sendHostPointer(.release(button: 0), at: hit, modifiers: [])
            }
        }

        private func handleIndirectPointer(
            _ gesture: UIGestureRecognizer,
            in terminalView: KeybarTerminalView
        ) {
            guard protocolState?.mouseTracking.reportsMouse == true else { return }
            let hit = terminalView.interactionHit(at: gesture.location(in: terminalView))
            if let pan = gesture as? UIPanGestureRecognizer {
                switch pan.state {
                case .began:
                    terminalView.sendHostPointer(.press(button: 0), at: hit, modifiers: [])
                case .changed:
                    terminalView.sendHostPointer(.motion(button: 0), at: hit, modifiers: [])
                case .ended, .cancelled:
                    terminalView.sendHostPointer(.release(button: 0), at: hit, modifiers: [])
                default:
                    break
                }
            } else if gesture.state == .ended {
                terminalView.sendHostPointer(.press(button: 0), at: hit, modifiers: [])
                terminalView.sendHostPointer(.release(button: 0), at: hit, modifiers: [])
            }
        }

        private var clipboardIdentity: TerminalClipboardSessionIdentity {
            .init(
                terminalGeneration: terminalGeneration,
                attachmentGeneration: persistentState?.attachmentGeneration ?? terminalGeneration
            )
        }

        private func showNotice(_ text: String, style: ConnToastStyle) {
            noticeTask?.cancel()
            // A new value identity matters even when two consecutive swipes produce
            // the same localized message; String-only state suppresses the second
            // SwiftUI onChange event.
            interactionNotice = TerminalInteractionNotice(text: text, style: style)
            noticeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.interactionNotice = nil
            }
        }

        func setTerminalTitle(source _: TerminalView, title _: String) {}
        func hostCurrentDirectoryUpdate(source _: TerminalView, directory: String?) {
            guard replayOutboundGate.allowsTerminalDelegateOutput else { return }
            switch replayOutboundGate.currentFeedProvenance {
            case .outsideFeed:
                break
            case let .live(generation) where generation == terminalGeneration:
                break
            case .live, .replay, .generationBoundary:
                return
            }
            guard let path = TerminalWorkingDirectoryPath.osc7Path(from: directory) else {
                return
            }
            onTerminalWorkingDirectoryChanged(.osc7, terminalGeneration, path)
        }
        func scrolled(source: TerminalView, position: Double) {
            updateInteractionContext()
            let state = TerminalViewportState(
                followsLiveOutput: !source.canScroll || position >= 1,
                scrollPosition: position
            )
            Task { [transcript] in await transcript.updateViewport(state) }
        }

        func requestOpenLink(source _: TerminalView, link _: String, params _: [String: String]) {}
        func bell(source _: TerminalView) {}
        func clipboardCopy(source _: TerminalView, content: Data) {
            guard replayOutboundGate.allowsHostSideEffects,
                  clipboardPolicy.acceptsWrite(
                      content,
                      provenance: replayOutboundGate.currentFeedProvenance,
                      identity: clipboardIdentity
                  )
            else { return }
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            } else {
                UIPasteboard.general.setData(content, forPasteboardType: "public.data")
            }
            showNotice(L("已复制"), style: .success)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            _ = source
            guard clipboardPolicy.acceptsRead(
                provenance: replayOutboundGate.currentFeedProvenance,
                identity: clipboardIdentity
            ) else { return nil }
            return nil
        }

        func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
    }

    private extension TerminalProtocolState {
        init(_ state: TerminalHostProtocolState) {
            let mouseTracking: TerminalMouseTracking = switch state.mouseMode {
            case .off: .off
            case .x10: .pressOnly
            case .vt200: .pressAndRelease
            case .buttonEventTracking: .buttonMotion
            case .anyEvent: .allMotion
            }
            self.init(
                revision: state.revision,
                isAlternateBuffer: state.isAlternateBuffer,
                mouseTracking: mouseTracking,
                alternateScrollEnabled: state.alternateScrollEnabled,
                bracketedPasteEnabled: state.bracketedPasteEnabled,
                focusReportingEnabled: state.focusReportingEnabled,
                synchronizedOutputEnabled: state.synchronizedOutputEnabled,
                applicationCursorEnabled: state.applicationCursorEnabled,
                columns: state.columns,
                rows: state.rows
            )
        }
    }

    private extension TerminalPersistentRouteState {
        init(
            _ state: PersistentTerminalInteractionState,
            historyOwnership: PersistentTerminalHistoryOwnership
        ) {
            let mode: TerminalPersistentModeCapability = switch state.modeCapability {
            case .none: .none
            case .scrollable: .scrollable
            case .keyDriven: .keyDriven
            case .unsupported: .unsupported
            }
            let freshness: TerminalPersistentStateFreshness =
                state.freshness == .stale || state.isAlternateBuffer == nil ? .stale : .fresh
            self.init(
                revision: state.revision,
                freshness: freshness,
                isAlternateBuffer: state.isAlternateBuffer ?? false,
                modeCapability: mode,
                historyOwnership: historyOwnership,
                historyAvailable: state.historyAvailable,
                targetID: state.target.targetID
            )
        }
    }

    /// 负责终端绘制、滚动与焦点通知的 `TerminalView` 子类。
    public final class KeybarTerminalView: TerminalView {
        var onFirstResponderChange: ((Bool) -> Void)?
        var onSystemPaste: ((String) -> Void)?
        private var horizontalContentPadding: CGFloat = 0
        fileprivate var configuredCursorShape: TerminalCursorShape?
        fileprivate var configuredCursorBlinking: Bool?
        private var providerNavigationPan: UIPanGestureRecognizer?
        private var remoteScrollPan: UIPanGestureRecognizer?
        private var selectionLongPress: UILongPressGestureRecognizer?
        private var selectionPan: UIPanGestureRecognizer?
        private var directPointerPan: UIPanGestureRecognizer?
        private var directTap: UITapGestureRecognizer?
        private var indirectPointerPan: UIPanGestureRecognizer?
        private var indirectPointerTap: UITapGestureRecognizer?
        private var shouldBeginProviderNavigation: ((UIPanGestureRecognizer) -> Bool)?
        private var onProviderNavigation: ((UIPanGestureRecognizer) -> Void)?
        private var shouldBeginRemoteScroll: ((UIPanGestureRecognizer) -> Bool)?
        private var onRemoteScroll: ((UIPanGestureRecognizer) -> Void)?
        private var onSelectionLongPress: ((UILongPressGestureRecognizer) -> Void)?
        private var onSelectionPan: ((UIPanGestureRecognizer) -> Void)?
        private var shouldBeginDirectPointer: (() -> Bool)?
        private var shouldBeginIndirectPointer: (() -> Bool)?
        private var onDirectPointer: ((UIPanGestureRecognizer) -> Void)?
        private var onDirectTap: ((UITapGestureRecognizer) -> Void)?
        private var onIndirectPointer: ((UIGestureRecognizer) -> Void)?
        private var reviewSurface: TerminalReviewTextView?

        var installedProviderNavigationGesture: UIPanGestureRecognizer? {
            providerNavigationPan
        }

        var installedRemoteScrollGesture: UIPanGestureRecognizer? {
            remoteScrollPan
        }

        var installedSelectionGesture: UILongPressGestureRecognizer? {
            selectionLongPress
        }

        var installedSelectionDragGesture: UIPanGestureRecognizer? {
            selectionPan
        }

        var installedDirectPointerGesture: UIPanGestureRecognizer? {
            directPointerPan
        }

        var installedIndirectPointerGesture: UIPanGestureRecognizer? {
            indirectPointerPan
        }

        var estimatedRowHeight: Double {
            Double(max(font.lineHeight, 1))
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            configureViewportInsets()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureViewportInsets()
        }

        func installInteractionHost(
            shouldBeginProviderNavigation: @escaping (UIPanGestureRecognizer) -> Bool,
            onProviderNavigation: @escaping (UIPanGestureRecognizer) -> Void,
            shouldBeginRemoteScroll: @escaping (UIPanGestureRecognizer) -> Bool,
            onRemoteScroll: @escaping (UIPanGestureRecognizer) -> Void,
            onSelectionLongPress: @escaping (UILongPressGestureRecognizer) -> Void,
            onSelectionPan: @escaping (UIPanGestureRecognizer) -> Void,
            shouldBeginDirectPointer: @escaping () -> Bool,
            shouldBeginIndirectPointer: @escaping () -> Bool,
            onDirectPointer: @escaping (UIPanGestureRecognizer) -> Void,
            onDirectTap: @escaping (UITapGestureRecognizer) -> Void,
            onIndirectPointer: @escaping (UIGestureRecognizer) -> Void
        ) {
            self.shouldBeginProviderNavigation = shouldBeginProviderNavigation
            self.onProviderNavigation = onProviderNavigation
            self.shouldBeginRemoteScroll = shouldBeginRemoteScroll
            self.onRemoteScroll = onRemoteScroll
            self.onSelectionLongPress = onSelectionLongPress
            self.onSelectionPan = onSelectionPan
            self.shouldBeginDirectPointer = shouldBeginDirectPointer
            self.shouldBeginIndirectPointer = shouldBeginIndirectPointer
            self.onDirectPointer = onDirectPointer
            self.onDirectTap = onDirectTap
            self.onIndirectPointer = onIndirectPointer
            guard remoteScrollPan == nil else { return }

            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleSelectionLongPress(_:))
            )
            longPress.minimumPressDuration = 0.45
            longPress.cancelsTouchesInView = true
            longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            addGestureRecognizer(longPress)
            selectionLongPress = longPress

            let selectionDrag = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleSelectionPan(_:))
            )
            selectionDrag.maximumNumberOfTouches = 1
            selectionDrag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            selectionDrag.cancelsTouchesInView = true
            addGestureRecognizer(selectionDrag)
            selectionPan = selectionDrag

            let navigationPan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleProviderNavigation(_:))
            )
            navigationPan.maximumNumberOfTouches = 1
            navigationPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            navigationPan.cancelsTouchesInView = true
            navigationPan.require(toFail: longPress)
            navigationPan.require(toFail: selectionDrag)
            addGestureRecognizer(navigationPan)
            providerNavigationPan = navigationPan

            let remotePan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleRemoteScroll(_:))
            )
            remotePan.maximumNumberOfTouches = 2
            remotePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            remotePan.cancelsTouchesInView = true
            remotePan.require(toFail: longPress)
            remotePan.require(toFail: selectionDrag)
            remotePan.require(toFail: navigationPan)
            addGestureRecognizer(remotePan)
            remoteScrollPan = remotePan

            let pointerPan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleDirectPointer(_:))
            )
            pointerPan.maximumNumberOfTouches = 1
            pointerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pointerPan.cancelsTouchesInView = true
            pointerPan.require(toFail: longPress)
            pointerPan.require(toFail: selectionDrag)
            addGestureRecognizer(pointerPan)
            directPointerPan = pointerPan

            let touchTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleDirectTap(_:))
            )
            touchTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            touchTap.require(toFail: pointerPan)
            addGestureRecognizer(touchTap)
            directTap = touchTap

            let hardwarePan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleIndirectPointer(_:))
            )
            hardwarePan.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            ]
            addGestureRecognizer(hardwarePan)
            indirectPointerPan = hardwarePan

            let hardwareTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleIndirectPointer(_:))
            )
            hardwareTap.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            ]
            hardwareTap.require(toFail: hardwarePan)
            addGestureRecognizer(hardwareTap)
            indirectPointerTap = hardwareTap

            // Provider navigation gets first refusal for deliberate horizontal movement;
            // remote mode scrolling then handles vertical movement. Both fail immediately
            // outside their route so UIScrollView's native history pan can proceed.
            panGestureRecognizer.require(toFail: navigationPan)
            panGestureRecognizer.require(toFail: remotePan)
            panGestureRecognizer.require(toFail: longPress)
            panGestureRecognizer.require(toFail: selectionDrag)
        }

        func removeInteractionHost() {
            [
                providerNavigationPan,
                remoteScrollPan,
                selectionLongPress,
                selectionPan,
                directPointerPan,
                directTap,
                indirectPointerPan,
                indirectPointerTap
            ]
            .compactMap { $0 }
            .forEach(removeGestureRecognizer)
            providerNavigationPan = nil
            remoteScrollPan = nil
            selectionLongPress = nil
            selectionPan = nil
            directPointerPan = nil
            directTap = nil
            indirectPointerPan = nil
            indirectPointerTap = nil
            shouldBeginProviderNavigation = nil
            onProviderNavigation = nil
            shouldBeginRemoteScroll = nil
            onRemoteScroll = nil
            onSelectionLongPress = nil
            onSelectionPan = nil
            shouldBeginDirectPointer = nil
            shouldBeginIndirectPointer = nil
            onDirectPointer = nil
            onDirectTap = nil
            onIndirectPointer = nil
        }

        func presentReview(
            _ snapshot: TerminalReviewSnapshot,
            selectingUTF16Offset: Int?,
            onClose: @escaping () -> Void
        ) {
            let review = reviewSurface ?? TerminalReviewTextView(frame: bounds)
            reviewSurface = review
            review.frame = bounds
            review.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            review.onClose = onClose
            if review.superview == nil {
                addSubview(review)
            }
            bringSubviewToFront(review)
            review.display(
                snapshot,
                selectingUTF16Offset: selectingUTF16Offset,
                font: font,
                foregroundColor: nativeForegroundColor,
                backgroundColor: nativeBackgroundColor
            )
        }

        func dismissReview(restoringTerminalFocus: Bool = true) {
            if restoringTerminalFocus, reviewSurface?.textView.isFirstResponder == true {
                _ = becomeFirstResponder()
            }
            reviewSurface?.removeFromSuperview()
            reviewSurface = nil
        }

        override public func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if let providerNavigationPan, gestureRecognizer === providerNavigationPan {
                guard reviewSurface == nil, !hasActiveSelection else { return false }
                return shouldBeginProviderNavigation?(providerNavigationPan) == true
            }
            if let remoteScrollPan, gestureRecognizer === remoteScrollPan {
                guard !hasActiveSelection else { return false }
                return shouldBeginRemoteScroll?(remoteScrollPan) == true
            }
            if gestureRecognizer === selectionPan {
                return hasActiveSelection
            }
            if gestureRecognizer === selectionLongPress {
                return reviewSurface == nil && !hasActiveSelection
            }
            if gestureRecognizer === directPointerPan {
                guard !hasActiveSelection else { return false }
                return shouldBeginDirectPointer?() == true
            }
            if gestureRecognizer === indirectPointerPan
                || gestureRecognizer === indirectPointerTap {
                guard !hasActiveSelection else { return false }
                return shouldBeginIndirectPointer?() == true
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        @objc override public func paste(_: Any?) {
            guard let text = UIPasteboard.general.string else { return }
            onSystemPaste?(text)
        }

        @objc private func handleProviderNavigation(_ gesture: UIPanGestureRecognizer) {
            onProviderNavigation?(gesture)
        }

        @objc private func handleRemoteScroll(_ gesture: UIPanGestureRecognizer) {
            onRemoteScroll?(gesture)
        }

        @objc private func handleSelectionLongPress(_ gesture: UILongPressGestureRecognizer) {
            onSelectionLongPress?(gesture)
        }

        @objc private func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
            onSelectionPan?(gesture)
        }

        @objc private func handleDirectPointer(_ gesture: UIPanGestureRecognizer) {
            onDirectPointer?(gesture)
        }

        @objc private func handleDirectTap(_ gesture: UITapGestureRecognizer) {
            onDirectTap?(gesture)
        }

        @objc private func handleIndirectPointer(_ gesture: UIGestureRecognizer) {
            onIndirectPointer?(gesture)
        }

        /// SwiftUI 通过键盘安全区直接改变终端的真实高度，SwiftTerm 再据此重算行数。
        /// 禁止 `UIScrollView` 同时按安全区自动追加 adjusted inset，否则在
        /// 收起—再次弹出键盘后会对底部高度重复补偿，留下可滚动空白。
        private func configureViewportInsets() {
            contentInsetAdjustmentBehavior = .never
            hostManagesTouchGestures = true
            // Conn forwards host mouse events itself. Keeping SwiftTerm's built-in mouse
            // reporting disabled also preserves a live native selection while TUI output redraws.
            allowMouseReporting = false
            // SwiftTerm 默认会创建一排 Esc/Ctrl/方向键等输入附件。Conn 已有与终端
            // 同层的自定义快捷键栏，必须显式关闭默认附件，否则键盘上方会出现重复栏。
            inputAccessoryView = nil
        }

        /// SwiftTerm 将选择浮标画在文字坐标边缘。终端自身全宽、文字内容内移后，
        /// 浮标仍处于控件可绘制范围内，不会被左右边界裁切。
        func configureContentPadding(horizontal padding: CGFloat) {
            let padding = max(0, padding)
            horizontalContentPadding = padding
            terminalHorizontalContentInset = padding
            contentInset = UIEdgeInsets(
                top: contentInset.top,
                left: padding,
                bottom: contentInset.bottom,
                right: padding
            )
            verticalScrollIndicatorInsets = UIEdgeInsets(
                top: verticalScrollIndicatorInsets.top,
                left: padding,
                bottom: verticalScrollIndicatorInsets.bottom,
                right: padding
            )
            horizontalScrollIndicatorInsets = UIEdgeInsets(
                top: horizontalScrollIndicatorInsets.top,
                left: padding,
                bottom: horizontalScrollIndicatorInsets.bottom,
                right: padding
            )
            applyContentLayout()
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            applyContentLayout()
        }

        override public var contentOffset: CGPoint {
            didSet {
                guard horizontalContentPadding > 0 else { return }
                let targetX = -horizontalContentPadding
                guard abs(contentOffset.x - targetX) > 0.01 else { return }
                super.contentOffset = CGPoint(x: targetX, y: contentOffset.y)
            }
        }

        /// 进入窗口后自动聚焦，弹出软键盘与加速键条（无需用户先点一下）。
        override public func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isFirstResponder else { return }
                    _ = becomeFirstResponder()
                }
            } else {
                onFirstResponderChange?(false)
            }
        }

        override public func becomeFirstResponder() -> Bool {
            let didBecome = super.becomeFirstResponder()
            if didBecome {
                onFirstResponderChange?(true)
            }
            return didBecome
        }

        override public func resignFirstResponder() -> Bool {
            let didResign = super.resignFirstResponder()
            if didResign {
                onFirstResponderChange?(false)
            }
            return didResign
        }

        /// 输出流到达时保持“跟随实时输出”的语义。
        ///
        /// SwiftTerm 已经能区分实时跟随和用户手动回看，这里在 feed 前捕获状态，
        /// feed 后显式恢复底部位置，避免视口尺寸变化或批量输出时停在旧位置。
        /// 用户主动上翻后 `scrollPosition < 1`，不会被新输出抢回底部。
        func feedFollowingLiveOutput(byteArray: ArraySlice<UInt8>) {
            let wasFollowingLiveOutput = !canScroll || scrollPosition >= 1
            feed(byteArray: byteArray)
            if wasFollowingLiveOutput {
                scroll(toPosition: 1)
            }
        }

        private func applyContentLayout() {
            let targetX = -horizontalContentPadding
            if abs(contentOffset.x - targetX) > 0.01 {
                contentOffset = CGPoint(x: targetX, y: contentOffset.y)
            }
        }
    }
#endif
