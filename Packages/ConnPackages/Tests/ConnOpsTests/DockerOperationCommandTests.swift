import Testing
@testable import ConnOps

@Suite("Docker 操作草稿与命令")
struct DockerOperationCommandTests {
    @Test("用户值被视为一个 shell 参数而不是代码")
    func quotesShellMetacharacters() {
        #expect(ShellArgument.quote("") == "''")
        #expect(ShellArgument.quote(" white space ") == "' white space '")
        #expect(ShellArgument.quote("x'y") == "'x'\\''y'")
        #expect(ShellArgument.quote("one; two") == "'one; two'")
        #expect(ShellArgument.quote("`uname`") == "'`uname`'")
        #expect(ShellArgument.quote("$(whoami); x'y") == "'$(whoami); x'\\''y'")
    }

    @Test("run 草稿校验缺失镜像")
    func validatesMissingImage() {
        let draft = DockerRunDraft(image: "")

        #expect(draft.validate() == [.imageRequired])
    }

    @Test("run 草稿校验端口范围与宿主端口协议重复")
    func validatesPorts() {
        let invalid = PortBinding(hostPort: "0", containerPort: "70000", protocol: .tcp)
        #expect(DockerRunDraft(image: "nginx", ports: [invalid]).validate() == [.invalidPort(invalid)])

        let duplicate = DockerRunDraft(
            image: "nginx",
            ports: [
                PortBinding(hostPort: "8080", containerPort: "80", protocol: .tcp),
                PortBinding(hostPort: "8080", containerPort: "8080", protocol: .tcp),
            ]
        )
        #expect(duplicate.validate() == [.duplicateHostPort(hostPort: "8080", protocol: .tcp)])
    }

    @Test("同一宿主端口可映射到不同协议")
    func allowsSameHostPortForDifferentProtocols() {
        let draft = DockerRunDraft(
            image: "nginx",
            ports: [
                .init(hostPort: "8080", containerPort: "80", protocol: .tcp),
                .init(hostPort: "8080", containerPort: "80", protocol: .udp),
            ]
        )

        #expect(draft.validate().isEmpty)
    }

