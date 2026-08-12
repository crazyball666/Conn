import ConnMultiplexer
import Foundation
import Testing

@Suite("tmux identity and locator")
struct TmuxIdentityTests {
    @Test("default、named socket 与 socket path 生成稳定且互斥的定位参数")
    func locatorArgumentsAndKeys() throws {
        let defaultLocator = TmuxServerLocator.default
        let named = try TmuxServerLocator.namedSocket("conn-work")
        let path = try TmuxServerLocator.socketPath("/tmp//conn/./tmux.sock")

        #expect(defaultLocator.arguments == [])
        #expect(defaultLocator.configurationKey == "default")
        #expect(named.arguments == ["-L", "conn-work"])
        #expect(named.configurationKey == "named:conn-work")
        #expect(path.arguments == ["-S", "/tmp/conn/tmux.sock"])
        #expect(path.configurationKey == "path:/tmp/conn/tmux.sock")
    }

    @Test("named socket 拒绝空值、路径和控制字符")
    func namedSocketValidation() {
        for invalid in ["", "a/b", "line\nfeed", "nul\0byte"] {
            #expect(throws: TmuxIdentityError.self) {
                try TmuxServerLocator.namedSocket(invalid)
            }
        }
    }

    @Test("socket path 必须是规范化的绝对 POSIX 路径且不能向上穿越")
    func socketPathValidation() throws {
        for invalid in ["relative.sock", "/tmp/../escape.sock", "/tmp/line\nfeed"] {
            #expect(throws: TmuxIdentityError.self) {
                try TmuxServerLocator.socketPath(invalid)
            }
        }

        let normalized = try TmuxServerLocator.socketPath("///tmp///conn/./server.sock/")
        #expect(normalized.value == "/tmp/conn/server.sock")
    }

    @Test("locator 解码时重新执行验证，不能从持久化数据注入无效配置")
    func locatorDecodeValidation() throws {
        let valid = try TmuxServerLocator.namedSocket("primary")
        let encoded = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(TmuxServerLocator.self, from: encoded) == valid)

        let invalid = Data(#"{"kind":"socketPath","value":"../escape"}"#.utf8)
        #expect(throws: TmuxIdentityError.self) {
            try JSONDecoder().decode(TmuxServerLocator.self, from: invalid)
        }
    }

    @Test("Session、Window、Pane ID 只接受各自前缀与十进制编号")
    func typedEntityIDs() throws {
        #expect(TmuxSessionID(rawValue: "$12")?.rawValue == "$12")
        #expect(TmuxWindowID(rawValue: "@34")?.rawValue == "@34")
        #expect(TmuxPaneID(rawValue: "%56")?.rawValue == "%56")

        #expect(TmuxSessionID(rawValue: "@12") == nil)
        #expect(TmuxWindowID(rawValue: "@-1") == nil)
        #expect(TmuxPaneID(rawValue: "%1x") == nil)
        #expect(TmuxPaneID(rawValue: "%") == nil)

        let session = try #require(TmuxSessionID(rawValue: "$12"))
        let roundTrip = try JSONDecoder().decode(
            TmuxSessionID.self,
            from: JSONEncoder().encode(session)
        )
        #expect(roundTrip == session)
    }

    @Test("server token 由 socket、PID 和启动时间共同确定并可持久化")
    func serverInstanceTokenScopeAndCoding() throws {
        let token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp//tmux-501/./default",
            serverPID: 321,
            serverStartTime: 1_765_000_000
        )
        let reusedPID = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux-501/default",
            serverPID: 321,
            serverStartTime: 1_765_000_001
        )
        let otherSocket = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux-501/other",
            serverPID: 321,
            serverStartTime: 1_765_000_000
        )

        #expect(token.resolvedSocketPath == "/tmp/tmux-501/default")
        #expect(token != reusedPID)
        #expect(token != otherSocket)
        #expect(try JSONDecoder().decode(
            TmuxServerInstanceToken.self,
            from: JSONEncoder().encode(token)
        ) == token)
    }

    @Test("server token 拒绝无效 socket、PID 与启动时间")
    func serverInstanceTokenValidation() {
        #expect(throws: TmuxIdentityError.self) {
            try TmuxServerInstanceToken(
                resolvedSocketPath: "relative",
                serverPID: 1,
                serverStartTime: 1
            )
        }
        #expect(throws: TmuxIdentityError.self) {
            try TmuxServerInstanceToken(
                resolvedSocketPath: "/tmp/tmux.sock",
                serverPID: 0,
                serverStartTime: 1
            )
        }
        #expect(throws: TmuxIdentityError.self) {
            try TmuxServerInstanceToken(
                resolvedSocketPath: "/tmp/tmux.sock",
                serverPID: 1,
                serverStartTime: 0
            )
        }
    }
}
