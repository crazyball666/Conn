import Foundation
import Testing

@Suite("Docker 创建表单左滑删除")
struct DockerFormSwipeDeleteTests {
    @Test("全部可追加行使用原生左滑删除且不显示行尾减号")
    func repeatableRowsUseNativeSwipeDelete() throws {
        let runForm = try source(named: "Conn/Hosts/DockerRunFormView.swift")
        let resourceForms = try source(named: "Conn/Hosts/DockerResourceFormViews.swift")

        #expect(runForm.components(separatedBy: ".onDelete").count - 1 == 5)
        #expect(runForm.contains("state.ports.remove(atOffsets: offsets)"))
        #expect(runForm.contains("state.environment.remove(atOffsets: offsets)"))
        #expect(runForm.contains("state.mounts.remove(atOffsets: offsets)"))
        #expect(runForm.contains("state.otherOptions.remove(atOffsets: offsets)"))
        #expect(runForm.contains("state.command.remove(atOffsets: offsets)"))
        #expect(!runForm.contains("minus.circle"))

        #expect(resourceForms.contains(".onDelete"))
        #expect(resourceForms.contains("rows.wrappedValue.remove(atOffsets: offsets)"))
        #expect(!resourceForms.contains("minus.circle"))
    }

    private func source(named relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectURL.appending(path: relativePath), encoding: .utf8)
    }
}