    @Test("run 草稿校验环境变量和挂载目标")
    func validatesEnvironmentAndMount() {
        let draft = DockerRunDraft(
            image: "nginx",
            environment: [.init(key: "NOT-VALID", value: "value")],
            mounts: [
                .init(source: .namedVolume("data"), target: "relative/path"),
                .init(source: .namedVolume(""), target: "/missing-source"),
            ]
        )

        #expect(draft.validate() == [
            .invalidEnvironmentKey("NOT-VALID"),
            .mountTargetMustBeAbsolute("relative/path"),
            .mountSourceRequired,
        ])
    }

    @Test("run 草稿拒绝空和覆盖结构化字段的其他选项")
    func rejectsEmptyAndConflictingOtherOptions() {
        let conflicts = [
            "--name", "--network=app", "--restart=always", "--detach", "-d",
            "--publish=8080:80", "-p", "--env=KEY=value", "-e",
            "--volume=data:/data", "-v", "--mount", "--mount=type=volume", "--",
        ]
        let errors = DockerRunDraft(image: "nginx", otherOptionTokens: [""] + conflicts).validate()

        #expect(errors.contains(.emptyOtherOptionToken))
        for token in conflicts {
            #expect(errors.contains(.conflictingOtherOptionToken(token)))
        }
    }

    @Test("run 草稿拒绝 --net 网络别名，不能绕开结构化网络复核")
    func rejectsNetworkAliasOverrides() {
        let equalsSyntax = DockerRunDraft(
            image: "nginx",
            otherOptionTokens: ["--net=host"]
        )
        let separateSyntax = DockerRunDraft(
            image: "nginx",
            otherOptionTokens: ["--net", "host"]
        )

        #expect(equalsSyntax.validate() == [.conflictingOtherOptionToken("--net=host")])
        #expect(separateSyntax.validate() == [.conflictingOtherOptionToken("--net")])
    }

    @Test("run 草稿拒绝等号形式的名称覆盖")
    func rejectsEqualsFormNameOverride() {
        let errors = DockerRunDraft(image: "nginx", otherOptionTokens: ["--name=override"]).validate()

        #expect(errors == [.conflictingOtherOptionToken("--name=override")])
    }

    @Test("run 草稿拒绝附值形式的冲突短选项")
    func rejectsAttachedValueShortOptions() {
        let conflicts = ["-p8080:80", "-eKEY=value", "-vhost:/dst"]
        let errors = DockerRunDraft(image: "nginx", otherOptionTokens: conflicts).validate()

        #expect(errors == conflicts.map(ValidationError.conflictingOtherOptionToken))
    }

    @Test("run 草稿拒绝含 detach 的短选项簇但保留无关簇")
    func rejectsDetachShortOptionClusters() {
        let detached = DockerRunDraft(image: "nginx", otherOptionTokens: ["-di"])
        let unrelated = DockerRunDraft(image: "nginx", otherOptionTokens: ["-it", "-P"])
        let invalidAttachedJunk = DockerRunDraft(image: "nginx", otherOptionTokens: ["-dfoo"])

        #expect(detached.validate() == [.conflictingOtherOptionToken("-di")])
        #expect(unrelated.validate().isEmpty)
        #expect(invalidAttachedJunk.validate().isEmpty)
    }

    @Test("run 草稿允许未冲突的高级选项和任意启动命令 token")
    func allowsAdvancedOptionsAndCommandTokens() {
        let draft = DockerRunDraft(
            image: "nginx",
            otherOptionTokens: ["--cpus=1", "--add-host", "db:10.0.0.2"],
            commandTokens: ["--name", "", "$(id)"]
        )

        #expect(draft.validate().isEmpty)
    }

    @Test("构造新 Docker 操作并逐个编码动态参数")
    func buildsOperationCommands() {
        let run = DockerRunDraft(
            image: "nginx:1.27",
            name: "web app",
            detached: true,
            network: "app net",
            ports: [.init(hostPort: "8080", containerPort: "80", protocol: .tcp)],
            environment: [.init(key: "APP_MODE", value: "prod;$(whoami)")],
            mounts: [.init(source: .namedVolume("data vol"), target: "/var/lib/app", readOnly: true)],
            restartPolicy: .unlessStopped,
            hostname: "web-01",
            user: "nginx",
            workdir: "/app",
            readOnlyRoot: true,
            otherOptionTokens: ["--cpus=1", "--add-host", "db:10.0.0.2"],
            commandTokens: ["nginx", "-g", "daemon off;"]
        )
        let volume = DockerVolumeDraft(
            name: "app data", driver: "local driver", otherOptionTokens: ["--opt", "type=nfs;"]
        )
        let network = DockerNetworkDraft(
            name: "app net", driver: "bridge driver", isInternal: true, isAttachable: true,
            otherOptionTokens: ["--opt", "com.example.note=hello world"]
        )

        #expect(DockerCommand.pull(reference: "repo;$(whoami)", sudo: false) == "docker pull 'repo;$(whoami)'")
        // swiftlint:disable line_length
        #expect(
            DockerCommand.run(run, sudo: true)
                == "sudo -n docker run --name 'web app' --detach --network 'app net' --hostname 'web-01' --user 'nginx' --workdir '/app' --publish '8080:80/tcp' --env 'APP_MODE=prod;$(whoami)' --mount 'type=volume,src=data vol,dst=/var/lib/app,readonly' --restart 'unless-stopped' --read-only '--cpus=1' '--add-host' 'db:10.0.0.2' 'nginx:1.27' 'nginx' '-g' 'daemon off;'"
        )
        // swiftlint:enable line_length
        #expect(
            DockerCommand.createVolume(volume, sudo: false)
                == "docker volume create --driver 'local driver' '--opt' 'type=nfs;' 'app data'"
        )
        #expect(DockerCommand.removeVolume(name: "app data; rm -rf /", sudo: true) == "sudo -n docker volume rm 'app data; rm -rf /'")
        #expect(
            DockerCommand.createNetwork(network, sudo: false)
                == "docker network create --driver 'bridge driver' --internal --attachable '--opt' 'com.example.note=hello world' 'app net'"
        )
        #expect(DockerCommand.removeNetwork(name: "app net;$(id)", sudo: true) == "sudo -n docker network rm 'app net;$(id)'")
        #expect(
            DockerCommand.systemPrune(.init(allUnusedImages: true, includeVolumes: true), sudo: true)
                == "sudo -n docker system prune -f -a --volumes"
        )
        #expect(DockerCommand.systemPrune(.init(), sudo: false) == "docker system prune -f")
    }

    @Test("空字符串的 hostname / user / workdir 等同于未设置")
    func ignoresBlankIdentityFields() {
        let draft = DockerRunDraft(
            image: "nginx",
            hostname: "",
            user: "",
            workdir: nil,
            readOnlyRoot: false
        )

        #expect(
            DockerCommand.run(draft, sudo: false) == "docker run 'nginx'"
        )
    }

    @Test("构造 bind 挂载并保留只读语义")
    func buildsBindMountCommands() {
        let readWrite = DockerRunDraft(
            image: "busybox:1",
            mounts: [.init(source: .bind("/srv/data;$(id)"), target: "/container dir")]
        )
        let readOnly = DockerRunDraft(
            image: "busybox",
            mounts: [.init(source: .bind("/host dir"), target: "/container dir", readOnly: true)]
        )

        #expect(
            DockerCommand.run(readWrite, sudo: false)
                == "docker run --mount 'type=bind,src=/srv/data;$(id),dst=/container dir' 'busybox:1'"
        )
        #expect(
            DockerCommand.run(readOnly, sudo: false)
                == "docker run --mount 'type=bind,src=/host dir,dst=/container dir,readonly' 'busybox'"
        )
    }
}
