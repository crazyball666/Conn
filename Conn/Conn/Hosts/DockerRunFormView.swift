import ConnOps
import ConnUI
import SwiftUI

/// 可编辑行刻意持有 UUID，而不是拿数组下标作为 `ForEach` 身份；插入、删除或重排后
/// TextField 的焦点与值仍属于同一行，最后再按数组顺序映射为不可变领域草稿。
struct DockerPortRow: Identifiable {
    let id: UUID
    var hostPort: String
    var containerPort: String
    var `protocol`: DockerPortProtocol

    init(id: UUID = UUID(), hostPort: String = "", containerPort: String = "", protocol: DockerPortProtocol = .tcp) {
        self.id = id
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.`protocol` = `protocol`
    }
}

enum DockerPortProtocol: String, CaseIterable, Identifiable {
    case tcp
    case udp
    case sctp

    var id: Self { self }

    func binding(hostPort: String, containerPort: String) -> PortBinding {
        switch self {
        case .tcp: PortBinding(hostPort: hostPort, containerPort: containerPort)
        case .udp: PortBinding(hostPort: hostPort, containerPort: containerPort, protocol: .udp)
        case .sctp: PortBinding(hostPort: hostPort, containerPort: containerPort, protocol: .sctp)
        }
    }
}

struct DockerEnvironmentRow: Identifiable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

enum DockerMountSourceKind: CaseIterable, Identifiable {
    case namedVolume
    case bind

    var id: Self { self }
    var title: String {
        switch self {
        case .namedVolume: L("具名卷")
        case .bind: L("绑定挂载")
        }
    }
}

struct DockerMountRow: Identifiable {
    let id: UUID
    var sourceKind: DockerMountSourceKind
    var source: String
    var target: String
    var readOnly: Bool

    init(
        id: UUID = UUID(), sourceKind: DockerMountSourceKind = .namedVolume, source: String = "",
        target: String = "", readOnly: Bool = false
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }

    var draft: MountEntry {
        let source: MountEntry.Source = switch sourceKind {
        case .namedVolume: .namedVolume(source)
        case .bind: .bind(source)
        }
        return MountEntry(source: source, target: target, readOnly: readOnly)
    }
}

struct DockerTokenRow: Identifiable {
    let id: UUID
    var value: String

    init(id: UUID = UUID(), value: String = "") {
        self.id = id
        self.value = value
    }
}

struct DockerRunFormState {
    var image = ""
    var name = ""
    var detached = true
    var network = ""
    var ports: [DockerPortRow] = []
    var environment: [DockerEnvironmentRow] = []
    var mounts: [DockerMountRow] = []
    var restartPolicy: RestartPolicy = .no
    var otherOptions: [DockerTokenRow] = []
    var command: [DockerTokenRow] = []

    var draft: DockerRunDraft {
        DockerRunDraft(
            image: image, name: name.isEmpty ? nil : name, detached: detached,
            network: network.isEmpty ? nil : network,
            ports: ports.map { $0.protocol.binding(hostPort: $0.hostPort, containerPort: $0.containerPort) },
            environment: environment.map { EnvironmentEntry(key: $0.key, value: $0.value) },
            mounts: mounts.map(\.draft), restartPolicy: restartPolicy,
            otherOptionTokens: otherOptions.map(\.value), commandTokens: command.map(\.value)
        )
    }

    var isValid: Bool { draft.validate().isEmpty }
}

enum DockerRunRisk: Hashable {
    case privileged
    case hostNetwork
    case dockerSocket
    case rootBind

    var title: String {
        switch self {
        case .privileged: L("特权容器")
        case .hostNetwork: L("主机网络")
        case .dockerSocket: L("Docker Socket")
        case .rootBind: L("根目录绑定")
        }
    }
}

enum DockerRunRiskDetector {
    static func detect(_ draft: DockerRunDraft) -> [DockerRunRisk] {
        var risks: [DockerRunRisk] = []
        if draft.otherOptionTokens.contains(where: { $0 == "--privileged" || $0.hasPrefix("--privileged=") }) {
            risks.append(.privileged)
        }
        if draft.network == "host" {
            risks.append(.hostNetwork)
        }
        for mount in draft.mounts {
            guard case let .bind(path) = mount.source else { continue }
            if path == "/var/run/docker.sock" { risks.append(.dockerSocket) }
            if path == "/" { risks.append(.rootBind) }
        }
        return risks
    }
}

