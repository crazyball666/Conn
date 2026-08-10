import Foundation
import Testing
@testable import ConnKit

@Suite("Snippet 变量解析")
struct SnippetTests {
    @Test("用户片段默认适用于全部平台且没有内置 key")
    func userSnippetDefaultsToUniversal() {
        let snippet = Snippet(title: "自定义", script: "uptime")

        #expect(snippet.platforms.isEmpty)
        #expect(snippet.requiredCapabilities.isEmpty)
        #expect(snippet.builtinKey == nil)
        #expect(snippet.isCompatible(with: .linux, availableCapabilities: []))
        #expect(snippet.isCompatible(with: .macOS, availableCapabilities: []))
        #expect(snippet.isCompatible(with: .windows, availableCapabilities: []))
    }

    @Test("旧版 JSON 缺少平台元数据时按全平台解码")
    func legacyJSONDefaultsToUniversal() throws {
        let json = """
        {
          "id":"legacy", "title":"旧片段", "script":"uptime", "interpreter":"sh",
          "groupIDs":[], "pinned":false, "danger":false, "sortOrder":0,
          "createdAt":1, "updatedAt":1, "syncDirty":false
        }
        """

        let snippet = try JSONDecoder().decode(Snippet.self, from: Data(json.utf8))

        #expect(snippet.platforms.isEmpty)
        #expect(snippet.requiredCapabilities.isEmpty)
        #expect(snippet.builtinKey == nil)
    }

    @Test("平台与能力共同决定内置片段兼容性")
    func evaluatesPlatformAndCapabilities() {
        let linux = Snippet(
            title: "服务", script: "systemctl status nginx", platforms: [.linux]
        )
        let docker = Snippet(
            title: "容器", script: "docker ps", requiredCapabilities: [.docker]
        )

        #expect(linux.isCompatible(with: .linux, availableCapabilities: []))
        #expect(!linux.isCompatible(with: .macOS, availableCapabilities: []))
        #expect(!docker.isCompatible(with: .macOS, availableCapabilities: []))
        #expect(docker.isCompatible(with: .macOS, availableCapabilities: [.docker]))
    }

    @Test("解析无默认值的变量")
    func parsesBareVariable() {
        let vars = Snippet.parseVariables(from: "systemctl restart {{service}}")
        #expect(vars == [Snippet.Variable(name: "service", defaultValue: nil)])
    }

    @Test("解析带默认值的变量")
    func parsesVariableWithDefault() {
        let vars = Snippet.parseVariables(from: "tail -n {{lines:200}} {{path}}")
        #expect(vars == [
            Snippet.Variable(name: "lines", defaultValue: "200"),
            Snippet.Variable(name: "path", defaultValue: nil)
        ])
    }

    @Test("同名变量只返回一次，保留首次出现的默认值")
    func deduplicatesByName() {
        let vars = Snippet.parseVariables(from: "cp {{f:/tmp/a}} /backup/{{f}}")
        #expect(vars == [Snippet.Variable(name: "f", defaultValue: "/tmp/a")])
    }

    @Test("转义的 \\{\\{ 不被当作变量")
    func ignoresEscapedBraces() {
        let vars = Snippet.parseVariables(from: #"docker ps --format '\{\{.Names\}\}'"#)
        #expect(vars.isEmpty)
    }

    @Test("Docker 的 {{json .}} 模板不会被误判为变量（含点号与空格）")
    func ignoresDockerGoTemplate() {
        #expect(Snippet.parseVariables(from: "docker ps -a --format '{{json .}}'").isEmpty)
        #expect(Snippet.parseVariables(from: "docker ps --format '{{.Names}}\t{{.Status}}'").isEmpty)
    }

    @Test("变量名只允许字母数字下划线，非法字符不匹配")
    func rejectsInvalidNames() {
        #expect(Snippet.parseVariables(from: "echo {{a-b}}").isEmpty)
        #expect(Snippet.parseVariables(from: "echo {{ }}").isEmpty)
    }

    @Test("填充变量值生成最终命令，缺省实参回退默认值")
    func rendersCommand() {
        let snippet = Snippet(title: "重启服务", script: "systemctl restart {{service}} --now={{now:yes}}")
        #expect(snippet.render(values: ["service": "nginx"]) == "systemctl restart nginx --now=yes")
    }

    @Test("variables 计算属性与 parseVariables 结果一致")
    func variablesPropertyMatchesParser() {
        let snippet = Snippet(title: "查日志", script: "tail -n {{lines:200}} {{path}}")
        #expect(snippet.variables == Snippet.parseVariables(from: snippet.script))
    }

    @Test("同名变量先出现无默认形式时，带默认的那处也被替换、不留占位符（#22）")
    func rendersMixedDefaultForms() {
        // {{x}} 先、{{x:hi}} 后：两处都要被替换成实参值，绝不能把 {{x:hi}} 原样留进命令
        let snippet = Snippet(title: "t", script: "echo {{x}} and {{x:hi}}")
        #expect(snippet.render(values: ["x": "V"]) == "echo V and V")
        // 关键：无论如何最终命令里都不能残留 {{ 占位符
        #expect(!snippet.render(values: [:]).contains("{{"))
        #expect(!snippet.render(values: ["x": "V"]).contains("{{"))
    }

    @Test("分组 id 的 JSON 往返无损")
    func groupIDsCodableRoundTrip() throws {
        let original = Snippet(title: "容器日志", script: "docker logs", interpreter: .bash, groupIDs: ["g-docker", "g-logs"])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)

        #expect(decoded == original)
    }

    @Test("脚本保留多行内容和解释器")
    func scriptKeepsMultilineAndInterpreter() {
        let snippet = Snippet(title: "健康检查", script: "hostname\nuptime", interpreter: .zsh)
        #expect(snippet.script.contains("\n"))
        #expect(snippet.interpreter == .zsh)
        let expected = "bash -c 'printf '\\''ok'\\''" + "\n'"
        #expect(ShellInterpreter.bash.invocation(for: "printf 'ok'\n") == expected)
    }
}
