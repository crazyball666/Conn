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
    /// 连接就绪后自动发送的命令（仅 DEBUG 冒烟用，验证中文渲染）。
    let autoCommand: String?

    @State private var phase: Phase = .connecting
    @Environment(SettingsStore.self) private var settings
    /// fullScreenCover 没有下滑手势也没有返回键，关闭按钮是唯一出口。
    @Environment(\.dismiss) private var dismiss

    init(host: Host, connectionManager: ConnectionManager, autoCommand: String? = nil) {
        self.host = host
        self.connectionManager = connectionManager
        self.autoCommand = autoCommand
    }

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        connectionManager = dependencies.connectionManager
        autoCommand = nil
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
    }

    private var terminalContent: some View {
        let configuration = settings.terminalConfiguration
        return ZStack {
            color(configuration.theme.background).ignoresSafeArea()
            switch phase {
            case .connecting:
                connecting
            case let .ready(session):
                TerminalHostingView(session: session, configuration: configuration)
                    // 连键盘安全区一起忽略：默认的键盘避让会把终端高度压掉近一半，
                    // SwiftTerm 随即重算行数并触发 `sizeChanged` → `session.resize`，
                    // 也就是真的给远端发一次 SIGWINCH，收键盘时再发一次。对 vim /
                    // tmux 这类全屏程序，这两次尺寸变化会直接打乱它们的布局。
                    // 改为终端保持全高、键盘盖住下半部分——远端全程无感（键盘挡住的部分
                    // 靠 `KeybarTerminalView` 自己加的 `contentInset` 补偿，见该文件）。
                    .ignoresSafeArea([.container, .keyboard], edges: .bottom)
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
        }
    }

    private func connect() async {
        do {
            let session = try await connectionManager.session(for: host)
            let channel = try await session.openShell(term: TermSize(cols: 80, rows: 24))
            let terminalSession = TerminalSession(channel: channel)
            phase = .ready(terminalSession)

            if let autoCommand {
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
}
