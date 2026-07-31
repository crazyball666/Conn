import Foundation
import ConnSSH
import Testing
@testable import Conn

struct DockerLocalizationTests {
    @Test("Docker 文案在全部目标语言完成翻译，且 printf 占位符一致")
    func phase2DockerStringsAreTranslatedWithMatchingPlaceholders() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Conn/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        for key in phase2Keys {
            guard let entry = strings[key] as? [String: Any] else {
                Issue.record("缺少 Docker 文案：\(key)")
                continue
            }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]

            for locale in locales {
                guard
                    let localization = localizations[locale] as? [String: Any],
                    let unit = localization["stringUnit"] as? [String: Any],
                    unit["state"] as? String == "translated",
                    let value = unit["value"] as? String,
                    !value.isEmpty
                else {
                    Issue.record("\(key) 缺少 \(locale) 的已翻译 stringUnit")
                    continue
                }

                #expect(
                    printfPlaceholders(in: value) == printfPlaceholders(in: key),
                    "\(key) 的 \(locale) 译文 printf 占位符不匹配"
                )
            }
        }
    }

    @Test("Docker 本地化清单覆盖源码中的直接 L 调用")
    func phase2DockerAllowlistCoversLocalizedCallsInSource() throws {
        let usedKeys = try sourceLocalizedKeys()
        let missingKeys = usedKeys.subtracting(phase2Keys)

        #expect(missingKeys.isEmpty, "本地化清单遗漏 Docker 文案：\(missingKeys.sorted())")
    }

    @Test("第二期 Docker 演示命令提供成功、已知失败与未知终态夹具")
    func demoOperationsHaveDeterministicResponses() throws {
        let endpoint = SSHEndpoint(host: "demo.local", port: 22)
        let pull = try #require(DemoOps.response(command: "docker pull 'nginx:1.27'", endpoint: endpoint))
        let failedPull = try #require(DemoOps.response(
            command: "docker pull 'conn-demo/failing:latest'", endpoint: endpoint
        ))
        let interruptedPull = try #require(DemoOps.response(
            command: "docker pull 'conn-demo/interrupted:latest'", endpoint: endpoint
        ))

        #expect(pull.streamChunks?.count == 3)
        #expect(pull.exitCode == 0)
        #expect(failedPull.exitCode == 1)
        #expect(failedPull.stderr.contains("denied"))
        #expect(interruptedPull.streamFailure == .channelClosed)

        let writeCommands = [
            "docker run --detach 'nginx:1.27'",
            "docker volume create --driver 'local' 'demo-volume'",
            "docker volume rm 'demo-volume'",
            "docker network create --driver 'bridge' 'demo-network'",
            "docker network rm 'demo-network'",
            "docker system prune -f -a --volumes"
        ]
        for command in writeCommands {
            let response = try #require(DemoOps.response(command: command, endpoint: endpoint))
            #expect(response.exitCode == 0, "\(command) 应返回已知成功终态")
            #expect(!response.stdout.isEmpty, "\(command) 应返回可读演示输出")
        }
    }

    private let locales = ["en", "ja", "ko", "zh-Hant"]

    // Docker 源码 surface 的所有直接 L key；zh-Hans 是 catalog 的 sourceLanguage。
    private let phase2Keys = [
        "%@ 失败（退出码 %d）",
        "%@ 失败：%@",
        "%@ 成功",
        "%@ 结果未知",
        "%@容器",
        "Docker",
        "Docker Socket",
        "Docker 停止容器",
        "Docker 创建卷",
        "Docker 创建容器",
        "Docker 创建网络",
        "Docker 删除卷",
        "Docker 删除容器",
        "Docker 删除网络",
        "Docker 删除镜像",
        "Docker 启动容器",
        "Docker 当前不可用",
        "Docker 拉取镜像",
        "Docker 清理悬空镜像",
        "Docker 系统清理",
        "Docker 重启容器",
        "不设置",
        "不重启",
        "主机端口",
        "主机网络",
        "主机路径",
        "值",
        "停止",
        "具名卷",
        "内部网络",
        "创建",
        "创建卷",
        "创建容器",
        "创建网络",
        "删除",
        "删除卷",
        "删除网络",
        "删除镜像",
        "包含未使用卷",
        "协议",
        "卷",
        "卷配置无效，未执行 Docker 操作",
        "参数",
        "另一个 Docker 操作正在进行",
        "取消",
        "只读",
        "可附加",
        "名称",
        "后台运行",
        "启动",
        "启动命令",
        "基本",
        "复核配置",
        "失败时",
        "始终",
        "完成",
        "容器端口",
        "容器路径",
        "容器配置无效，未执行 Docker 操作",
        "拉取",
        "拉取完成",
        "拉取镜像",
        "拉取结果未知",
        "挂载",
        "无法保存拉取审计，未开始拉取",
        "有效配置",
        "根目录绑定",
        "正在拉取镜像",
        "添加参数",
        "添加挂载",
        "添加环境变量",
        "添加端口",
        "添加选项",
        "清理",
        "清理 Docker 资源",
        "清理悬空镜像",
        "清理范围",
        "默认将移除已停止容器、未使用网络、悬空镜像和构建缓存。",
        "特权容器",
        "环境变量",
        "确认 Docker 操作",
        "确认词",
        "确认词不匹配，未执行 Docker 操作",
        "移除所有未使用镜像",
        "端口",
        "等待远端输出…",
        "类型",
        "绑定挂载",
        "结果未知",
        "继续",
        "网络",
        "网络配置无效，未执行 Docker 操作",
        "请输入 %@ 以继续。",
        "返回",
        "选择卷",
        "选项",
        "重启",
        "重启策略",
        "镜像",
        "镜像引用",
        "镜像引用不能为空",
        "镜像操作",
        "除非手动停止",
        "驱动",
        "高级选项",
        "高风险配置",
        "；审计未保存",
        "Docker 守护进程未运行。\n请在服务器上启动：\nsudo systemctl start docker",
        "Docker 操作",
        "Docker 预置，不可删除",
        "主机",
        "作用域",
        "健康",
        "入口",
        "入口与命令",
        "共 %d 个",
        "共 %d 个卷",
        "共 %d 个网络",
        "共 %d 个镜像",
        "创建于",
        "刷新",
        "否",
        "启动于",
        "命令",
        "大小",
        "好",
        "子网",
        "容器",
        "容器 ID",
        "容器操作与片段执行会记录在这里",
        "层历史",
        "引用容器",
        "当前用户无权访问 Docker。\n将用户加入 docker 组：\nsudo usermod -aG docker $USER\n然后重新登录后重试。",
        "执行历史",
        "挂载点",
        "接入容器",
        "控制台",
        "搜索卷",
        "搜索容器",
        "搜索网络",
        "搜索镜像",
        "更多操作",
        "摘要",
        "日志",
        "是",
        "未使用",
        "未检测到 Docker CLI。请确认该服务器已安装 Docker。",
        "架构",
        "标签",
        "概要",
        "段",
        "没有匹配的卷",
        "没有匹配的容器",
        "没有匹配的网络",
        "没有匹配的镜像",
        "没有卷",
        "没有容器使用此镜像",
        "没有容器引用此卷",
        "没有容器接入此网络",
        "没有网络",
        "没有镜像",
        "状态",
        "网关",
        "网络 ID",
        "该主机上没有容器",
        "读取卷…",
        "读取容器…",
        "读取网络…",
        "读取详情…",
        "读取镜像…",
        "还没有执行记录",
        "重启次数",
        "重试",
        "镜像 ID",
        "预置",
        "%@ · %d 个服务 · %d/%d 个容器运行",
        "%d/%d 个容器运行",
        "Compose",
        "Compose 项目日志",
        "Compose 项目配置无效",
        "Docker Compose 停止项目",
        "Docker Compose 停止并移除项目",
        "Docker Compose 启动项目",
        "Docker Compose 重启服务",
        "Docker Compose 重启项目",
        "停止 Compose 项目",
        "停止并移除",
        "停止并移除 Compose 项目",
        "共 %d 个项目",
        "启动 Compose 项目",
        "将使用项目名称：%@",
        "已停止",
        "手动",
        "手动添加 Compose 项目",
        "手动添加项目",
        "搜索 Compose 项目",
        "操作",
        "无镜像",
        "未知",
        "服务",
        "未检测到 Docker Compose",
        "没有 Compose 项目",
        "没有匹配的 Compose 项目",
        "添加",
        "自动发现",
        "该项目没有服务",
        "读取 Compose 项目…",
        "读取服务…",
        "运行中",
        "部分运行",
        "配置文件",
        "配置文件必须使用服务器上的绝对路径。",
        "配置文件绝对路径",
        "重启 Compose 服务",
        "重启 Compose 项目",
        "项目名称",
        "项目名称（可选）",
        "项目目录",
        "项目目录（可选）",
        "项目配置",
        "从列表移除此手动项目",
        "只会从当前会话的项目列表移除，不会停止或删除服务器上的 Docker 资源。",
        "将移除该项目的容器和网络，但不会删除卷。项目配置会保留，之后可以再次启动。",
        "执行中…",
        "这是生产环境主机。该操作会影响正在运行的服务，请核对目标后再继续。",
        "移除",
        "移除手动项目？"
    ]

    private let phase2DockerSourceFiles = [
        "Conn/Commands/RunHistoryView.swift",
        "Conn/Hosts/ContainerDetailView.swift",
        "Conn/Hosts/DockerComposeModel.swift",
        "Conn/Hosts/DockerComposeManualFormView.swift",
        "Conn/Hosts/DockerComposeViews.swift",
        "Conn/Hosts/DockerDestructiveConfirmationView.swift",
        "Conn/Hosts/DockerOperationRouting.swift",
        "Conn/Hosts/DockerOperationFeedback.swift",
        "Conn/Hosts/DockerOperationTypes.swift",
        "Conn/Hosts/DockerOperationsModel.swift",
        "Conn/Hosts/DockerPullProgressView.swift",
        "Conn/Hosts/DockerResourceFormViews.swift",
        "Conn/Hosts/DockerRunFormView.swift",
        "Conn/Hosts/DockerRunReviewView.swift",
        "Conn/Hosts/DockerView.swift",
        "Conn/Hosts/ImageDetailView.swift",
        "Conn/Hosts/NetworkDetailView.swift",
        "Conn/Hosts/VolumeDetailView.swift"
    ]

    private func sourceLocalizedKeys() throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: #"\bL\(\s*\"((?:\\.|[^\"\\])*)\""#)

        return try phase2DockerSourceFiles.reduce(into: Set<String>()) { keys, relativePath in
            let source = try source(named: relativePath)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let capturedRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(unescapedSwiftStringLiteral(String(source[capturedRange])))
            }
        }
    }

    private func unescapedSwiftStringLiteral(_ literal: String) -> String {
        var result = ""
        var index = literal.startIndex

        while index < literal.endIndex {
            let character = literal[index]
            guard character == "\\" else {
                result.append(character)
                index = literal.index(after: index)
                continue
            }

            let escapedIndex = literal.index(after: index)
            guard escapedIndex < literal.endIndex else {
                result.append(character)
                break
            }

            switch literal[escapedIndex] {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\\", "\"": result.append(literal[escapedIndex])
            default:
                result.append(character)
                result.append(literal[escapedIndex])
            }
            index = literal.index(after: escapedIndex)
        }

        return result
    }

}

