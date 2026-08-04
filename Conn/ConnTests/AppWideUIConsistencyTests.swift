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

    @Test("根 Tab 使用脚本文案，脚本执行默认不选主机且按钮状态统一")
    func scriptTabAndRunActionsUseConsistentState() throws {
        let dock = try packageSource("Sources/ConnUI/Components/ConnDock.swift")
        let runView = try appSource("Commands/SnippetRunView.swift")
        let button = try packageSource("Sources/ConnUI/Components/ConnButton.swift")

        #expect(dock.contains("case .commands: \"脚本\""))
        #expect(!runView.contains("if selectedHostIDs.isEmpty, let first = hosts.first"))
        #expect(runView.contains("ConnButton(L(\"执行脚本\"), kind: .primary)"))
        #expect(runView.contains("ConnButton(L(\"进终端\"), kind: .primary)"))
        #expect(runView.contains(".disabled(selectedHosts.isEmpty || isRunning)"))
        #expect(runView.contains(".disabled(selectedHosts.count != 1 || isRunning)"))
        #expect(button.contains("@Environment(\\.isEnabled)"))
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

    @Test("终端会话列表项整行空白区域也能点击")
    func terminalSessionRowsMakeEntireRowInteractive() throws {
        for path in [
            "Terminal/TerminalSessionCenterView.swift",
            "Terminal/TerminalSessionListSheet.swift",
        ] {
            let source = try appSource(path)
            #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
            #expect(source.contains(".contentShape(Rectangle())"))
        }
    }

    @Test("终端选择主机与会话操作列表整行可点击")
    func terminalHostPickerRowsMakeEntireRowInteractive() throws {
        let source = try appSource("Terminal/TerminalSessionCenterView.swift")
        #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(source.contains(".contentShape(Rectangle())"))
        #expect(source.contains("Button { onOpen(tab.id) } label:"))
    }

    @Test("终端导航栏主标题显示主机，会话名显示副标题")
    func terminalNavigationUsesHostTitleAndSessionSubtitle() throws {
        let source = try appSource("Terminal/TerminalScreen.swift")
        #expect(source.contains(".navigationTitle(hostTitle)"))
        #expect(source.contains("Text(hostTitle)"))
        #expect(source.contains("Text(sessionSubtitle)"))
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

    @Test("主机登录密码支持显示与隐藏切换")
    func hostPasswordCanToggleVisibility() throws {
        let hostForm = try appSource("Hosts/HostFormView.swift")

        #expect(hostForm.contains("@State private var isPasswordVisible = false"))
        #expect(hostForm.contains("isPasswordVisible.toggle()"))
        #expect(hostForm.contains("SecureField(L(\"选填\"), text: text)"))
        #expect(hostForm.contains("TextField(L(\"选填\"), text: text)"))
        #expect(hostForm.contains("L(\"显示密码\")"))
        #expect(hostForm.contains("L(\"隐藏密码\")"))
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

    @Test("服务器卡片的内存和磁盘显示已用与总量")
    func serverCardsShowUsedAndTotalStorage() throws {
        let source = try appSource("Servers/ServersViewModel.swift")
        let healthCard = try packageSource("Sources/ConnUI/Components/HealthCard.swift")

        #expect(source.contains("memTotalText: MetricFormat.compactPair(used: metrics?.memUsedBytes, total: metrics?.memTotalBytes)"))
        #expect(source.contains("diskTotalText: MetricFormat.compactPair(used: metrics?.diskUsedBytes, total: metrics?.diskTotalBytes)"))
        #expect(!source.contains("memTotalText: MetricFormat.pair(used: metrics?.memUsedBytes, total: metrics?.memTotalBytes)"))
        #expect(!source.contains("diskTotalText: MetricFormat.pair(used: metrics?.diskUsedBytes, total: metrics?.diskTotalBytes)"))
        #expect(healthCard.contains("VStack(alignment: .center, spacing: 3)"))
        #expect(healthCard.contains(".frame(maxWidth: .infinity, alignment: .center)"))
        #expect(healthCard.contains(".multilineTextAlignment(.center)"))
    }

    @Test("Swap 只显示用量摘要和进度条，不采集独立趋势")
    func swapUsesCompactSummaryWithoutTrendChart() throws {
        let view = try appSource("Hosts/HostOverviewView.swift")
        let viewModel = try appSource("Hosts/HostOverviewViewModel.swift")

        #expect(view.contains("private var swapSummary"))
        #expect(view.contains("ConnLoadBar(percent: percent"))
        #expect(!view.contains("viewModel.swapUsedHistory"))
        #expect(!view.contains("hasSwapHistory"))
        #expect(!viewModel.contains("swapUsedHistory"))
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

    private func packageSource(_ relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectURL.appending(path: "Packages/ConnPackages/\(relativePath)"),
            encoding: .utf8
        )
    }
}
