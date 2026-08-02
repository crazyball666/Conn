import Foundation
import Testing

@Suite("Docker 创建表单左滑删除")
struct DockerFormSwipeDeleteTests {
    @Test("容器重复行使用原生左滑删除，资源表单使用多行高级参数")
    func repeatableRowsUseNativeSwipeDelete() throws {
        let runForm = try source(named: "Conn/Hosts/DockerRunFormView.swift")
        let resourceForms = try source(named: "Conn/Hosts/DockerResourceFormViews.swift")

        // run form 现在的「高级选项」是多行 TextArea（不是行列表），自然没有 onDelete；
        // 实际可追加行 = 端口 / 环境变量 / 挂载 / 启动命令，共 4 个 onDelete。
        #expect(runForm.components(separatedBy: ".onDelete").count - 1 == 4)
        #expect(runForm.contains("state.ports.remove(atOffsets: offsets)"))
        #expect(runForm.contains("state.environment.remove(atOffsets: offsets)"))
        #expect(runForm.contains("state.mounts.remove(atOffsets: offsets)"))
        #expect(runForm.contains("state.command.remove(atOffsets: offsets)"))
        #expect(runForm.contains("parseOtherOptions"))
        #expect(!runForm.contains("minus.circle"))

        #expect(resourceForms.contains("TextEditor(text: $state.otherOptionsText)"))
        #expect(!resourceForms.contains("tokenSection"))
        #expect(!resourceForms.contains(".onDelete"))
        #expect(!resourceForms.contains("minus.circle"))
    }

    @Test("端口和挂载与环境变量一样可展开收起且不显示即时完善提示")
    func optionalSectionsUseDisclosureGroups() throws {
        let runForm = try source(named: "Conn/Hosts/DockerRunFormView.swift")

        #expect(runForm.contains("@State private var isPortsExpanded = true"))
        #expect(runForm.contains("@State private var isMountsExpanded = true"))
        #expect(runForm.contains("@State private var isCommandExpanded = true"))
        #expect(runForm.contains("DisclosureGroup(isExpanded: $isPortsExpanded)"))
        #expect(runForm.contains("DisclosureGroup(isExpanded: $isMountsExpanded)"))
        #expect(runForm.contains("DisclosureGroup(isExpanded: $isCommandExpanded)"))
        #expect(!runForm.contains("validationSection"))
        #expect(!runForm.contains("需要完善"))

        let advancedIndex = try #require(runForm.range(of: "                advancedSection"))
        let commandIndex = try #require(runForm.range(of: "                commandSection"))
        #expect(advancedIndex.lowerBound < commandIndex.lowerBound)
    }

    private func source(named relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectURL.appending(path: relativePath), encoding: .utf8)
    }
}
