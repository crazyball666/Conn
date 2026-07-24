import Foundation
import Testing
@testable import ConnKit

@Suite("Snippet 变量解析")
struct SnippetTests {
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
        let snippet = Snippet(title: "重启服务", command: "systemctl restart {{service}} --now={{now:yes}}")
        #expect(snippet.render(values: ["service": "nginx"]) == "systemctl restart nginx --now=yes")
    }

    @Test("variables 计算属性与 parseVariables 结果一致")
    func variablesPropertyMatchesParser() {
        let snippet = Snippet(title: "查日志", command: "tail -n {{lines:200}} {{path}}")
        #expect(snippet.variables == Snippet.parseVariables(from: snippet.command))
    }

    @Test("同名变量先出现无默认形式时，带默认的那处也被替换、不留占位符（#22）")
    func rendersMixedDefaultForms() {
        // {{x}} 先、{{x:hi}} 后：两处都要被替换成实参值，绝不能把 {{x:hi}} 原样留进命令
        let snippet = Snippet(title: "t", command: "echo {{x}} and {{x:hi}}")
        #expect(snippet.render(values: ["x": "V"]) == "echo V and V")
        // 关键：无论如何最终命令里都不能残留 {{ 占位符
        #expect(!snippet.render(values: [:]).contains("{{"))
        #expect(!snippet.render(values: ["x": "V"]).contains("{{"))
    }
}
