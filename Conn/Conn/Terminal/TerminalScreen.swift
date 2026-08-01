import ConnKit
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// 单个主机的终端会话屏。
///
/// Phase 4a：单会话直连。多标签会话中心（S4）在 Phase 4b。
struct TerminalScreen: View {
    let host: Host
    let connectionManager: ConnectionManager
    private let snippetRepository: (any SnippetRepository)?
    private let snippetGroupRepository: (any SnippetGroupRepository)?
    /// 首次连接就绪后自动发送的命令（Docker 控制台 / 命令片段 / DEBUG 冒烟）。
    let autoCommand: String?
    /// Docker 控制台重开 shell 后需要重新进入容器；普通命令片段不能因重连被重复执行。
    private let replaysAutoCommandOnReconnect: Bool

    @State private var phase: Phase = .connecting
    @State private var isOpeningTerminal = false
    @State private var isCommandPickerPresented = false
    @State private var hasSentAutoCommand = false
    @State private var hasPendingAutoCommandReplay = false
    @Environment(SettingsStore.self) private var settings
    /// fullScreenCover 没有下滑手势也没有返回键，关闭按钮是唯一出口。
    @Environment(\.dismiss) private var dismiss

    init(
        host: Host,
        connectionManager: ConnectionManager,
        autoCommand: String? = nil,
        replaysAutoCommandOnReconnect: Bool = false,
        snippetRepository: (any SnippetRepository)? = nil,
        snippetGroupRepository: (any SnippetGroupRepository)? = nil
    ) {
        self.host = host
        self.connectionManager = connectionManager
        self.autoCommand = autoCommand
        self.replaysAutoCommandOnReconnect = replaysAutoCommandOnReconnect
        self.snippetRepository = snippetRepository
        self.snippetGroupRepository = snippetGroupRepository
    }

    init(
        host: Host,
        dependencies: AppDependencies,
        autoCommand: String? = nil,
        replaysAutoCommandOnReconnect: Bool = false
    ) {
        self.host = host
        connectionManager = dependencies.connectionManager
        self.autoCommand = autoCommand
        self.replaysAutoCommandOnReconnect = replaysAutoCommandOnReconnect
        snippetRepository = dependencies.snippetRepository
        snippetGroupRepository = dependencies.snippetGroupRepository
    }

    enum Phase {
        case connecting
        case ready(TerminalSession)
        case failed(String)
    }

    var body: some View {
        // 六个调用点都改成了 `.fullScreenCover`（没有系统返回键/下滑手势），
        // 所以这层导航栈与关闭按钮自己包在 `TerminalScreen` 内部，调用方无需关心。
        // 唯一例外是 `ConnApp` 的 `CONN_SMOKE_TERMINAL` 冒烟入口——它把本视图直接当
        // 根视图用，不会再套一层 `NavigationStack`，避免嵌两层导航栈。
        NavigationStack {
            terminalContent
                .navigationTitle(host.name)
                .navigationBarTitleDisplayMode(.inline)
                // 终端背景是深色，nav bar 透明露出底色，强制 dark scheme 让标题/返回箭头
                // 按深色模式渲染（浅色字），否则会出现「黑字黑底看不见」。
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { closeButton }
                }
        }
        // 上面的 toolbarColorScheme 只管导航栏。状态栏不是 toolbar——时间 / 信号 /
        // 电量跟的是 `preferredColorScheme`，App 在浅色模式时它们被画成黑字，压在
        // 深色终端上几乎看不见。全部 8 个终端主题背景都是深色（#07090F～#2E3440），
        // 所以这里无条件强制深色是安全的。
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isCommandPickerPresented) {
            if let snippetRepository, let snippetGroupRepository {
                TerminalCommandPickerView(
                    repository: snippetRepository,
                    groupRepository: snippetGroupRepository,
                    onSelect: insertCommand
                )
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var terminalContent: some View {
        let configuration = settings.terminalConfiguration
        return ZStack {
            color(configuration.theme.background).ignoresSafeArea()
            switch phase {
            case .connecting:
                connecting
            case let .ready(session):
                TerminalHostingView(
                    session: session,
                    configuration: configuration,
                    onChooseCommand: showCommandPicker,
                    onReconnect: { reopen(session) }
                )
                    // 只延伸到设备底边，保留键盘安全区。键盘出现时终端视口真实缩小，
                    // SwiftTerm 会同步 PTY 行数并把当前提示符留在键盘上方；不再通过
                    // contentInset 伪造一段可滚动空白。
                    .ignoresSafeArea(.container, edges: .bottom)
            case let .failed(message):
                failure(message)
            }
        }
        .task { await connect() }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
        }
        .accessibilityLabel(L("关闭"))
    }

    private func color(_ rgb: TerminalTheme.RGB) -> Color {
        Color(
            red: Double(rgb.r) / 255,
            green: Double(rgb.g) / 255,
            blue: Double(rgb.b) / 255
        )
    }

    private var connecting: some View {
        VStack(spacing: ConnSpacing.sm) {
            ProgressView().controlSize(.large).tint(.connAccent)
            Text(String(format: L("正在连接 %@…"), host.name))
                .font(.connData())
                .foregroundStyle(.connMuted)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: ConnSpacing.sm) {
            Image(systemName: "xmark.octagon").font(.system(size: 40)).foregroundStyle(.connCrit)
            Text(message)
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ConnSpacing.xl)
            ConnButton(L("重试"), kind: .ghost) {
                phase = .connecting
                Task { await connect() }
            }
        }
    }

    private func connect() async {
        guard !isOpeningTerminal else { return }
        isOpeningTerminal = true
        defer { isOpeningTerminal = false }
        do {
            let session = try await connectionManager.session(for: host)
            let channel = try await session.openShell(term: TermSize(cols: 80, rows: 24))
            let terminalSession = TerminalSession(channel: channel)
            phase = .ready(terminalSession)

            if let autoCommand, !hasSentAutoCommand || hasPendingAutoCommandReplay {
                hasSentAutoCommand = true
                hasPendingAutoCommandReplay = false
                // 等 shell 就绪后自动发一条命令（冒烟：验证中文渲染）
                Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    await terminalSession.send([UInt8]("\(autoCommand)\n".utf8))
                }
            }
        } catch let error as SSHError {
            phase = .failed(error.diagnosis)
        } catch {
            phase = .failed(String(format: L("连接失败：%@"), error.friendlyDiagnosis))
        }
    }

    /// 只关闭当前 PTY shell，再从连接池打开一个新 shell；不驱逐共享 SSH 连接，
    /// 避免打断同一主机正在采集的指标、文件传输或日志流。
    private func reopen(_ current: TerminalSession) {
        guard !isOpeningTerminal else { return }
        hasPendingAutoCommandReplay = replaysAutoCommandOnReconnect
        phase = .connecting
        Task {
            await current.close()
            await connect()
        }
    }

    private func showCommandPicker() {
        guard snippetRepository != nil, snippetGroupRepository != nil else { return }
        isCommandPickerPresented = true
    }

    /// 本地命令只写进当前 PTY，不追加换行；用户仍需在终端里确认后手动执行。
    private func insertCommand(_ command: String) {
        guard case let .ready(session) = phase else { return }
        isCommandPickerPresented = false
        Task { await session.send(Array(command.utf8)) }
    }
}
