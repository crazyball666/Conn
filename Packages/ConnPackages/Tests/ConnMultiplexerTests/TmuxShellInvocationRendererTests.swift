import ConnKit
import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux POSIX shell invocation renderer")
struct TmuxShellInvocationRendererTests {
    @Test("default locator 在单次 tmux invocation 内校验 PID 与启动时间再执行")
    func rendersGuardedDefaultInvocation() throws {
        let renderer = TmuxShellInvocationRenderer()
        let executable = try TmuxExecutablePath("/usr/local/bin/tmux")
        let token = try makeToken()
        let pane = try #require(TmuxPaneID(rawValue: "%3"))
        let nonce = try TmuxInvocationNonce("n-1")

        let invocation = try renderer.render(
            .killPane(pane),
            executable: executable,
            locator: .default,
            expectedInstance: token,
            nonce: nonce
        )

        #expect(invocation.arguments == [
            "if-shell",
            "-F",
            "#{&&:#{==:#{pid},321},#{==:#{start_time},1765000000}}",
            "display-message -p '__CONN_TMUX_GUARD_ACCEPTED_n-1__' ; kill-pane -t '%3'",
            "display-message -p '__CONN_TMUX_INSTANCE_CHANGED_n-1__'",
        ])
        #expect(invocation.guardAcceptedMarker == "__CONN_TMUX_GUARD_ACCEPTED_n-1__")
        #expect(invocation.instanceChangedMarker == "__CONN_TMUX_INSTANCE_CHANGED_n-1__")
        #expect(
            invocation.script
                == #"exec /usr/local/bin/tmux if-shell -F '#{&&:#{==:#{pid},321},#{==:#{start_time},1765000000}}' 'display-message -p '\''__CONN_TMUX_GUARD_ACCEPTED_n-1__'\'' ; kill-pane -t '\''%3'\''' 'display-message -p '\''__CONN_TMUX_INSTANCE_CHANGED_n-1__'\'''"#
        )
        #expect(invocation.script.components(separatedBy: "/usr/local/bin/tmux").count == 2)
    }

    @Test("named 与 path locator 只通过同一次 invocation 的 argv 注入")
    func rendersLocatorArguments() throws {
        let renderer = TmuxShellInvocationRenderer()
        let executable = try TmuxExecutablePath("/opt/Ops Tools/tmux")
        let token = try makeToken(path: "/tmp/conn socket")
        let session = try #require(TmuxSessionID(rawValue: "$1"))
        let nonce = try TmuxInvocationNonce("abc")

        let named = try renderer.render(
            .killSession(session),
            executable: executable,
            locator: try .namedSocket("conn-work"),
            expectedInstance: token,
            nonce: nonce
        )
        #expect(Array(named.arguments.prefix(2)) == ["-L", "conn-work"])
        #expect(named.script.hasPrefix("exec '/opt/Ops Tools/tmux' -L conn-work "))

        let path = try renderer.render(
            .killSession(session),
            executable: executable,
            locator: try .socketPath("/tmp/conn socket"),
            expectedInstance: token,
            nonce: nonce
        )
        #expect(Array(path.arguments.prefix(2)) == ["-S", "/tmp/conn socket"])
        #expect(path.script.hasPrefix("exec '/opt/Ops Tools/tmux' -S '/tmp/conn socket' "))
    }

    @Test("socket-path profile 与 token 指向不同 socket 时在渲染前拒绝")
    func rejectsSocketPathInstanceMismatch() throws {
        let renderer = TmuxShellInvocationRenderer()
        let pane = try #require(TmuxPaneID(rawValue: "%1"))

        #expect(throws: TmuxShellInvocationError.locatorInstanceMismatch) {
            try renderer.render(
                .killPane(pane),
                executable: TmuxExecutablePath("/usr/bin/tmux"),
                locator: .socketPath("/tmp/other.sock"),
                expectedInstance: makeToken(path: "/tmp/expected.sock"),
                nonce: TmuxInvocationNonce("nonce")
            )
        }
    }

    @Test("Shell renderer 对嵌套 tmux command 与 POSIX argv 分别编码")
    func independentlyEncodesNestedCommandAndShellArguments() throws {
        let session = try #require(TmuxSessionID(rawValue: "$7"))
        let name = try TmuxName("prod'; kill-server; # $HOME \\ 名称")
        let invocation = try TmuxShellInvocationRenderer().render(
            .renameSession(session, to: name),
            executable: TmuxExecutablePath("/usr/bin/tmux"),
            locator: .default,
            expectedInstance: makeToken(),
            nonce: TmuxInvocationNonce("safe")
        )

        let guardedCommand = invocation.arguments[3]
        #expect(
            guardedCommand.contains(
                #"rename-session -t '$7' 'prod'\''; kill-server; # $HOME \ 名称'"#
            )
        )
        #expect(invocation.script.hasPrefix("exec /usr/bin/tmux if-shell -F "))
        #expect(!invocation.script.contains("sh -c"))
    }

    @Test("pane layouts remain typed inside the guarded one-shot invocation")
    func rendersPaneLayout() throws {
        let window = try #require(TmuxWindowID(rawValue: "@8"))
        let invocation = try TmuxShellInvocationRenderer().render(
            .applyPaneLayout(window, layout: .mainVertical),
            executable: TmuxExecutablePath("/usr/bin/tmux"),
            locator: .default,
            expectedInstance: makeToken(),
            nonce: TmuxInvocationNonce("layout")
        )

        #expect(invocation.arguments[3].contains(
            "select-layout -t '@8' 'main-vertical'"
        ))
    }

    @Test("tmux 原生选择器使用当前 Pane 显示 Session 与 Window 列表")
    func rendersNativeTreeSelectors() throws {
        let pane = try #require(TmuxPaneID(rawValue: "%3"))
        let renderer = TmuxShellInvocationRenderer()
        let executable = try TmuxExecutablePath("/usr/bin/tmux")
        let token = try makeToken()

        let sessions = try renderer.render(
            .chooseTree(pane, scope: .sessions),
            executable: executable,
            locator: .default,
            expectedInstance: token,
            nonce: TmuxInvocationNonce("sessions")
        )
        let windows = try renderer.render(
            .chooseTree(pane, scope: .windows),
            executable: executable,
            locator: .default,
            expectedInstance: token,
            nonce: TmuxInvocationNonce("windows")
        )

        #expect(sessions.arguments[3].contains("choose-tree -s -t '%3'"))
        #expect(windows.arguments[3].contains("choose-tree -w -t '%3'"))
    }

    @Test("进入历史时启用滚动到底自动退出 copy mode")
    func rendersCopyModeWithExitAtBottom() throws {
        let pane = try #require(TmuxPaneID(rawValue: "%3"))
        let invocation = try TmuxShellInvocationRenderer().render(
            .enterCopyMode(pane),
            executable: TmuxExecutablePath("/usr/bin/tmux"),
            locator: .default,
            expectedInstance: makeToken(),
            nonce: TmuxInvocationNonce("copy-mode")
        )

        #expect(invocation.arguments[3].contains("copy-mode -e -t '%3'"))
    }

    @Test("相对 Window 导航使用 tmux 原生偏移在单条命令中合并多步")
    func rendersBatchedRelativeWindowNavigation() throws {
        let session = try #require(TmuxSessionID(rawValue: "$7"))
        let client = try TmuxClientTarget("/dev/pts/9")
        let invocation = try TmuxShellInvocationRenderer().render(
            .selectRelativeWindow(
                in: session,
                direction: .previous,
                steps: TmuxWindowNavigationStepCount(2),
                for: client
            ),
            executable: TmuxExecutablePath("/usr/bin/tmux"),
            locator: .default,
            expectedInstance: makeToken(),
            nonce: TmuxInvocationNonce("window-nav")
        )

        #expect(invocation.arguments[3].contains(
            "switch-client -c '/dev/pts/9' -t '$7:-2'"
        ))
    }

    @Test("tmux executable 与 invocation nonce 必须是受限类型")
    func validatesExecutableAndNonce() throws {
        #expect(try TmuxExecutablePath("/opt//tmux/./bin/tmux").value == "/opt/tmux/bin/tmux")

        for invalid in ["", "tmux", "./tmux", "/opt/../bin/tmux", "/bin/tmux\nnext"] {
            #expect(throws: TmuxShellInvocationError.self) {
                try TmuxExecutablePath(invalid)
            }
        }
        for invalid in ["", "has space", "bad/slash", String(repeating: "x", count: 129)] {
            #expect(throws: TmuxShellInvocationError.self) {
                try TmuxInvocationNonce(invalid)
            }
        }
    }

    @Test("Shell script 仍由已固定绝对路径的 POSIX runtime 承载")
    func wrapsWithPreparedPOSIXRuntime() throws {
        let pane = try #require(TmuxPaneID(rawValue: "%1"))
        let invocation = try TmuxShellInvocationRenderer().render(
            .killPane(pane),
            executable: TmuxExecutablePath("/usr/bin/tmux"),
            locator: .default,
            expectedInstance: makeToken(),
            nonce: TmuxInvocationNonce("runtime")
        )
        let runtime = try POSIXScriptExecutionProvider().prepareRuntime(
            resolvedExecutablePath: "/bin/sh",
            interpreter: .sh
        )
        let transportCommand = try runtime.invocation(for: invocation.script)

        #expect(transportCommand.hasPrefix("/bin/sh -c "))
        #expect(transportCommand.contains("/usr/bin/tmux"))
        #expect(!transportCommand.contains("command -v"))
    }

    private func makeToken(
        path: String = "/tmp/tmux-501/default"
    ) throws -> TmuxServerInstanceToken {
        try TmuxServerInstanceToken(
            resolvedSocketPath: path,
            serverPID: 321,
            serverStartTime: 1_765_000_000
        )
    }
}
