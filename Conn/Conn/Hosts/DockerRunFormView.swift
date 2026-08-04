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
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: MountEntry.Source = switch sourceKind {
        case .namedVolume: .namedVolume(normalizedSource)
        case .bind: .bind(normalizedSource)
        }
        return MountEntry(source: source, target: normalizedTarget, readOnly: readOnly)
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
    var hostname = ""
    var user = ""
    var workdir = ""
    var readOnlyRoot = false
    var detached = true
    var network = ""
    var ports: [DockerPortRow] = []
    var environment: [DockerEnvironmentRow] = []
    var mounts: [DockerMountRow] = []
    var restartPolicy: RestartPolicy = .no
    /// 多行文本，每行一项 docker flag。空行 / `#` 开头行视为注释。
    /// 与 `otherOptions`（按行列表）不同——这里一次性能粘 10 个 flag 而不占 10 行 UI。
    var otherOptionsText = ""
    var command: [DockerTokenRow] = []

    var draft: DockerRunDraft {
        let normalizedPorts = ports.compactMap { port -> PortBinding? in
            let host = port.hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
            let container = port.containerPort.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !(host.isEmpty && container.isEmpty) else { return nil }
            return port.protocol.binding(hostPort: host, containerPort: container)
        }
        let normalizedEnvironment = environment.compactMap { entry -> EnvironmentEntry? in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !(key.isEmpty && entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            else { return nil }
            return EnvironmentEntry(key: key, value: entry.value)
        }
        let normalizedMounts = mounts.compactMap { mount -> MountEntry? in
            let source = mount.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = mount.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !(source.isEmpty && target.isEmpty) else { return nil }
            return DockerMountRow(
                id: mount.id, sourceKind: mount.sourceKind, source: source,
                target: target, readOnly: mount.readOnly
            ).draft
        }
        let normalizedCommand = command.compactMap { token -> String? in
            let value = token.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return DockerRunDraft(
            image: image,
            name: name.trimmedOrNil,
            detached: detached,
            network: network.trimmedOrNil,
            ports: normalizedPorts,
            environment: normalizedEnvironment,
            mounts: normalizedMounts,
            restartPolicy: restartPolicy,
            hostname: hostname.trimmedOrNil,
            user: user.trimmedOrNil,
            workdir: workdir.trimmedOrNil,
            readOnlyRoot: readOnlyRoot,
            otherOptionTokens: Self.parseOtherOptions(otherOptionsText),
            commandTokens: normalizedCommand
        )
    }

    var isValid: Bool { draft.validate().isEmpty }

    /// 多行文本转 token 列表。空行 / `#` 开头行忽略；其余行整行作为一个 argv。
    /// 空格分隔的复合形式（如 `--add-host db:1.2.3.4`）不支持——必须写成
    /// `--add-host=db:1.2.3.4`，以 `=` 形式粘进多行文本。
    static func parseOtherOptions(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

private extension String {
    /// 仅用于结构化可选字段：把前后空白去掉后是空串就视为"未设置"。
    /// 区别于"用户有意输入的纯空白值"——后者是病态输入，照原样传出反而是噪音。
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
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

/// `docker run` 的结构化编辑器。工具栏的"创建容器"直接调用 `runContainer`，
/// 不再跳转中间复核页——命令预览就放在表单最末段。
struct DockerRunFormView: View {
    let images: DockerImagesModel
    let networks: DockerNetworksModel
    let volumes: DockerVolumesModel
    let operations: DockerOperationsModel
    /// 复用当前草稿作为本地命令片段保存。父级负责落库，表单根据 throwing
    /// 回调的结果更新成功状态；这里只产生 `(title, command)`。
    let onSaveAsCommand: DockerCommandSaveHandler?
    @Environment(\.dismiss) private var dismiss
    @State private var state = DockerRunFormState()
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var savedTitle: String?
    @State private var isCommandSaved = false
    @State private var isPortsExpanded = true
    @State private var isEnvironmentExpanded = true
    @State private var isMountsExpanded = true
    @State private var isCommandExpanded = true

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                portsSection
                environmentSection
                mountsSection
                advancedSection
                commandSection
                if !risks.isEmpty {
                    risksSection
                }
                previewSection
                if let errorMessage {
                    Section {
                        ConnBanner(errorMessage, systemImage: "exclamationmark.triangle")
                    }
                    .listRowBackground(Color.connSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("创建容器"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSubmitting)
            .task {
                await images.loadIfNeeded()
                await volumes.loadIfNeeded()
                await networks.loadIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L("创建容器"))
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!state.isValid || !operations.isWriteAvailable || isSubmitting)
                }
            }
        }
    }

    private var basicsSection: some View {
        Section(L("基本")) {
            HStack(spacing: ConnSpacing.sm) {
                TextField(L("镜像"), text: $state.image)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !images.items.filter({ !$0.isDangling }).isEmpty {
                    Menu {
                        ForEach(images.items.filter { !$0.isDangling }) { image in
                            Button {
                                state.image = image.reference
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(image.displayName)
                                    Text(image.size).font(.connFootnote).foregroundStyle(.connMuted)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(.connAccent)
                            .frame(width: 34, height: 34)
                    }
                    .accessibilityLabel(L("选择已有镜像"))
                }
            }
            TextField(L("名称"), text: $state.name).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle(L("后台运行"), isOn: $state.detached)
            HStack(spacing: ConnSpacing.sm) {
                TextField("\(L("网络"))（可选）", text: $state.network)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !networks.items.isEmpty {
                    Menu {
                        Button(L("不设置")) { state.network = "" }
                        ForEach(networks.items) { network in
                            Button(network.name) { state.network = network.name }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(.connAccent)
                            .frame(width: 34, height: 34)
                    }
                    .accessibilityLabel(L("选择已有网络"))
                }
            }
            Picker(L("重启策略"), selection: $state.restartPolicy) {
                ForEach(RestartPolicy.allCases, id: \.self) { policy in
                    Text(restartTitle(policy)).tag(policy)
                }
            }
        }
        .listRowBackground(Color.connSurface)
    }

    @ViewBuilder
    private var portsSection: some View {
        if state.ports.isEmpty {
            Section(L("端口")) {
                Button { state.ports.append(DockerPortRow()) } label: {
                    Label(L("添加端口"), systemImage: "plus")
                }
            }
            .listRowBackground(Color.connSurface)
        } else {
            Section {
                DisclosureGroup(isExpanded: $isPortsExpanded) {
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
                        }
                    }
                    .onDelete { offsets in
                        state.ports.remove(atOffsets: offsets)
                    }
                    Button { state.ports.append(DockerPortRow()) } label: {
                        Label(L("添加端口"), systemImage: "plus")
                    }
                } label: {
                    HStack {
                        Text(L("端口"))
                        Spacer(minLength: 0)
                        Text("\(state.ports.count)")
                            .font(.connData(.caption2))
                            .foregroundStyle(.connMuted)
                    }
                }
            }
            .listRowBackground(Color.connSurface)
        }
    }

    @ViewBuilder
    private var environmentSection: some View {
        // 12-factor 应用动辄 5-10 个环境变量，不折叠会占大半个屏幕。
        // 0 项时 DisclosureGroup 自带折叠占位、看起来像空段，所以直接显示添加按钮更清爽。
        if state.environment.isEmpty {
            Section(L("环境变量")) {
                Button { state.environment.append(DockerEnvironmentRow()) } label: {
                    Label(L("添加环境变量"), systemImage: "plus")
                }
            }
            .listRowBackground(Color.connSurface)
        } else {
            Section {
                DisclosureGroup(isExpanded: $isEnvironmentExpanded) {
                    ForEach($state.environment) { $entry in
                        HStack {
                            TextField(L("名称"), text: $entry.key).textInputAutocapitalization(.characters)
                            SecureField(L("值"), text: $entry.value)
                        }
                    }
                    .onDelete { offsets in
                        state.environment.remove(atOffsets: offsets)
                    }
                    Button { state.environment.append(DockerEnvironmentRow()) } label: {
                        Label(L("添加环境变量"), systemImage: "plus")
                    }
                } label: {
                    HStack {
                        Text(L("环境变量"))
                        Spacer(minLength: 0)
                        Text("\(state.environment.count)")
                            .font(.connData(.caption2))
                            .foregroundStyle(.connMuted)
                    }
                }
            }
            .listRowBackground(Color.connSurface)
        }
    }

    @ViewBuilder
    private var mountsSection: some View {
        if state.mounts.isEmpty {
            Section(L("挂载")) {
                Button { state.mounts.append(DockerMountRow()) } label: {
                    Label(L("添加挂载"), systemImage: "plus")
                }
            }
            .listRowBackground(Color.connSurface)
        } else {
            Section {
                DisclosureGroup(isExpanded: $isMountsExpanded) {
                    ForEach($state.mounts) { $mount in
                        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                            Picker(L("类型"), selection: $mount.sourceKind) {
                                ForEach(DockerMountSourceKind.allCases) { Text($0.title).tag($0) }
                            }
                            if mount.sourceKind == .namedVolume {
                                HStack(spacing: ConnSpacing.sm) {
                                    TextField("\(L("卷"))（可手动填写）", text: $mount.source)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                    if !volumes.items.isEmpty {
                                        Menu {
                                            ForEach(volumes.items) { volume in
                                                Button(volume.name) { mount.source = volume.name }
                                            }
                                        } label: {
                                            Image(systemName: "chevron.up.chevron.down")
                                                .foregroundStyle(.connAccent)
                                                .frame(width: 34, height: 34)
                                        }
                                        .accessibilityLabel(L("选择已有卷"))
                                    }
                                }
                            } else {
                                TextField(L("主机路径"), text: $mount.source)
                                    .textInputAutocapitalization(.never)
                            }
                            TextField(L("容器路径"), text: $mount.target)
                                .textInputAutocapitalization(.never)
                            Toggle(L("只读"), isOn: $mount.readOnly)
                        }
                    }
                    .onDelete { offsets in
                        state.mounts.remove(atOffsets: offsets)
                    }
                    Button { state.mounts.append(DockerMountRow()) } label: {
                        Label(L("添加挂载"), systemImage: "plus")
                    }
                } label: {
                    HStack {
                        Text(L("挂载"))
                        Spacer(minLength: 0)
                        Text("\(state.mounts.count)")
                            .font(.connData(.caption2))
                            .foregroundStyle(.connMuted)
                    }
                }
            }
            .listRowBackground(Color.connSurface)
        }
    }

    private var advancedSection: some View {
        // 这里是任何未结构化 docker flag 的统一入口——一行一项，
        // 写法上等同从 docker 文档 / docker-compose.yml 里粘。
        // 必须用 `--flag=value` 形式，不支持 `--flag value` 拆两行（多行就两行 ≠ argv）。
        Section {
            TextEditor(text: $state.otherOptionsText)
                .font(.connData(.footnote))
                .frame(minHeight: 80)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
        } header: {
            Text(L("高级选项"))
        } footer: {
            Text(String(format: L("一行一项 docker flag，可写 --flag=value 形式。空行与 # 开头行忽略；%@、%@、%@和%@也可在这里填写。"), L("主机名"), L("用户"), L("工作目录"), L("只读根文件系统")))
        }
        .listRowBackground(Color.connSurface)
    }

    @ViewBuilder
    private var commandSection: some View {
        if state.command.isEmpty {
            Section(L("启动命令")) {
                Button { state.command.append(DockerTokenRow()) } label: {
                    Label(L("添加参数"), systemImage: "plus")
                }
            }
            .listRowBackground(Color.connSurface)
        } else {
            Section {
                DisclosureGroup(isExpanded: $isCommandExpanded) {
                    ForEach($state.command) { $token in
                        TextField(L("参数"), text: $token.value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .onDelete { offsets in
                        state.command.remove(atOffsets: offsets)
                    }
                    Button { state.command.append(DockerTokenRow()) } label: {
                        Label(L("添加参数"), systemImage: "plus")
                    }
                } label: {
                    HStack {
                        Text(L("启动命令"))
                        Spacer(minLength: 0)
                        Text("\(state.command.count)")
                            .font(.connData(.caption2))
                            .foregroundStyle(.connMuted)
                    }
                }
            }
            .listRowBackground(Color.connSurface)
        }
    }

    /// 高风险配置（如特权、主机网络、绑定 Docker Socket）一律以橙色列出，
    /// 即使拼到命令预览里也拦不住"复制走手敲"——必须留一道目视警示。
    private var risksSection: some View {
        Section(L("高风险配置")) {
            ForEach(risks, id: \.self) { risk in
                Label(risk.title, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.connWarn)
            }
        }
        .listRowBackground(Color.connSurface)
    }

    /// 实时显示要交给 SSH 的 docker 命令。复用真正的命令构造器，
    /// 与 `runContainer` 走的是同一条 `DockerCommand.run`，避免预览与执行分叉。
    /// 段尾附"保存到本地命令"按钮——一键把当前草稿落成可复用片段，
    /// 不用退出表单去命令 Tab 再粘贴一遍。
    private var previewSection: some View {
        Section {
            Text(previewCommand)
                .font(.connData(.footnote))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let onSaveAsCommand {
                Button {
                    saveAsCommand(via: onSaveAsCommand)
                } label: {
                    Label(L("保存到本地命令"), systemImage: "square.and.arrow.down")
                }
                .disabled(!state.isValid || isCommandSaved)
            }
            if let savedTitle {
                Label(String(format: L("已保存：%@"), savedTitle), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.connGood)
                    .font(.connFootnote)
            }
        } header: {
            Text(L("预览命令"))
        }
        .listRowBackground(Color.connSurface)
    }

    private var risks: [DockerRunRisk] { DockerRunRiskDetector.detect(state.draft) }

    private var previewCommand: String { DockerCommand.run(state.draft, sudo: false) }

    private func submit() {
        guard state.isValid else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            let outcome = await operations.runContainer(state.draft)
            isSubmitting = false
            if outcome.isSuccess {
                dismiss()
            } else {
                errorMessage = DockerOperationFeedback.message(
                    for: outcome,
                    label: L("创建容器")
                )
            }
        }
    }

    /// 把当前草稿作为本地命令片段保存。标题从 `name` 派生：优先用 `name`，
    /// 否则用 image。回调抛错时保留按钮可用，方便用户修复后重试。
    private func saveAsCommand(via onSave: @escaping DockerCommandSaveHandler) {
        guard !isCommandSaved else { return }
        let command = previewCommand
        let title = state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(format: L("运行 %@"), state.image.trimmingCharacters(in: .whitespacesAndNewlines))
            : String(format: L("运行 %@"), state.name.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            try onSave(title, command)
            savedTitle = title
            isCommandSaved = true
        } catch {
            errorMessage = String(
                format: L("保存失败：%@"),
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    private func restartTitle(_ policy: RestartPolicy) -> String {
        switch policy {
        case .no: L("不重启")
        case .always: L("始终")
        case .unlessStopped: L("除非手动停止")
        case .onFailure: L("失败时")
        }
    }

}
