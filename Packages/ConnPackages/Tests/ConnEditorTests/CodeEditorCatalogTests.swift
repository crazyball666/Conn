import Testing
@testable import ConnEditor

struct CodeEditorCatalogTests {
    @Test("语言按扩展名/文件名推断")
    func languageDetection() {
        #expect(CodeEditorCatalog.language(forFileName: "deploy.sh") == "bash")
        #expect(CodeEditorCatalog.language(forFileName: "app.py") == "python")
        #expect(CodeEditorCatalog.language(forFileName: "config.yaml") == "yaml")
        #expect(CodeEditorCatalog.language(forFileName: "nginx.conf") == "nginx")
        #expect(CodeEditorCatalog.language(forFileName: "my.ini") == "ini")
        #expect(CodeEditorCatalog.language(forFileName: "data.json") == "json")
        #expect(CodeEditorCatalog.language(forFileName: "Dockerfile") == "dockerfile")
        #expect(CodeEditorCatalog.language(forFileName: "Makefile") == "makefile")
        #expect(CodeEditorCatalog.language(forFileName: "pass.txt") == "plaintext")
        #expect(CodeEditorCatalog.language(forFileName: "/etc/hosts") == "plaintext")
        #expect(CodeEditorCatalog.language(forFileName: "README.unknown") == "plaintext")
    }

    @Test("主题目录含默认项且可回退")
    func themes() {
        #expect(CodeEditorCatalog.themes.contains { $0.id == CodeEditorCatalog.defaultThemeID })
        #expect(CodeEditorCatalog.theme(id: "不存在").id == CodeEditorCatalog.themes[0].id)
        #expect(CodeEditorCatalog.theme(id: "dracula").isDark)
    }
}