/// `docker run` 的结构化编辑器。只有 review 页面能触发 `runContainer`，表单页只改本地草稿。
struct DockerRunFormView: View {
    let networks: DockerNetworksModel
    let volumes: DockerVolumesModel
    let operations: DockerOperationsModel
    @Environment(\.dismiss) private var dismiss
    @State private var state = DockerRunFormState()
    @State private var showsReview = false

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                portsSection
                environmentSection
                mountsSection
                advancedSection
                commandSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("创建容器"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsReview) {
                DockerRunReviewView(draft: state.draft, operations: operations) { dismiss() }
            }
            .task {
                await volumes.loadIfNeeded()
                await networks.loadIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("继续")) { showsReview = true }
                        .fontWeight(.semibold)
                        .disabled(!state.isValid || !operations.isWriteAvailable)
                }
            }
        }
    }

    private var basicsSection: some View {
        Section(L("基本")) {
            TextField(L("镜像"), text: $state.image).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField(L("名称"), text: $state.name).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle(L("后台运行"), isOn: $state.detached)
            Picker(L("网络"), selection: $state.network) {
                Text(L("不设置")).tag("")
                ForEach(networks.items) { network in Text(network.name).tag(network.name) }
            }
            Picker(L("重启策略"), selection: $state.restartPolicy) {
                ForEach(RestartPolicy.allCases, id: \.self) { policy in
                    Text(restartTitle(policy)).tag(policy)
                }
            }
        }
        .listRowBackground(Color.connSurface)
    }

    private var portsSection: some View {
        Section(L("端口")) {
            ForEach($state.ports) { $port in
                HStack {
                    TextField(L("主机端口"), text: $port.hostPort).keyboardType(.numberPad)
                    Text(":").foregroundStyle(.connMuted)
                    TextField(L("容器端口"), text: $port.containerPort).keyboardType(.numberPad)
                    Picker(L("协议"), selection: $port.protocol) {
                        ForEach(DockerPortProtocol.allCases) { portProtocol in
                            Text(portProtocol.rawValue).tag(portProtocol)
                        }
                    }
                    .labelsHidden()
                    Button { remove(port.id, from: &state.ports) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.connCrit)
                }
            }
            Button { state.ports.append(DockerPortRow()) } label: { Label(L("添加端口"), systemImage: "plus") }
        }
        .listRowBackground(Color.connSurface)
    }

    private var environmentSection: some View {
        Section(L("环境变量")) {
            ForEach($state.environment) { $entry in
                HStack {
                    TextField(L("名称"), text: $entry.key).textInputAutocapitalization(.characters)
                    SecureField(L("值"), text: $entry.value)
                    Button { remove(entry.id, from: &state.environment) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.connCrit)
                }
            }
            Button { state.environment.append(DockerEnvironmentRow()) } label: { Label(L("添加环境变量"), systemImage: "plus") }
        }
        .listRowBackground(Color.connSurface)
    }

    private var mountsSection: some View {
        Section(L("挂载")) {
            ForEach($state.mounts) { $mount in
                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    HStack {
                        Picker(L("类型"), selection: $mount.sourceKind) {
                            ForEach(DockerMountSourceKind.allCases) { Text($0.title).tag($0) }
                        }
                        Button { remove(mount.id, from: &state.mounts) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.connCrit)
                    }
                    if mount.sourceKind == .namedVolume {
                        Picker(L("卷"), selection: $mount.source) {
                            Text(L("选择卷")).tag("")
                            ForEach(volumes.items) { volume in Text(volume.name).tag(volume.name) }
                        }
                    } else {
                        TextField(L("主机路径"), text: $mount.source).textInputAutocapitalization(.never)
                    }
                    TextField(L("容器路径"), text: $mount.target).textInputAutocapitalization(.never)
                    Toggle(L("只读"), isOn: $mount.readOnly)
                }
            }
            Button { state.mounts.append(DockerMountRow()) } label: { Label(L("添加挂载"), systemImage: "plus") }
        }
        .listRowBackground(Color.connSurface)
    }

    private var advancedSection: some View {
        Section(L("高级选项")) {
            ForEach($state.otherOptions) { $token in
                HStack {
                    TextField(L("选项"), text: $token.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { remove(token.id, from: &state.otherOptions) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.connCrit)
                }
            }
            Button { state.otherOptions.append(DockerTokenRow()) } label: { Label(L("添加选项"), systemImage: "plus") }
        }
        .listRowBackground(Color.connSurface)
    }

    private var commandSection: some View {
        Section(L("启动命令")) {
            ForEach($state.command) { $token in
                HStack {
                    TextField(L("参数"), text: $token.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { remove(token.id, from: &state.command) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.connCrit)
                }
            }
            Button { state.command.append(DockerTokenRow()) } label: { Label(L("添加参数"), systemImage: "plus") }
        }
        .listRowBackground(Color.connSurface)
    }

    private func restartTitle(_ policy: RestartPolicy) -> String {
        switch policy {
        case .no: L("不重启")
        case .always: L("始终")
        case .unlessStopped: L("除非手动停止")
        case .onFailure: L("失败时")
        }
    }

    private func remove<Row: Identifiable>(_ id: Row.ID, from rows: inout [Row]) {
        rows.removeAll { $0.id == id }
    }
}

private struct DockerRunReviewView: View {
    let draft: DockerRunDraft
    let operations: DockerOperationsModel
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !risks.isEmpty {
                Section(L("高风险配置")) {
                    ForEach(risks, id: \.self) { risk in
                        Label(risk.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.connWarn)
                    }
                }
            }
            Section(L("有效配置")) {
                ForEach(Array(maskedArguments.enumerated()), id: \.offset) { _, argument in
                    Text(argument).font(.connData(.footnote)).textSelection(.enabled)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("复核配置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("返回")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("创建容器")) {
                    Task {
                        await operations.runContainer(draft)
                        completed()
                    }
                }
                .fontWeight(.semibold)
                .disabled(!operations.isWriteAvailable)
            }
        }
    }

    private var risks: [DockerRunRisk] { DockerRunRiskDetector.detect(draft) }

    private var maskedArguments: [String] {
        var result: [String] = []
        var masksNextEnvironment = false
        for argument in draft.effectiveArguments {
            if masksNextEnvironment {
                let key = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
                result.append("\(key)=••••")
                masksNextEnvironment = false
            } else {
                result.append(argument)
                masksNextEnvironment = argument == "--env"
            }
        }
        return result
    }
}
