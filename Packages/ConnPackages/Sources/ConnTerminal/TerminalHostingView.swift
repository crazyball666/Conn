#if canImport(UIKit)
    import ConnMultiplexer
    import ConnSSH
    import ConnUI
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// SwiftUI 终端容器。
    ///
    /// 终端视口与快捷键栏是同一个 `VStack` 里的相邻区域；系统键盘位于两者下方。
    /// 快捷键栏展开时会真实压缩终端视口，不再通过 `inputAccessoryView` 悬浮覆盖内容。
    public struct TerminalHostingView: View {
        private let session: TerminalSession
        private let transcript: TerminalTranscript
        private let persistentInteraction: (any PersistentTerminalInteractionFacet)?
        private let terminalGeneration: UInt64
        private let configuration: TerminalConfiguration
        private let onChooseCommand: () -> Void
        private let onReconnect: () -> Void

        public init(
            session: TerminalSession,
            transcript: TerminalTranscript,
            persistentInteraction: (any PersistentTerminalInteractionFacet)? = nil,
            terminalGeneration: UInt64 = 0,
            configuration: TerminalConfiguration = .init(),
            onChooseCommand: @escaping () -> Void = {},
            onReconnect: @escaping () -> Void = {}
        ) {
            self.session = session
            self.transcript = transcript
            self.persistentInteraction = persistentInteraction
            self.terminalGeneration = terminalGeneration
            self.configuration = configuration
            self.onChooseCommand = onChooseCommand
            self.onReconnect = onReconnect
        }

        public var body: some View {
            TerminalHostContent(
                session: session,
                transcript: transcript,
                persistentInteraction: persistentInteraction,
                terminalGeneration: terminalGeneration,
                configuration: configuration,
                onChooseCommand: onChooseCommand,
                onReconnect: onReconnect
            )
            // 重连会换一个 TerminalSession；显式换身份，避免 @StateObject 继续持有旧会话。
            .id(ObjectIdentifier(session))
        }
    }

    private struct TerminalHostContent: View {
        @StateObject private var controller: TerminalInputController
        @State private var isKeybarExpanded: Bool
        @Environment(\.scenePhase) private var scenePhase

        private let configuration: TerminalConfiguration
        private let onChooseCommand: () -> Void
        private let onReconnect: () -> Void

        init(
            session: TerminalSession,
            transcript: TerminalTranscript,
            persistentInteraction: (any PersistentTerminalInteractionFacet)?,
            terminalGeneration: UInt64,
            configuration: TerminalConfiguration,
            onChooseCommand: @escaping () -> Void,
            onReconnect: @escaping () -> Void
        ) {
            _controller = StateObject(wrappedValue: TerminalInputController(
                session: session,
                transcript: transcript,
                persistentInteraction: persistentInteraction,
                terminalGeneration: terminalGeneration
            ))
            _isKeybarExpanded = State(
                initialValue: ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_EXPANDED"] != nil
            )
            self.configuration = configuration
            self.onChooseCommand = onChooseCommand
            self.onReconnect = onReconnect
        }

        var body: some View {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    TerminalViewportRepresentable(
                        configuration: configuration,
                        controller: controller
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !controller.isReviewActive {
                        terminalActions
                            .padding(.top, ConnSpacing.xs)
                            .padding(.trailing, ConnSpacing.sm)
                    }

                    if let notice = controller.interactionNotice {
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, ConnSpacing.sm)
                            .padding(.vertical, ConnSpacing.xs)
                            .background(.black.opacity(0.74), in: Capsule())
                            .padding(.top, ConnSpacing.xs)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    }
                }

                if configuration.showsKeybar, controller.isTerminalFocused {
                    TerminalKeybar(
                        ctrlActive: controller.ctrlActive,
                        isExpanded: isKeybarExpanded,
                        onKey: controller.handleKey,
                        onPaste: { controller.handlePaste($0) },
                        onChooseCommand: onChooseCommand,
                        onReconnect: onReconnect,
                        onDismissKeyboard: controller.dismissKeyboard,
                        onExpansionChange: { isKeybarExpanded = $0 }
                    )
                    .frame(
                        height: isKeybarExpanded
                            ? TerminalKeybarMetrics.expandedHeight
                            : TerminalKeybarMetrics.compactHeight
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("terminal.keybar")
                }
            }
            .onChange(of: controller.isTerminalFocused) { _, isFocused in
                if !isFocused {
                    isKeybarExpanded = false
                }
            }
            .onAppear { controller.setApplicationActive(scenePhase == .active) }
            .onChange(of: scenePhase) { _, phase in
                controller.setApplicationActive(phase == .active)
            }
            .onDisappear { controller.detach() }
        }

        private var terminalActions: some View {
            HStack(spacing: ConnSpacing.xs) {
                if controller.pointerAvailable {
                    Button(action: controller.togglePointer) {
                        Image(systemName: controller.pointerActive ? "cursorarrow.rays" : "cursorarrow")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.pointerActive ? .connAccent : .black.opacity(0.62))
                    .accessibilityLabel(L("远端指针模式"))
                    .accessibilityIdentifier("terminal.pointerMode")
                }

                Menu {
                    Button(action: controller.allowClipboardReadOnce) {
                        Label(L("允许读取剪贴板一次（30 秒）"), systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.62))
                .accessibilityLabel(L("终端操作"))
                .accessibilityIdentifier("terminal.actions")
            }
        }
    }

    /// 只包装 SwiftTerm 视口；快捷键栏由上层 SwiftUI 布局负责。
    private struct TerminalViewportRepresentable: UIViewRepresentable {
        let configuration: TerminalConfiguration
        let controller: TerminalInputController

        func makeUIView(context: Context) -> KeybarTerminalView {
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

        func updateUIView(_ terminalView: KeybarTerminalView, context: Context) {
            applyConfiguration(to: terminalView)
            terminalView.configureContentPadding(horizontal: ConnSpacing.sm)
        }

        static func dismantleUIView(_ terminalView: KeybarTerminalView, coordinator: Void) {
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
        private let persistentInteraction: (any PersistentTerminalInteractionFacet)?
        private let terminalGeneration: UInt64
        private let replayOutboundGate = TerminalReplayOutboundGate()
        private let interactionController = TerminalInteractionController()
        private let typedInputPlanner = TerminalTypedInputPlanner()

        private var renderTask: Task<Void, Never>?
        private var persistentStateTask: Task<Void, Never>?
        private var historyCaptureTask: Task<Void, Never>?
        private var stateResolutionTask: Task<Void, Never>?
        private var providerScrollTask: Task<Void, Never>?
        private var noticeTask: Task<Void, Never>?
        private var attachmentID: UUID?
        private var protocolState: TerminalProtocolState?
        private var persistentState: PersistentTerminalInteractionState?
        private var scrollAccumulator = TerminalScrollAccumulator(rowHeight: 18)
        private var scrollHit = TerminalInteractionHit(column: 0, row: 0, pixelX: 0, pixelY: 0)
        private var providerPendingRows = 0
        private var clipboardPolicy = TerminalClipboardPolicy()
        private var focusState = TerminalFocusState()
        private var isTypedPaste = false
        weak var terminalView: KeybarTerminalView?

        @Published var ctrlActive = false
        @Published private(set) var isTerminalFocused = false
        @Published private(set) var pointerAvailable = false
        @Published private(set) var pointerActive = false
        @Published private(set) var isReviewActive = false
        @Published private(set) var interactionNotice: String?

        init(
            session: TerminalSession,
            transcript: TerminalTranscript,
            persistentInteraction: (any PersistentTerminalInteractionFacet)?,
            terminalGeneration: UInt64
        ) {
            self.session = session
            self.transcript = transcript
            self.persistentInteraction = persistentInteraction
            self.terminalGeneration = terminalGeneration
        }

        func attach(_ terminalView: KeybarTerminalView) {
            detach()
            self.terminalView = terminalView
            terminalView.onHostProtocolStateChanged = { [weak self] state in
                Task { @MainActor in self?.acceptHostProtocolState(state) }
            }
            terminalView.installInteractionHost(
                shouldBeginRemoteScroll: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return false }
                    return self.shouldBeginRemoteScroll(gesture, in: terminalView)
                },
                onRemoteScroll: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    self.handleRemoteScroll(gesture, in: terminalView)
                },
                onSelectionLongPress: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    self.handleSelectionLongPress(gesture, in: terminalView)
                },
                shouldBeginDirectPointer: { [weak self] in self?.pointerActive == true },
                shouldBeginIndirectPointer: { [weak self] in
                    self?.protocolState?.mouseTracking.reportsMouse == true
                },
                onDirectPointer: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    self.handlePointerPan(gesture, in: terminalView)
                },
                onDirectTap: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    self.handleDirectTap(gesture, in: terminalView)
                },
                onIndirectPointer: { [weak self, weak terminalView] gesture in
                    guard let self, let terminalView else { return }
                    self.handleIndirectPointer(gesture, in: terminalView)
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
            }
        }

        func detach() {
            renderTask?.cancel()
            persistentStateTask?.cancel()
            historyCaptureTask?.cancel()
            stateResolutionTask?.cancel()
            providerScrollTask?.cancel()
            noticeTask?.cancel()
            renderTask = nil
            persistentStateTask = nil
            historyCaptureTask = nil
            stateResolutionTask = nil
            providerScrollTask = nil
            noticeTask = nil
            providerPendingRows = 0
            clipboardPolicy.clearReadAuthority()
            interactionController.invalidate()
            terminalView?.onHostProtocolStateChanged = nil
            terminalView?.dismissReview()
            terminalView?.removeInteractionHost()
            terminalView = nil
            pointerActive = false
            pointerAvailable = false
            isReviewActive = false
            guard let attachmentID else { return }
            self.attachmentID = nil
            Task { [transcript] in
                await transcript.detach(attachmentID)
            }
        }

        private func renderTranscript() async {
            var isReplayGateActive = true
            defer {
                if isReplayGateActive { replayOutboundGate.finishReplay() }
            }

            let attachment = await transcript.attach()
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
                    if requiresReset { terminalView.getTerminal().resetToInitialState() }
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
                    terminalView.scroll(toPosition: viewport.followsLiveOutput ? 1 : viewport.scrollPosition)
                case .generationBoundary:
                    replayOutboundGate.withFeed(.generationBoundary) {
                        terminalView.feedFollowingLiveOutput(
                            byteArray: TerminalTranscript.generationBoundaryBytes[...]
                        )
                    }
                }
            }
            await transcript.detach(attachment.id)
            if attachmentID == attachment.id { attachmentID = nil }
        }

        func setTerminalFocused(_ isFocused: Bool) {
            guard isTerminalFocused != isFocused else { return }
            isTerminalFocused = isFocused
            if let report = focusState.setFirstResponder(isFocused) {
                terminalView?.setHostFocus(report)
            }
        }

        func setApplicationActive(_ isActive: Bool) {
            if !isActive {
                clipboardPolicy.clearReadAuthority()
                interactionController.deactivatePointer()
                syncInteractionPresentation()
            }
            if let report = focusState.setApplicationActive(isActive) {
                terminalView?.setHostFocus(report)
            }
        }

        /// SwiftTerm uses this delegate for user input and live protocol responses. Replay and
        /// generation-boundary responses are denied, while sticky Ctrl applies only to actual
        /// user input outside a terminal feed.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard replayOutboundGate.allowsTerminalDelegateOutput else { return }
            let bytes = [UInt8](data)
            if replayOutboundGate.currentFeedProvenance == .outsideFeed,
               !isTypedPaste,
               bytes == TerminalKey.esc.bytes,
               interactionController.handleEscape() == .consumedLocally
            {
                syncInteractionPresentation()
                return
            }

            let encoded: [UInt8]
            if replayOutboundGate.currentFeedProvenance == .outsideFeed, !isTypedPaste {
                let result = TerminalKeyEncoder.encode(bytes, ctrlActive: ctrlActive)
                encoded = result.bytes
                ctrlActive = result.ctrlStillActive
            } else {
                encoded = bytes
            }
            Task { try? await session.send(encoded) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { try? await session.resize(cols: newCols, rows: newRows) }
            acceptHostProtocolState(source.hostProtocolState)
        }

        func handleKey(_ key: TerminalKey) {
            if key.isSticky {
                ctrlActive.toggle()
                return
            }
            if key == .esc, interactionController.handleEscape() == .consumedLocally {
                syncInteractionPresentation()
                return
            }
            let (encoded, stillActive) = TerminalKeyEncoder.encode(key.bytes, ctrlActive: ctrlActive)
            ctrlActive = stillActive
            Task { try? await session.send(encoded) }
        }

        func handlePaste(_ text: String, source: TerminalPasteSource = .keybar) {
            guard let terminalView else { return }
            switch typedInputPlanner.paste(text, source: source) {
            case let .paste(value):
                isTypedPaste = true
                terminalView.paste(text: value)
                isTypedPaste = false
            }
        }

        func dismissKeyboard() {
            _ = terminalView?.resignFirstResponder()
        }

        func togglePointer() {
            if interactionController.mode == .pointer {
                interactionController.deactivatePointer()
            } else {
                _ = interactionController.activatePointer()
            }
            syncInteractionPresentation()
        }

        func allowClipboardReadOnce() {
            clipboardPolicy.grantReadOnce(for: clipboardIdentity)
            showNotice(L("已允许读取一次，30 秒内有效"))
        }

        private func acceptHostProtocolState(_ state: TerminalHostProtocolState) {
            protocolState = TerminalProtocolState(state)
            updateInteractionContext()
        }

        private func acceptPersistentState(_ state: PersistentTerminalInteractionState) {
            persistentState = state
            updateInteractionContext()
        }

        private func updateInteractionContext() {
            guard let protocolState else { return }
            let persistentRoute: TerminalPersistentRouteState?
            if let persistentState {
                persistentRoute = TerminalPersistentRouteState(persistentState)
            } else if persistentInteraction != nil {
                persistentRoute = .init(
                    revision: 0,
                    freshness: .stale,
                    isAlternateBuffer: protocolState.isAlternateBuffer,
                    modeCapability: .none,
                    historyAvailable: false
                )
            } else {
                persistentRoute = nil
            }
            interactionController.update(.init(
                mode: interactionController.mode,
                protocolState: protocolState,
                terminalGeneration: terminalGeneration,
                attachmentGeneration: persistentState?.attachmentGeneration ?? terminalGeneration,
                persistent: persistentRoute,
                localHistoryAvailable: terminalView?.canScroll == true
            ))
            syncInteractionPresentation()
        }

        private func syncInteractionPresentation() {
            pointerAvailable = interactionController.pointerAvailable
            pointerActive = interactionController.mode == .pointer
            isReviewActive = interactionController.review != nil
            if !isReviewActive { terminalView?.dismissReview() }
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
            switch action {
            case .remoteMouse:
                terminalView.sendHostWheel(
                    direction: rows > 0 ? .up : .down,
                    count: abs(rows),
                    at: scrollHit,
                    modifiers: []
                )
            case .providerScrollableMode:
                enqueueProviderScroll(rows)
            case .providerKeyDrivenMode, .providerAlternateKeys, .plainAlternateKeys:
                terminalView.sendHostCursorKey(direction, count: abs(rows))
            case .providerHistory:
                capturePersistentHistory(selectionHit: nil)
            case .resolvePersistentState:
                resolvePersistentState(replayingRows: rows)
            case .selection, .pointer, .providerUnsupportedBoundary,
                 .localNormalBuffer, .boundary:
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
                    guard let self, self.terminalGeneration == generation,
                          let terminalView = self.terminalView else { return }
                    self.acceptPersistentState(state)
                    let action = self.interactionController.beginScroll(modeOverride: .live)
                    self.executeScroll(action, rows: rows, in: terminalView)
                } catch {
                    self?.showNotice(L("远端终端状态暂不可用，可重试"))
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
                expectedStateRevision: state.revision,
                direction: rows > 0 ? .up : .down,
                rows: abs(rows)
            ) else { return }
            providerScrollTask = Task { @MainActor [weak self] in
                do {
                    try await persistentInteraction.scrollProviderMode(request)
                } catch {
                    self?.providerPendingRows = 0
                    self?.showNotice(L("该远端模式暂时无法滚动"))
                }
                self?.providerScrollTask = nil
                self?.drainProviderScroll()
            }
        }

        private func handleSelectionLongPress(
            _ gesture: UILongPressGestureRecognizer,
            in terminalView: KeybarTerminalView
        ) {
            guard gesture.state == .began else { return }
            let hit = terminalView.interactionHit(at: gesture.location(in: terminalView))
            acceptHostProtocolState(terminalView.hostProtocolState)
            if persistentInteraction != nil, protocolState?.isAlternateBuffer != true {
                if persistentState == nil {
                    resolveThenCaptureSelection(hit)
                } else {
                    capturePersistentHistory(selectionHit: hit)
                }
                return
            }
            let scope: TerminalSnapshotScope = protocolState?.isAlternateBuffer == true
                ? .visible : .normalHistory
            let source = terminalView.makeHostSnapshot(scope)
            let snapshot = TerminalReviewSnapshot(
                swiftTerm: source,
                terminalGeneration: terminalGeneration,
                attachmentGeneration: persistentState?.attachmentGeneration ?? terminalGeneration
            )
            let line = scope == .visible
                ? hit.row
                : source.visibleLineRange.lowerBound + hit.row
            presentReview(snapshot, selectionOffset: snapshot.utf16Offset(line: line, column: hit.column))
        }

        private func resolveThenCaptureSelection(_ hit: TerminalInteractionHit) {
            guard stateResolutionTask == nil, let persistentInteraction else { return }
            stateResolutionTask = Task { @MainActor [weak self] in
                defer { self?.stateResolutionTask = nil }
                do {
                    let state = try await persistentInteraction.resolveState()
                    guard let self else { return }
                    self.acceptPersistentState(state)
                    self.capturePersistentHistory(selectionHit: hit)
                } catch {
                    self?.showNotice(L("远端历史暂不可用，可重试"))
                }
            }
        }

        private func capturePersistentHistory(selectionHit: TerminalInteractionHit?) {
            guard historyCaptureTask == nil,
                  let persistentInteraction,
                  let state = persistentState,
                  let request = try? PersistentTerminalHistoryRequest(
                      target: state.target,
                      attachmentGeneration: state.attachmentGeneration,
                      expectedStateRevision: state.revision,
                      maxLines: 20_000,
                      maxBytes: 1_048_576
                  )
            else { return }
            let generation = terminalGeneration
            historyCaptureTask = Task { @MainActor [weak self] in
                defer { self?.historyCaptureTask = nil }
                do {
                    let captured = try await persistentInteraction.captureHistory(request)
                    guard let self,
                          self.terminalGeneration == generation,
                          self.persistentState?.target == captured.target,
                          self.persistentState?.attachmentGeneration == captured.attachmentGeneration
                    else { return }
                    let snapshot = TerminalReviewSnapshot(
                        persistent: captured,
                        terminalGeneration: generation
                    )
                    let offset = selectionHit.flatMap {
                        snapshot.utf16Offset(
                            line: snapshot.visibleLineRange.lowerBound + $0.row,
                            column: $0.column
                        )
                    }
                    self.presentReview(snapshot, selectionOffset: offset)
                } catch {
                    self?.showNotice(L("远端历史暂不可用，可重试"))
                }
            }
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
            terminalView?.presentReview(
                snapshot,
                selectingUTF16Offset: selectionOffset,
                onClose: { [weak self] in
                    self?.interactionController.dismissReview()
                    self?.syncInteractionPresentation()
                }
            )
            syncInteractionPresentation()
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
            if pointerActive {
                let hit = terminalView.interactionHit(at: gesture.location(in: terminalView))
                terminalView.sendHostPointer(.press(button: 0), at: hit, modifiers: [])
                terminalView.sendHostPointer(.release(button: 0), at: hit, modifiers: [])
            } else {
                _ = terminalView.becomeFirstResponder()
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

        private func showNotice(_ text: String) {
            noticeTask?.cancel()
            interactionNotice = text
            noticeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.interactionNotice = nil
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {
            updateInteractionContext()
            let state = TerminalViewportState(
                followsLiveOutput: !source.canScroll || position >= 1,
                scrollPosition: position
            )
            Task { [transcript] in await transcript.updateViewport(state) }
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
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
            showNotice(L("已复制"))
        }
        func clipboardRead(source: TerminalView) -> Data? {
            guard replayOutboundGate.allowsHostSideEffects,
                  clipboardPolicy.consumeReadAuthority(for: clipboardIdentity)
            else { return nil }
            if let text = UIPasteboard.general.string {
                return boundedClipboardData(Data(text.utf8))
            }
            return UIPasteboard.general.data(forPasteboardType: "public.data")
                .flatMap(boundedClipboardData)
        }
        private func boundedClipboardData(_ data: Data) -> Data? {
            data.count <= clipboardPolicy.maximumWriteBytes ? data : nil
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
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
        init(_ state: PersistentTerminalInteractionState) {
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
        private var remoteScrollPan: UIPanGestureRecognizer?
        private var selectionLongPress: UILongPressGestureRecognizer?
        private var directPointerPan: UIPanGestureRecognizer?
        private var directTap: UITapGestureRecognizer?
        private var indirectPointerPan: UIPanGestureRecognizer?
        private var indirectPointerTap: UITapGestureRecognizer?
        private var shouldBeginRemoteScroll: ((UIPanGestureRecognizer) -> Bool)?
        private var onRemoteScroll: ((UIPanGestureRecognizer) -> Void)?
        private var onSelectionLongPress: ((UILongPressGestureRecognizer) -> Void)?
        private var shouldBeginDirectPointer: (() -> Bool)?
        private var shouldBeginIndirectPointer: (() -> Bool)?
        private var onDirectPointer: ((UIPanGestureRecognizer) -> Void)?
        private var onDirectTap: ((UITapGestureRecognizer) -> Void)?
        private var onIndirectPointer: ((UIGestureRecognizer) -> Void)?
        private var reviewSurface: TerminalReviewTextView?

        var installedRemoteScrollGesture: UIPanGestureRecognizer? { remoteScrollPan }
        var installedSelectionGesture: UILongPressGestureRecognizer? { selectionLongPress }
        var installedDirectPointerGesture: UIPanGestureRecognizer? { directPointerPan }
        var installedIndirectPointerGesture: UIPanGestureRecognizer? { indirectPointerPan }

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
            shouldBeginRemoteScroll: @escaping (UIPanGestureRecognizer) -> Bool,
            onRemoteScroll: @escaping (UIPanGestureRecognizer) -> Void,
            onSelectionLongPress: @escaping (UILongPressGestureRecognizer) -> Void,
            shouldBeginDirectPointer: @escaping () -> Bool,
            shouldBeginIndirectPointer: @escaping () -> Bool,
            onDirectPointer: @escaping (UIPanGestureRecognizer) -> Void,
            onDirectTap: @escaping (UITapGestureRecognizer) -> Void,
            onIndirectPointer: @escaping (UIGestureRecognizer) -> Void
        ) {
            self.shouldBeginRemoteScroll = shouldBeginRemoteScroll
            self.onRemoteScroll = onRemoteScroll
            self.onSelectionLongPress = onSelectionLongPress
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

            let remotePan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleRemoteScroll(_:))
            )
            remotePan.maximumNumberOfTouches = 2
            remotePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            remotePan.cancelsTouchesInView = true
            remotePan.require(toFail: longPress)
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
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            ]
            addGestureRecognizer(hardwarePan)
            indirectPointerPan = hardwarePan

            let hardwareTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleIndirectPointer(_:))
            )
            hardwareTap.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            ]
            hardwareTap.require(toFail: hardwarePan)
            addGestureRecognizer(hardwareTap)
            indirectPointerTap = hardwareTap

            // The remote recognizer gets first refusal. It fails immediately for ordinary
            // normal-buffer history, at which point UIScrollView's native pan proceeds.
            panGestureRecognizer.require(toFail: remotePan)
            panGestureRecognizer.require(toFail: longPress)
        }

        func removeInteractionHost() {
            [remoteScrollPan, selectionLongPress, directPointerPan, directTap,
             indirectPointerPan, indirectPointerTap]
                .compactMap { $0 }
                .forEach(removeGestureRecognizer)
            remoteScrollPan = nil
            selectionLongPress = nil
            directPointerPan = nil
            directTap = nil
            indirectPointerPan = nil
            indirectPointerTap = nil
            shouldBeginRemoteScroll = nil
            onRemoteScroll = nil
            onSelectionLongPress = nil
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
            review.display(
                snapshot,
                selectingUTF16Offset: selectingUTF16Offset,
                font: font,
                foregroundColor: nativeForegroundColor,
                backgroundColor: nativeBackgroundColor
            )
            if review.superview == nil { addSubview(review) }
            bringSubviewToFront(review)
        }

        func dismissReview() {
            reviewSurface?.removeFromSuperview()
            reviewSurface = nil
        }

        override public func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if let remoteScrollPan, gestureRecognizer === remoteScrollPan {
                return shouldBeginRemoteScroll?(remoteScrollPan) == true
            }
            if gestureRecognizer === selectionLongPress {
                return reviewSurface == nil && shouldBeginDirectPointer?() != true
            }
            if gestureRecognizer === directPointerPan {
                return shouldBeginDirectPointer?() == true
            }
            if gestureRecognizer === indirectPointerPan
                || gestureRecognizer === indirectPointerTap
            {
                return shouldBeginIndirectPointer?() == true
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        @objc override public func paste(_ sender: Any?) {
            guard let text = UIPasteboard.general.string else { return }
            onSystemPaste?(text)
        }

        @objc private func handleRemoteScroll(_ gesture: UIPanGestureRecognizer) {
            onRemoteScroll?(gesture)
        }

        @objc private func handleSelectionLongPress(_ gesture: UILongPressGestureRecognizer) {
            onSelectionLongPress?(gesture)
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
            // SwiftTerm 默认会创建一排 Esc/Ctrl/方向键等输入附件。Conn 已有与终端
            // 同层的自定义快捷键栏，必须显式关闭默认附件，否则键盘上方会出现重复栏。
            inputAccessoryView = nil
        }

        /// SwiftTerm 将选择浮标画在文字坐标边缘。终端自身全宽、文字内容内移后，
        /// 浮标仍处于控件可绘制范围内，不会被左右边界裁切。
        func configureContentPadding(horizontal padding: CGFloat) {
            let padding = max(0, padding)
            horizontalContentPadding = padding
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
                    _ = self?.becomeFirstResponder()
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
            let usableWidth = bounds.width - horizontalContentPadding * 2
            let terminal = getTerminal()
            guard horizontalContentPadding > 0,
                  usableWidth > 0,
                  terminal.cols > 0 else {
                return
            }

            let cellWidth = getOptimalFrameSize().width / CGFloat(terminal.cols)
            guard cellWidth > 0 else { return }

            let targetColumns = max(1, Int(usableWidth / cellWidth))
            if targetColumns != terminal.cols {
                resize(cols: targetColumns, rows: terminal.rows)
            }

            let targetX = -horizontalContentPadding
            if abs(contentOffset.x - targetX) > 0.01 {
                contentOffset = CGPoint(x: targetX, y: contentOffset.y)
            }
        }

    }
#endif
