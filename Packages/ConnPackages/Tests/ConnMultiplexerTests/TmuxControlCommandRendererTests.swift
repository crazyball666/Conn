import ConnMultiplexer
import Foundation
import Testing

@Suite("tmux Control Mode command renderer")
struct TmuxControlCommandRendererTests {
    @Test("Session、Window、Pane 首期操作渲染为明确的 tmux command language")
    func rendersFirstReleaseOperations() throws {
        let renderer = TmuxControlCommandRenderer()
        let session = try #require(TmuxSessionID(rawValue: "$1"))
        let window = try #require(TmuxWindowID(rawValue: "@2"))
        let pane = try #require(TmuxPaneID(rawValue: "%3"))
        let client = try TmuxClientTarget("/dev/pts/9")

        let fixtures: [(TmuxOperation, String)] = [
            (
                .createSession(name: try TmuxName("ops")),
                "new-session -d -P -F '#{session_id}' -s 'ops'"
            ),
            (
                .createSession(name: nil),
                "new-session -d -P -F '#{session_id}'"
            ),
            (
                .renameSession(session, to: try TmuxName("prod api")),
                "rename-session -t '$1' 'prod api'"
            ),
            (.detachClient(client), "detach-client -t '/dev/pts/9'"),
            (.killSession(session), "kill-session -t '$1'"),
            (
                .selectWindow(window, for: client),
                "switch-client -c '/dev/pts/9' -t '@2'"
            ),
            (
                .createWindow(in: session, name: try TmuxName("logs")),
                "new-window -d -P -F '#{window_id}' -t '$1:' -n 'logs'"
            ),
            (
                .createWindow(in: session, name: nil),
                "new-window -d -P -F '#{window_id}' -t '$1:'"
            ),
            (
                .renameWindow(window, to: try TmuxName("api")),
                "rename-window -t '@2' 'api'"
            ),
            (.killWindow(window), "kill-window -t '@2'"),
            (
                .selectPane(pane, for: client),
                "switch-client -c '/dev/pts/9' -t '%3'"
            ),
            (
                .splitPane(pane, orientation: .horizontal),
                "split-window -d -P -F '#{pane_id}' -h -t '%3'"
            ),
            (
                .splitPane(pane, orientation: .vertical),
                "split-window -d -P -F '#{pane_id}' -v -t '%3'"
            ),
            (
                .setPaneZoom(pane, zoomed: true),
                "if-shell -F -t '%3' '#{==:#{window_zoomed_flag},0}' "
                    + "'resize-pane -Z -t %3' ''"
            ),
            (
                .setPaneZoom(pane, zoomed: false),
                "if-shell -F -t '%3' '#{window_zoomed_flag}' "
                    + "'resize-pane -Z -t %3' ''"
            ),
            (.killPane(pane), "kill-pane -t '%3'"),
        ]

        for (operation, expected) in fixtures {
            let command = renderer.render(operation)
            #expect(command.value == expected)
            #expect(command.wireData == Data((expected + "\n").utf8))
        }
    }

    @Test("tmux 参数编码阻断分号、注释、变量展开与引号注入")
    func encodesHostileButValidNameAsOneArgument() throws {
        let session = try #require(TmuxSessionID(rawValue: "$7"))
        let name = try TmuxName("prod'; kill-server; # $HOME \\ 名称")

        let rendered = TmuxControlCommandRenderer().render(
            .renameSession(session, to: name)
        )

        #expect(
            rendered.value
                == #"rename-session -t '$7' 'prod'\''; kill-server; # $HOME \ 名称'"#
        )
        #expect(rendered.value.filter { $0 == "\n" }.isEmpty)
    }

    @Test("Control renderer 永远不加入 executable、server locator 或 shell wrapper")
    func controlCommandsContainNoTransportLayerSyntax() throws {
        let pane = try #require(TmuxPaneID(rawValue: "%1"))
        let command = TmuxControlCommandRenderer().render(.killPane(pane)).value

        #expect(command == "kill-pane -t '%1'")
        #expect(!command.contains("/tmux"))
        #expect(!command.contains(" -L "))
        #expect(!command.contains(" -S "))
        #expect(!command.contains("sh -c"))
    }

    @Test("data client size participation uses a typed targeted flag mutation")
    func rendersTargetedClientFlagMutation() throws {
        let target = try TmuxClientTarget("/dev/pts/9")
        let renderer = TmuxControlCommandRenderer()

        #expect(renderer.render(TmuxClientFlagUpdate(
            client: target,
            flag: .ignoreSize,
            enabled: true
        )).value == "refresh-client -t '/dev/pts/9' -f 'ignore-size'")
        #expect(renderer.render(TmuxClientFlagUpdate(
            client: target,
            flag: .ignoreSize,
            enabled: false
        )).value == "refresh-client -t '/dev/pts/9' -f '!ignore-size'")
    }

    @Test("Conn 主动创建的名称按 UTF-8 字节限制并拒绝空白及控制字符")
    func validatesManagedNames() throws {
        #expect(try TmuxName("Unicode 名称").value == "Unicode 名称")
        for invalid in ["", "   ", "line\nfeed", "escape\u{1B}sequence"] {
            #expect(throws: TmuxOperationError.self) {
                try TmuxName(invalid)
            }
        }
        #expect(throws: TmuxOperationError.self) {
            try TmuxName(String(repeating: "a", count: 257))
        }
    }

    @Test("Control client target 拒绝空值、控制字符和超长值")
    func validatesClientTarget() throws {
        #expect(try TmuxClientTarget("/dev/ttys001").value == "/dev/ttys001")
        for invalid in ["", "tty\nnext", String(repeating: "x", count: 1025)] {
            #expect(throws: TmuxOperationError.self) {
                try TmuxClientTarget(invalid)
            }
        }
    }

    @Test("bootstrap create 与普通 token-bound operation 是不同类型")
    func bootstrapOperationIsSeparated() throws {
        let bootstrap = TmuxBootstrapOperation.createSession(name: try TmuxName("first"))
        let ordinary = TmuxOperation.createSession(name: try TmuxName("next"))

        #expect(bootstrap == .createSession(name: try TmuxName("first")))
        #expect(ordinary == .createSession(name: try TmuxName("next")))
    }
}