extension DockerLocalizationTests {
    @Test("五类 Docker 资源共用导航栏操作菜单，内容区只保留数量与列表")
    func resourceOperationsUseNavigationMenu() throws {
        let dockerView = try source(named: "Conn/Hosts/DockerView.swift")
        let routing = try source(named: "Conn/Hosts/DockerOperationRouting.swift")
        let runForm = try source(named: "Conn/Hosts/DockerRunFormView.swift")
        let runReview = try source(named: "Conn/Hosts/DockerRunReviewView.swift")
        let composeViews = try source(named: "Conn/Hosts/DockerComposeViews.swift")
        let detailBuilding = try source(named: "Conn/Hosts/DockerDetailBuilding.swift")

        #expect(dockerView.components(separatedBy: "DockerDetail.listHeader").count - 1 == 4)
        #expect(composeViews.components(separatedBy: "DockerDetail.listHeader").count - 1 == 1)
        #expect(!routing.contains("operationToolbar"))
        #expect(dockerView.contains("private var resourceOperationMenu"))
        #expect(dockerView.contains(".toolbar { resourceNavigationToolbar }"))
        #expect(dockerView.contains("L(\"共 %d 个\")"))
        #expect(!dockerView.contains("L(\"%@容器\")"))
        #expect(dockerView.contains("operationSheet = .runContainer"))
        #expect(dockerView.contains("operationSheet = .pullImage"))
        #expect(dockerView.contains("operationSheet = .createVolume"))
        #expect(dockerView.contains("operationSheet = .createNetwork"))
        #expect(dockerView.contains("operationSheet = .addComposeProject"))
        #expect(dockerView.contains("Label(L(\"手动添加项目\"), systemImage: \"plus\")"))
        #expect(!composeViews.contains("addManual"))
        #expect(composeViews.contains(".composeDown(project: project, dialect: dialect)"))
        #expect(composeViews.contains("kind: .compose(project: project, dialect: dialect, service: nil)"))
        #expect(runForm.contains("DockerRunReviewView(draft: state.draft, operations: operations)"))
        #expect(runReview.contains("DockerCommand.run(draft, sudo: false)"))
        #expect(runReview.contains("operations.runContainer(draft)"))
        #expect(!runForm.contains("maskedArguments"))
        #expect(!detailBuilding.contains("inlineActionButton"))
        #expect(!detailBuilding.contains("isMenuEnabled"))
        #expect(!detailBuilding.contains("hitExpansion"))
        #expect(!detailBuilding.contains(".padding(.vertical, -ConnSpacing.xs)"))
    }

