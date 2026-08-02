import Foundation
import Testing

struct AppWideUIConsistencyTests {
    @Test("命令页不再使用命令与分组的嵌套分段")
    func snippetsUsesFocusedListAndGroupDestination() throws {
        let source = try appSource("Commands/SnippetsView.swift")

        #expect(!source.contains("SnippetsPage"))
        #expect(!source.contains("pagePicker"))
        #expect(!source.contains(".pickerStyle(.segmented)"))
        #expect(source.contains("isGroupsPresented"))
        #expect(source.contains(".navigationDestination(isPresented: $isGroupsPresented)"))
        #expect(source.contains("Label(L(\"管理分组\")"))
    }

    @Test("管理分组页自己承载分组弹窗并居中空状态")
    func snippetGroupsOwnPresentationAndCenteredEmptyState() throws {
        let source = try appSource("Commands/SnippetsView.swift")

        #expect(source.contains("private var groupsPage: some View {\n        GeometryReader"))
        #expect(source.contains("isNewGroupPresented: $isGroupsNewGroupPresented"))
        #expect(source.contains(".frame(minHeight: geometry.size.height)"))
    }

    @Test("连接失败页面统一使用设计系统重试组件")
    func featureFailuresUseSharedRetryState() throws {
        let paths = [
            "Hosts/ProcessListView.swift",
            "Files/FileBrowserView.swift",
            "Files/DirectoryPickerView.swift",
            "Hosts/LogCenterView.swift",
            "Hosts/DockerView.swift",
            "Hosts/DockerComposeViews.swift",
            "Hosts/DockerDetailBuilding.swift",
        ]

        for path in paths {
            #expect(try appSource(path).contains("ConnRetryState("), "\(path) 尚未接入统一错误重试组件")
        }
    }

    @Test("命令与分组列表项使用长按操作和更高卡片行")
    func snippetRowsUseLongPressActionsAndTallerCards() throws {
        let source = try appSource("Commands/SnippetsView.swift")

        #expect(!source.contains("ConnMoreActionsIcon()"))
        #expect(source.components(separatedBy: ".contextMenu").count >= 3)
        #expect(source.components(separatedBy: ".padding(.vertical, ConnSpacing.md)").count >= 3)
    }

    @Test("命令与分组列表项长按整行空白区域也能触发操作")
    func snippetRowsMakeEntireCardInteractive() throws {
        let source = try appSource("Commands/SnippetsView.swift")

        #expect(source.components(separatedBy: ".contentShape(Rectangle())").count >= 3)
    }

    @Test("创建 Docker 命令保存成功后锁定按钮并防止重复保存")
    func dockerCommandSaveLocksAfterSuccess() throws {
        let runForm = try appSource("Hosts/DockerRunFormView.swift")
        let resourceForms = try appSource("Hosts/DockerResourceFormViews.swift")

        for source in [runForm, resourceForms] {
            #expect(source.contains("@State private var isCommandSaved = false"))
            #expect(source.contains(".disabled(!state.isValid || isCommandSaved)"))
            #expect(source.contains("guard !isCommandSaved else { return }"))
            #expect(source.contains("isCommandSaved = true"))
        }
        #expect(runForm.contains("try onSave(title, command)"))
        #expect(resourceForms.contains("try onSave(title, previewCommand)"))
    }

    @Test("密钥详情支持重命名并同步保存")
    func keyDetailsCanRename() throws {
        let view = try appSource("Keys/KeyManagerView.swift")
        let viewModel = try appSource("Keys/KeyManagerViewModel.swift")

        #expect(view.contains("重命名"))
        #expect(view.contains("isRenamePresented"))
        #expect(viewModel.contains("func rename"))
    }

    @Test("主机认证只提供密码与密钥，密钥管家使用导航栏新增")
    func sshAuthAndKeyManagerUseCurrentDesign() throws {
        let hostForm = try appSource("Hosts/HostFormView.swift")
        let keyManager = try appSource("Keys/KeyManagerView.swift")
        #expect(!hostForm.contains("keyPassphrase"))
        #expect(!hostForm.contains("密码短语"))
        #expect(keyManager.contains("ToolbarItem(placement: .topBarTrailing)"))
        #expect(keyManager.contains("ForEach(SSHKey.Kind.allCases"))
        #expect(keyManager.contains("导入私钥"))
    }

    @Test("服务器和命令表单的分组选择默认收起")
    func groupSelectionFormsUseCollapsedDisclosureGroups() throws {
        let hostForm = try appSource("Hosts/HostFormView.swift")
        let snippetForm = try appSource("Commands/SnippetFormView.swift")

        #expect(hostForm.contains("@State private var isGroupExpanded = false"))
        #expect(hostForm.contains("DisclosureGroup(isExpanded: $isGroupExpanded)"))
        #expect(snippetForm.contains("@State private var isGroupsExpanded = false"))
        #expect(snippetForm.contains("DisclosureGroup(isExpanded: $isGroupsExpanded)"))
    }

