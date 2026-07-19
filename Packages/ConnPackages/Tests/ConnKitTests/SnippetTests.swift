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
            Snippet.Variable(name: "path", defaultValue: nil),
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
}