    @Test("Docker 五类资源统一使用导航栏下方的系统搜索栏")
    func dockerResourcesUsePersistentSystemSearch() throws {
        let dockerView = try source(named: "Conn/Hosts/DockerView.swift")
        let composeViews = try source(named: "Conn/Hosts/DockerComposeViews.swift")
        let detailBuilding = try source(named: "Conn/Hosts/DockerDetailBuilding.swift")

        #expect(dockerView.contains("placement: .navigationBarDrawer(displayMode: .always)"))
        #expect(dockerView.contains("prompt: searchPrompt"))
        #expect(dockerView.contains("private var searchPrompt: String"))
        #expect(dockerView.contains("case .containers: L(\"搜索容器\")"))
        #expect(dockerView.contains("case .images: L(\"搜索镜像\")"))
        #expect(dockerView.contains("case .volumes: L(\"搜索卷\")"))
        #expect(dockerView.contains("case .networks: L(\"搜索网络\")"))
        #expect(dockerView.contains("case .compose: L(\"搜索 Compose 项目\")"))
        #expect(!detailBuilding.contains("static func listControls("))
        #expect(!detailBuilding.contains("ConnSearchField("))
        #expect(!composeViews.contains("searchPrompt:"))
    }

    @Test("容器与 Compose 详情共用同一操作卡片样式")
    func dockerDetailsUseSharedActionButtons() throws {
        let containerDetail = try source(named: "Conn/Hosts/ContainerDetailView.swift")
        let composeViews = try source(named: "Conn/Hosts/DockerComposeViews.swift")
        let detailBuilding = try source(named: "Conn/Hosts/DockerDetailBuilding.swift")

        #expect(detailBuilding.contains("static func actionButton("))
        #expect(containerDetail.contains("DockerDetail.actionButton("))
        #expect(
            composeViews.components(separatedBy: "DockerDetail.actionButton(").count - 1 == 4
        )
        #expect(composeViews.contains("actions\n                summary\n                servicesSection"))
        #expect(!composeViews.contains("PillButton(L(\"启动\")"))
    }

    @Test("Compose 单容器服务直达详情且多副本在项目页就地展开")
    func composeServiceRowsNavigateOrExpandContainers() throws {
        let composeViews = try source(named: "Conn/Hosts/DockerComposeViews.swift")

        #expect(composeViews.contains("@State private var openedContainer: ContainerInfo?"))
        #expect(composeViews.contains("@State private var expandedServiceIDs: Set<String>"))
        #expect(composeViews.contains("service.containers.count == 1"))
        #expect(composeViews.contains("toggleServiceExpansion(service)"))
        #expect(composeViews.contains("expandedContainers(for: service)"))
        #expect(composeViews.contains("ContainerDetailView("))
        #expect(composeViews.contains("Button { open(service) }"))
        #expect(!composeViews.contains("serviceMenu("))
        #expect(!composeViews.contains("ConnMoreActionsIcon()"))
        #expect(!composeViews.contains("DockerComposeServiceContainersView"))
        #expect(!composeViews.contains("openedService"))
    }

    @Test("Compose 详情仅首次进入加载服务，返回时复用现有列表")
    func composeDetailLoadsServicesOnlyOnce() throws {
        let composeViews = try source(named: "Conn/Hosts/DockerComposeViews.swift")

        #expect(composeViews.contains("@State private var hasLoadedServices = false"))
        #expect(composeViews.contains(".task { await loadServicesIfNeeded() }"))
        #expect(composeViews.contains("guard !hasLoadedServices else { return }"))
        #expect(composeViews.contains("hasLoadedServices = true"))
        #expect(!composeViews.contains(".task { await loadServices() }"))
    }

    @Test("Docker 资源通过标题菜单切换并分别保存搜索词")
    func dockerResourcesUseTitleMenuAndIndependentSearches() throws {
        let dockerView = try source(named: "Conn/Hosts/DockerView.swift")

        #expect(!dockerView.contains("Picker(L(\"段\"), selection: $tab)"))
        #expect(dockerView.contains("private var resourceTitleMenu"))
        #expect(dockerView.contains("Label(L(target.rawValue), systemImage:"))
        #expect(!dockerView.contains("resourceMenuLabel"))
        #expect(!dockerView.contains("resourceCount"))
        #expect(dockerView.contains("@State private var searches: [Tab: String] = [:]"))
        #expect(dockerView.contains("private var searchBinding: Binding<String>"))
        #expect(!dockerView.contains("search = \"\""))
    }

    private func source(named relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectURL.appending(path: relativePath), encoding: .utf8)
    }

    private func printfPlaceholders(in string: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"%(?:\d+\$)?[@d]"#) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return expression.matches(in: string, range: range)
            .compactMap { Range($0.range, in: string).map { String(string[$0]) } }
            .map { String($0.suffix(1)) }
            .sorted()
    }
}
