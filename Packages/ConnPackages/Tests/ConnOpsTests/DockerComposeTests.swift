import Testing
@testable import ConnOps

@Suite("Docker Compose 第三期")
struct DockerComposeTests {
    @Test("Compose 命令失败向界面暴露远端原因而非 Swift 类型名")
    func commandFailureHasReadableLocalizedDescription() {
        let error = DockerComposeError.commandFailed(
            exitCode: 17,
            message: "daemon unavailable"
        )

        #expect(error.localizedDescription == "daemon unavailable")
        #expect(
            DockerComposeError.commandFailed(exitCode: 17, message: "").localizedDescription
                == "Docker Compose 命令失败（退出码 17）"
        )
    }

    @Test("手动项目校验绝对路径并规范化默认项目名")
    func validatesManualProjectAndNormalizesDefaultName() {
        let valid = DockerComposeManualDraft(
            configFile: "/srv/My App/compose.yml",
            projectDirectory: "/srv/My App"
        )
        let relative = DockerComposeManualDraft(configFile: "compose.yml")
        let invalidName = DockerComposeManualDraft(
            configFile: "/srv/app/compose.yml",
            projectName: "Bad Project"
        )

        #expect(valid.validate().isEmpty)
        #expect(valid.project?.name == "my-app")
        #expect(valid.project?.projectDirectory == "/srv/My App")
        #expect(relative.validate() == [.configFileMustBeAbsolute])
        #expect(invalidName.validate() == [.invalidProjectName("Bad Project")])
        #expect(DockerComposeManualDraft.normalizedProjectName(" 中文 App !! ") == "app")
        #expect(DockerComposeManualDraft.normalizedProjectName("___") == "compose")
    }

    @Test("v2 与 v1 命令使用相同项目上下文并逐个引用动态参数")
    func buildsDialectSpecificCommandsWithQuotedContext() {
        let project = DockerComposeProject(
            name: "web;$(id)",
            state: .running,
            configFiles: ["/srv/web app/compose.yml", "/srv/common/override.yml"],
            projectDirectory: "/srv/web app",
            source: .automatic
        )

        #expect(DockerCommand.composeVersion(.v2, sudo: false) == "docker compose version")
        #expect(DockerCommand.composeVersion(.v1, sudo: true) == "sudo -n docker-compose version")
        #expect(DockerCommand.composeProjects(sudo: true) == "sudo -n docker compose ls --all --format json")
        #expect(
            DockerCommand.composeUp(project, dialect: .v2, sudo: true)
                == "sudo -n docker compose -f '/srv/web app/compose.yml' -f '/srv/common/override.yml' --project-directory '/srv/web app' -p 'web;$(id)' up -d"
        )
        #expect(
            DockerCommand.composeDown(project, dialect: .v1, sudo: false)
                == "docker-compose -f '/srv/web app/compose.yml' -f '/srv/common/override.yml' --project-directory '/srv/web app' -p 'web;$(id)' down"
        )
        #expect(!DockerCommand.composeDown(project, dialect: .v1, sudo: false).contains("--volumes"))
        #expect(
            DockerCommand.composeRestart(project, service: "api; reboot", dialect: .v2, sudo: false)
                == "docker compose -f '/srv/web app/compose.yml' -f '/srv/common/override.yml' --project-directory '/srv/web app' -p 'web;$(id)' restart 'api; reboot'"
        )
        #expect(
            DockerCommand.composeLogs(project, service: nil, tail: 300, dialect: .v1, sudo: true)
                == "sudo -n docker-compose -f '/srv/web app/compose.yml' -f '/srv/common/override.yml' --project-directory '/srv/web app' -p 'web;$(id)' logs --no-color --tail 300 -f"
        )
        #expect(
            DockerCommand.composeConfigServices(project, dialect: .v2, sudo: false)
                == "docker compose -f '/srv/web app/compose.yml' -f '/srv/common/override.yml' --project-directory '/srv/web app' -p 'web;$(id)' config --services"
        )
    }

    @Test("v2 项目 JSON 解析配置文件与运行状态")
    func parsesV2ProjectList() {
        let output = """
        [
          {"Name":"web","Status":"running(2)","ConfigFiles":"/srv/web/compose.yml,/srv/base.yml"},
          {"Name":"jobs","Status":"exited(1)","ConfigFiles":"/srv/jobs/compose.yml"}
        ]
        """

        let projects = DockerComposeParser.parseV2Projects(output)

        #expect(projects.map(\.name) == ["jobs", "web"])
        #expect(projects.first(where: { $0.name == "web" })?.state == .running)
        #expect(projects.first(where: { $0.name == "web" })?.configFiles == [
            "/srv/web/compose.yml", "/srv/base.yml",
        ])
        #expect(projects.first(where: { $0.name == "web" })?.projectDirectory == "/srv/web")
        #expect(projects.first(where: { $0.name == "jobs" })?.state == .stopped)
    }

    @Test("容器标签为 v1 归并项目并保留多配置文件路径")
    func discoversV1ProjectsFromContainerLabels() {
        let output = """
        {"ID":"c1","Image":"api:1","Names":"web-api-1","State":"running","Status":"Up 2 hours","Ports":"8080/tcp","Labels":"com.docker.compose.project=web,com.docker.compose.project.config_files=/srv/web/compose.yml,/srv/base.yml,com.docker.compose.project.working_dir=/srv/web,com.docker.compose.service=api"}
        {"ID":"c2","Image":"worker:1","Names":"web-worker-1","State":"exited","Status":"Exited (0) 1 hour ago","Ports":"","Labels":"com.docker.compose.project=web,com.docker.compose.project.config_files=/srv/web/compose.yml,/srv/base.yml,com.docker.compose.project.working_dir=/srv/web,com.docker.compose.service=worker"}
        """

        let projects = DockerComposeParser.parseProjectsFromContainers(output)

        #expect(projects.count == 1)
        #expect(projects[0].name == "web")
        #expect(projects[0].state == .partial)
        #expect(projects[0].configFiles == ["/srv/web/compose.yml", "/srv/base.yml"])
        #expect(projects[0].projectDirectory == "/srv/web")
        #expect(projects[0].containerCount == 2)
        #expect(projects[0].runningContainerCount == 1)
    }

    @Test("服务按标签聚合且配置中无容器的服务显示已停止")
    func aggregatesServicesAndKeepsDeclaredZeroContainerServices() {
        let output = """
        {"ID":"c1","Image":"api:1","Names":"web-api-1","State":"running","Status":"Up 2 hours","Ports":"0.0.0.0:8080->8080/tcp","Labels":"com.docker.compose.project=web,com.docker.compose.service=api"}
        {"ID":"c2","Image":"worker:1","Names":"web-worker-1","State":"exited","Status":"Exited (0) 1 hour ago","Ports":"","Labels":"com.docker.compose.project=web,com.docker.compose.service=worker"}
        """

        let services = DockerComposeParser.parseServices(
            containerOutput: output,
            declaredServices: ["worker", "cron", "api"]
        )

        #expect(services.map(\.name) == ["api", "cron", "worker"])
        #expect(services.first(where: { $0.name == "api" })?.state == .running)
        #expect(services.first(where: { $0.name == "api" })?.runningContainerCount == 1)
        #expect(services.first(where: { $0.name == "cron" })?.state == .stopped)
        #expect(services.first(where: { $0.name == "cron" })?.containerCount == 0)
        #expect(services.first(where: { $0.name == "worker" })?.state == .stopped)
    }

    @Test("同名手动项目覆盖调用上下文但保留自动发现状态")
    func mergesManualAndDiscoveredProjectsByProjectName() {
        let discovered = DockerComposeProject(
            name: "web", state: .running,
            configFiles: ["/auto/compose.yml"], projectDirectory: "/auto",
            source: .automatic, containerCount: 2, runningContainerCount: 2
        )
        let manual = DockerComposeProject(
            name: "web", state: .unknown,
            configFiles: ["/manual/compose.yml"], projectDirectory: "/manual",
            source: .manual
        )
        let alternateName = DockerComposeProject(
            name: "web-preview", state: .unknown,
            configFiles: ["/manual/compose.yml"], projectDirectory: "/manual",
            source: .manual
        )

        let merged = DockerComposeParser.mergeProjects(
            discovered: [discovered],
            manual: [manual, alternateName]
        )

        #expect(merged.map(\.name) == ["web", "web-preview"])
        #expect(merged[0].state == .running)
        #expect(merged[0].configFiles == ["/manual/compose.yml"])
        #expect(merged[0].projectDirectory == "/manual")
        #expect(merged[0].source == .manual)
        #expect(merged[0].containerCount == 2)
    }
}
