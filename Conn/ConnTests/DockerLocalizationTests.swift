import Foundation
import ConnSSH
import Testing
@testable import Conn

struct DockerLocalizationTests {
    @Test("第二期 Docker 文案在全部目标语言完成翻译，且 printf 占位符一致")
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
                Issue.record("缺少第二期 Docker 文案：\(key)")
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

    @Test("第二期 Docker 本地化清单覆盖源码中的直接 L 调用")
    func phase2DockerAllowlistCoversLocalizedCallsInSource() throws {
        let usedKeys = try sourceLocalizedKeys()
        let missingKeys = usedKeys.subtracting(phase2Keys)

        #expect(missingKeys.isEmpty, "本地化清单遗漏第二期 Docker 文案：\(missingKeys.sorted())")
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

    // 所有第二期 Docker 写操作引入的用户可见 L key；zh-Hans 是 catalog 的 sourceLanguage。
    private let phase2Keys = [
        "%@ 失败（退出码 %d）",
        "%@ 成功",
        "%@ 结果未知",
        "%@容器",
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
        "；审计未保存"
    ]

    private let phase2DockerSourceFiles = [
        "Conn/Hosts/DockerDestructiveConfirmationView.swift",
        "Conn/Hosts/DockerOperationRouting.swift",
        "Conn/Hosts/DockerOperationTypes.swift",
        "Conn/Hosts/DockerOperationsModel.swift",
        "Conn/Hosts/DockerPullProgressView.swift",
        "Conn/Hosts/DockerResourceFormViews.swift",
        "Conn/Hosts/DockerRunFormView.swift"
    ]

    private func sourceLocalizedKeys() throws -> Set<String> {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expression = try NSRegularExpression(pattern: #"\bL\(\s*\"((?:\\.|[^\"\\])*)\""#)

        return try phase2DockerSourceFiles.reduce(into: Set<String>()) { keys, relativePath in
            let source = try String(contentsOf: projectURL.appending(path: relativePath), encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let capturedRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[capturedRange]))
            }
        }
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
