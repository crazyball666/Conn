import ConnMonitor
import Testing

@Suite("macOS 运行时长采集脚本")
struct DarwinUptimeScriptRegressionTests {
    @Test("启动时间表达式锚定 sec 字段")
    func bootTimeExtractionDoesNotMatchMicroseconds() {
        let command = DarwinCollectionScript.command()

        #expect(command.contains("s/^\\{[[:space:]]*sec"))
        #expect(!command.contains("s/.*sec ="))
    }
}