    @Test("服务器首页在短列表和空列表时仍可下拉刷新")
    func serverHomeAlwaysSupportsPullToRefresh() throws {
        let source = try appSource("Servers/ServersView.swift")

        #expect(
            source.contains(
                "private var hostsContent: some View {\n        ScrollView {\n            if viewModel.hosts.isEmpty {"
            )
        )
        #expect(source.contains(".containerRelativeFrame(.vertical)"))
        #expect(source.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
        #expect(source.contains(".refreshable { await viewModel.refresh() }"))
        #expect(!source.contains(".scrollBounceBehavior(.basedOnSize)"))
    }

    @Test("文件管理页使用导航栏下方固定系统搜索")
    func fileBrowserUsesPersistentNavigationSearch() throws {
        let source = try appSource("Files/FileBrowserView.swift")

        #expect(source.contains("placement: .navigationBarDrawer(displayMode: .always)"))
        #expect(source.contains("prompt: L(\"搜索当前目录\")"))
        #expect(!source.contains("ConnSearchField(L(\"搜索当前目录\")"))
        #expect(!source.contains("private var searchField"))
    }

    @Test("文件管理操作移至导航栏并替代终端入口")
    func fileBrowserUsesNavigationActionsWithoutTerminal() throws {
        let fileBrowser = try appSource("Files/FileBrowserView.swift")
        let hostDetail = try appSource("Hosts/HostDetailView.swift")

        #expect(fileBrowser.contains(".toolbar { fileActionsToolbar }"))
        #expect(fileBrowser.contains("private var fileActionsToolbar: some ToolbarContent"))
        #expect(fileBrowser.contains("ToolbarItem(placement: .topBarTrailing)"))
        #expect(fileBrowser.contains("Image(systemName: \"ellipsis.circle\")"))
        #expect(!fileBrowser.contains("ConnMoreActionsIcon()"))
        #expect(hostDetail.contains("case .files:\n            modulePage(showsTerminal: false)"))
    }

    @Test("进程列表使用导航栏下方固定系统搜索")
    func processListUsesPersistentNavigationSearch() throws {
        let source = try appSource("Hosts/ProcessListView.swift")

        #expect(source.contains("placement: .navigationBarDrawer(displayMode: .always)"))
        #expect(source.contains("prompt: L(\"搜索进程 / PID / 用户\")"))
        #expect(!source.contains("ConnSearchField(L(\"搜索进程 / PID / 用户\")"))
        #expect(!source.contains("private var searchField"))
    }

    @Test("模块整页失败统一走恢复加载而非静默刷新")
    func featureFailureRetriesUseRecoveryLoads() throws {
        let cases = [
            ("Hosts/ProcessListView.swift", "await viewModel.retryProcesses()"),
            ("Files/FileBrowserView.swift", "await viewModel.load()"),
            ("Hosts/DockerView.swift", "await viewModel.load()"),
            ("Hosts/LogCenterView.swift", "await viewModel.load()"),
        ]

        for (path, expectedAction) in cases {
            let block = try failureBlock(in: appSource(path))
            #expect(block.contains("ConnRetryState("), "\(path) 未使用统一错误状态")
            #expect(block.contains(expectedAction), "\(path) 的重试没有执行恢复加载")
        }

        let fileBlock = try failureBlock(in: appSource("Files/FileBrowserView.swift"))
        #expect(!fileBlock.contains("viewModel.refresh()"), "文件整页失败不能走仅适用于已有列表的静默刷新")
    }

    @Test("文件与日志子页面失败同样提供内联恢复入口")
    func fileAndLogDetailFailuresAreRecoverableInline() throws {
        let editor = try appSource("Files/FileEditorView.swift")
        #expect(editor.contains("ConnRetryState(message, retryTitle: L(\"重试\"))"))
        #expect(editor.contains("Task { await viewModel.load() }"))
        #expect(editor.contains("cachedFileSystem = nil"), "文件读取失败后必须丢弃可能已坏的 SFTP 通道")

        let logView = try appSource("Hosts/LogStreamView.swift")
        let logModel = try appSource("Hosts/LogStreamViewModel.swift")
        #expect(logView.contains("ConnRetryState(error, retryTitle: L(\"重试\"))"))
        #expect(logView.contains("viewModel.retry()"))
        #expect(logModel.contains("func retry()"))
        #expect(logModel.contains("stop()\n        start()"))
    }

    @Test("目录选择器失败后丢弃旧 SFTP 通道再重试")
    func directoryPickerDropsFailedFileSystem() throws {
        let source = try appSource("Files/DirectoryPickerView.swift")
        #expect(source.contains(
            "        } catch {\n            fileSystem = nil\n            errorText = error.friendlyDiagnosis"
        ))
    }

    private func failureBlock(in source: String) throws -> String {
        let start = try #require(source.range(of: "case let .failed(message):"))
        let end = try #require(source.range(of: "case .ready:", range: start.upperBound ..< source.endIndex))
        return String(source[start.lowerBound ..< end.lowerBound])
    }

    private func appSource(_ relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectURL.appending(path: "Conn/\(relativePath)"),
            encoding: .utf8
        )
    }
}
