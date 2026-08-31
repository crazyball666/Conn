import Testing
@testable import ConnTerminal

@Suite("TerminalWorkingDirectory — 终端目录解析")
struct TerminalWorkingDirectoryTests {
    @Test("解析 OSC 7 file URL、主机名和编码路径")
    func parsesOSC7FileURLs() {
        #expect(
            TerminalWorkingDirectoryPath.osc7Path(from: "file:///home/demo/app/")
                == "/home/demo/app"
        )
        #expect(
            TerminalWorkingDirectoryPath.osc7Path(from: "FILE://server/home/demo/app")
                == "/home/demo/app"
        )
        #expect(
            TerminalWorkingDirectoryPath.osc7Path(from: "file:///home/demo/My%20App?ignored=1#ignored")
                == "/home/demo/My App"
        )
    }

    @Test("拒绝不安全的 OSC 7 和 provider 路径")
    func rejectsUnsafePaths() {
        let invalidOSC7 = [
            "ssh:///home/demo",
            "file:relative/path",
            "file:///home/demo/%ZZ",
            "file:///home/demo/%00x",
            "file:///home/demo/%0A",
            "file:///home/demo/%7F",
            "file:///home/demo/./app",
            "file:///home/demo/../app",
            "file:///home/demo//app",
            "file:///home/demo/\u{0000}"
        ]
        for value in invalidOSC7 {
            #expect(TerminalWorkingDirectoryPath.osc7Path(from: value) == nil)
        }

        let invalidProvider = [
            "home/demo",
            "/home/demo/../app",
            "/home/demo//app",
            "/home/demo/%ZZ",
            "/home/demo/\u{0000}"
        ]
        for value in invalidProvider {
            #expect(TerminalWorkingDirectoryPath.providerPath(from: value) == nil)
        }
        #expect(TerminalWorkingDirectoryPath.providerPath(from: "/home/demo/app/") == "/home/demo/app")
        #expect(TerminalWorkingDirectoryPath.providerPath(from: "/") == "/")
    }

    @Test("provider 优先于 OSC 7，provider 失效后回退 OSC 7")
    func resolvesProviderBeforeOSC7() {
        var resolver = TerminalWorkingDirectoryResolver()

        resolver.update(source: .osc7, generation: 4, path: "/shell/path")
        #expect(resolver.effectivePath == "/shell/path")

        resolver.update(source: .provider, generation: 4, path: "/tmux/path")
        #expect(resolver.effectivePath == "/tmux/path")

        resolver.update(source: .provider, generation: 4, path: nil)
        #expect(resolver.effectivePath == "/shell/path")
    }

    @Test("代际变化清空旧目录，旧代际回调不能污染新目录")
    func invalidatesOldGeneration() {
        var resolver = TerminalWorkingDirectoryResolver()
        resolver.update(source: .provider, generation: 1, path: "/old/provider")
        resolver.update(source: .osc7, generation: 1, path: "/old/shell")

        resolver.synchronize(generation: 2)
        #expect(resolver.effectivePath == nil)

        resolver.update(source: .osc7, generation: 1, path: "/stale")
        #expect(resolver.effectivePath == nil)

        resolver.update(source: .osc7, generation: 2, path: "/new/shell")
        #expect(resolver.effectivePath == "/new/shell")
    }

    @Test("不同 resolver 实例保持 tab 隔离")
    func keepsTabsIsolated() {
        var first = TerminalWorkingDirectoryResolver()
        var second = TerminalWorkingDirectoryResolver()

        first.update(source: .osc7, generation: 1, path: "/first")
        second.update(source: .osc7, generation: 1, path: "/second")

        #expect(first.effectivePath == "/first")
        #expect(second.effectivePath == "/second")
    }
}
