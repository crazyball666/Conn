import ConnKit
import ConnSSH
import ConnUI
import SwiftUI
import UniformTypeIdentifiers

/// 目录选择器请求（移动/复制合用一个 sheet——避免同一视图挂多个 `.sheet(item:)` 冲突）。
private enum DirectoryPickerRequest: Identifiable {
    case move(FileEntry)
    case copy(FileEntry)

    var id: String {
        switch self {
        case let .move(entry): "move-\(entry.path)"
        case let .copy(entry): "copy-\(entry.path)"
        }
    }

    var isMove: Bool { if case .move = self { true } else { false } }
}

/// SFTP 文件浏览（Phase 6）——系统「文件」App 风格：面包屑导航 + 搜索 +
/// 分组列表（按类型着色图标）+ 操作收进右上角「•••」菜单，逐条操作走长按菜单。
struct FileBrowserView: View {
    let viewModel: FileBrowserViewModel
    @State private var showUpload = false
    @State private var textPrompt: TextPrompt?
    @State private var promptText = ""
    @State private var editorEntry: FileEntry?
    @State private var directoryPicker: DirectoryPickerRequest?
    @State private var searchText = ""
    @State private var sortField: SortField = .name
    @State private var sortAscending = true
    private let host: Host
    private let dependencies: AppDependencies

    init(host: Host, dependencies: AppDependencies, viewModel: FileBrowserViewModel) {
        self.host = host
        self.dependencies = dependencies
        self.viewModel = viewModel
    }

    enum SortField { case name, date, size, kind }

    private enum TextPrompt: Identifiable {
        case mkdir
        case touchFile
        case rename(FileEntry)
        case chmod(FileEntry)
        case jumpPath

        var id: String {
            switch self {
            case .mkdir: "mkdir"
            case .touchFile: "touchFile"
            case let .rename(entry): "rename-\(entry.path)"
            case let .chmod(entry): "chmod-\(entry.path)"
            case .jumpPath: "jumpPath"
            }
        }
    }

    var body: some View {
        VStack(spacing: ConnSpacing.sm) {
            header
            searchField
            if let transfer = viewModel.transfer { transferBar(transfer) }
            if let url = viewModel.downloadedURL { downloadedBar(url) }
            content
        }
        .padding(.bottom, ConnSpacing.md)
        // 撑满可视区，让 loading 蒙层整块覆盖文件列表（否则只盖到内容高度、会跳）。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay { operationOverlay }
        .animation(.easeInOut(duration: 0.15), value: viewModel.busyLabel)
        .task { await viewModel.loadIfNeeded() }
        .fileImporter(isPresented: $showUpload, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                Task { await viewModel.upload(from: url) }
            }
        }
        .navigationDestination(item: $editorEntry) { entry in
            FileEditorView(host: host, dependencies: dependencies, entry: entry)
        }
        .sheet(item: $directoryPicker) { request in
            DirectoryPickerView(
                title: request.isMove ? L("移动到") : L("复制到"),
                host: host,
                connectionManager: dependencies.connectionManager,
                initialPath: viewModel.currentPath
            ) { destination in
                switch request { // 弹窗同步交回路径，操作在父视图另起 Task（不随弹窗销毁）
                case let .move(entry): Task { await viewModel.move(entry, to: destination) }
                case let .copy(entry): Task { await viewModel.copy(entry, to: destination) }
                }
            }
        }
        .alert(L("删除"), isPresented: deletionBinding, presenting: viewModel.pendingDeletion) { entry in
            // 直接把 entry 传进去——不能靠 confirmDeletion 里读 pendingDeletion（alert 关闭已清空）。
            Button(String(format: L("删除 %@"), entry.name), role: .destructive) {
                Task { await viewModel.delete(entry) }
            }
            Button(L("取消"), role: .cancel) { viewModel.pendingDeletion = nil }
        } message: { entry in
            Text(entry.isDirectory ? L("将删除目录及其内容，不可撤销。") : L("此操作不可撤销。"))
        }
        .alert(promptTitle, isPresented: promptBinding) {
            TextField(promptPlaceholder, text: $promptText)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button(L("确定")) { handlePrompt() }
            Button(L("取消"), role: .cancel) { textPrompt = nil }
        }
        .alert(L("提示"), isPresented: messageBinding) {
            Button(L("好"), role: .cancel) { viewModel.actionMessage = nil }
        } message: {
            Text(viewModel.actionMessage ?? "")
        }
    }

    // MARK: - 顶部：面包屑 + 菜单

    private var header: some View {
        HStack(spacing: ConnSpacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) { breadcrumbItems }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                menuContent
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.connAccent)
            }
            .accessibilityLabel(L("更多操作"))
        }    }

    @ViewBuilder
    private var breadcrumbItems: some View {
        ForEach(breadcrumbs) { crumb in
            if !crumb.isRoot {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.connDim)
            }
            Button {
                if !crumb.isCurrent { Task { await viewModel.load(path: crumb.path) } }
            } label: {
                crumb.isRoot
                    ? AnyView(Image(systemName: "externaldrive").font(.system(size: 15)))
                    : AnyView(Text(crumb.label).font(.connData(.subheadline)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(crumb.isCurrent ? Color.connInk : .connAccent)
            .fontWeight(crumb.isCurrent ? .semibold : .regular)
            .disabled(crumb.isCurrent)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button { showUpload = true } label: { Label(L("上传文件"), systemImage: "square.and.arrow.up") }
        Button { promptText = ""; textPrompt = .mkdir } label: { Label(L("新建文件夹"), systemImage: "folder.badge.plus") }
        Button { promptText = ""; textPrompt = .touchFile } label: { Label(L("新建文件"), systemImage: "doc.badge.plus") }
        Divider()
        Menu {
            sortMenuButton(.name, L("名称"))
            sortMenuButton(.date, L("修改日期"))
            sortMenuButton(.size, L("大小"))
            sortMenuButton(.kind, L("类型"))
        } label: { Label(L("排序方式"), systemImage: "arrow.up.arrow.down") }
        Toggle(isOn: Binding(get: { viewModel.showHidden }, set: { viewModel.showHidden = $0 })) {
            Label(L("显示隐藏文件"), systemImage: "eye.slash")
        }
        Divider()
        Button { viewModel.copyCurrentPath() } label: { Label(L("复制当前目录路径"), systemImage: "doc.on.clipboard") }
        Button { promptText = viewModel.currentPath; textPrompt = .jumpPath } label: {
            Label(L("跳转指定目录"), systemImage: "arrow.right.circle")
        }
        Divider()
        Button { Task { await viewModel.refresh() } } label: { Label(L("刷新"), systemImage: "arrow.clockwise") }
    }

    private func sortMenuButton(_ field: SortField, _ label: String) -> some View {
        Button {
            if sortField == field { sortAscending.toggle() } else { sortField = field; sortAscending = true }
        } label: {
            if sortField == field {
                Label(label, systemImage: sortAscending ? "chevron.up" : "chevron.down")
            } else {
                Text(label)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: ConnSpacing.xs) {
            Image(systemName: "magnifyingglass").font(.connFootnote).foregroundStyle(.connMuted)
            TextField(L("搜索当前目录"), text: $searchText)
                .font(.connSubheadline).foregroundStyle(.connInk)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.connFootnote).foregroundStyle(.connMuted)
                }
                .buttonStyle(.plain).accessibilityLabel(L("清除"))
            }
        }
        .padding(.horizontal, ConnSpacing.sm).padding(.vertical, 9)
        .background(Color.connSurface, in: .rect(cornerRadius: ConnRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 1)
        )    }

    // MARK: - 传输条

    private func transferBar(_ transfer: FileTransferState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(
                format: transfer.direction == .download ? L("下载 %@ · %d%%") : L("上传 %@ · %d%%"),
                transfer.name, Int(transfer.progress * 100)
            ))
            .font(.connFootnote).foregroundStyle(.connMuted)
            ProgressView(value: transfer.progress).tint(.connAccent)
        }    }

    private func downloadedBar(_ url: URL) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.connGood)
            Text(String(format: L("已下载 %@"), url.lastPathComponent)).font(.connFootnote).foregroundStyle(.connInk)
            Spacer()
            ShareLink(item: url) { Text(L("分享")).font(.connFootnote).foregroundStyle(.connAccent) }
            Button { viewModel.downloadedURL = nil } label: {
                Image(systemName: "xmark").font(.footnote).foregroundStyle(.connMuted)
            }
        }
        .padding(.horizontal, ConnSpacing.cardPadding).padding(.vertical, ConnSpacing.sm)
        .connSurface(cornerRadius: ConnRadius.card)    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView(L("读取目录…")).font(.connFootnote).foregroundStyle(.connMuted)
                .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xxl)
        case let .failed(message):
            VStack(spacing: ConnSpacing.sm) {
                ConnBanner(message, systemImage: "exclamationmark.triangle")
                Button(L("重试")) { Task { await viewModel.refresh() } }.font(.connBody).foregroundStyle(.connAccent)
            }.padding(.vertical, ConnSpacing.md)
        case .ready:
            fileList
        }
    }

    private var fileList: some View {
        ScrollView {
            Group {
                if displayedEntries.isEmpty {
                    Text(searchText.isEmpty ? L("空目录") : L("无匹配的文件"))
                        .font(.connSubheadline).foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xxl)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Rectangle().fill(Color.connLine).frame(height: 0.5)
                                    .padding(.leading, 52)
                            }
                            row(entry)
                        }
                    }
                    .connSurface(cornerRadius: ConnRadius.card)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .refreshable {
            let clock = ContinuousClock()
            let start = clock.now
            await viewModel.refresh()
            let minimum = Duration.milliseconds(500)
            let elapsed = clock.now - start
            if elapsed < minimum { try? await Task.sleep(for: minimum - elapsed) }
        }
    }

    private func row(_ entry: FileEntry) -> some View {
        Button {
            if entry.isDirectory { Task { await viewModel.enter(entry) } } else { editorEntry = entry }
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: icon(for: entry))
                    .font(.system(size: 19)).foregroundStyle(iconColor(entry))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.connSubheadline).foregroundStyle(.connInk).lineLimit(1)
                    Text(subtitle(entry)).font(.connData(.caption2)).foregroundStyle(.connDim).lineLimit(1)
                }
                Spacer(minLength: ConnSpacing.xs)
                if entry.isDirectory {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.connDim)
                }
            }
            .padding(.horizontal, ConnSpacing.cardPadding).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rowActions(entry) }
    }

    @ViewBuilder
    private func rowActions(_ entry: FileEntry) -> some View {
        if !entry.isDirectory {
            Button { editorEntry = entry } label: { Label(L("编辑"), systemImage: "pencil") }
            Button { Task { await viewModel.download(entry) } } label: {
                Label(L("下载"), systemImage: "arrow.down.circle")
            }
        }
        Button { promptText = entry.name; textPrompt = .rename(entry) } label: {
            Label(L("重命名"), systemImage: "character.cursor.ibeam")
        }
        Button { promptText = entry.octalPermissions ?? "644"; textPrompt = .chmod(entry) } label: {
            Label(L("修改权限"), systemImage: "lock")
        }
        if entry.isDirectory {
            Button { Task { await viewModel.compress(entry) } } label: {
                Label(L("压缩"), systemImage: "archivebox")
            }
        }
        Divider()
        Button { directoryPicker = .move(entry) } label: { Label(L("移动"), systemImage: "arrow.right.square") }
        Button { directoryPicker = .copy(entry) } label: { Label(L("复制"), systemImage: "doc.on.doc") }
        Divider()
        Button(role: .destructive) { viewModel.pendingDeletion = entry } label: {
            Label(L("删除"), systemImage: "trash")
        }
    }
}

// MARK: - 派生 / 辅助

private extension FileBrowserView {
    /// 文件操作进行中的 loading 蒙层：透明浮层（列表仍可见、仅拦截交互）+ 居中卡片（转圈 + 提示）。
    @ViewBuilder
    var operationOverlay: some View {
        if let label = viewModel.busyLabel {
            ZStack {
                Color.black.opacity(0.06) // 极淡遮罩：拦截交互、暗示忙碌，底下列表仍清晰可见
                VStack(spacing: ConnSpacing.sm) {
                    ProgressView().controlSize(.large).tint(.connAccent)
                    Text(String(format: L("%@中…"), label))
                        .font(.connFootnote).foregroundStyle(.connMuted)
                }
                .padding(ConnSpacing.xl)
                .connSurface(cornerRadius: ConnRadius.card)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
            }
            .transition(.opacity)
        }
    }

    /// 过滤（隐藏项 + 搜索）+ 排序（目录优先，再按字段；`kind` 排序也走 `sortAscending` 翻转）后的条目。
    var displayedEntries: [FileEntry] {
        var list = viewModel.showHidden ? viewModel.entries : viewModel.entries.filter { !$0.isHidden }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { list = list.filter { $0.name.lowercased().contains(query) } }
        return list.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory } // 目录永远在前
            let ascending: Bool
            switch sortField {
            case .name: ascending = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date: ascending = (lhs.modifiedAt ?? .distantPast) < (rhs.modifiedAt ?? .distantPast)
            case .size: ascending = lhs.size < rhs.size
            case .kind: ascending = lhs.kind < rhs.kind // FileKind 枚举序：directory<file<symlink<other
            }
            return sortAscending ? ascending : !ascending
        }
    }

    struct Crumb: Identifiable {
        let label: String
        let path: String
        let isRoot: Bool
        let isCurrent: Bool
        var id: String { path }
    }

    /// 当前路径 → 面包屑（根 + 各级目录名，末级为当前不可点）。
    var breadcrumbs: [Crumb] {
        let path = viewModel.currentPath
        let comps = path.split(separator: "/").map(String.init)
        var result = [Crumb(label: "/", path: "/", isRoot: true, isCurrent: path == "/")]
        var accumulated = ""
        for (index, component) in comps.enumerated() {
            accumulated += "/" + component
            result.append(Crumb(
                label: component, path: accumulated,
                isRoot: false, isCurrent: index == comps.count - 1
            ))
        }
        return result
    }

    /// 扩展名 → SF Symbol。用查表而非大 switch，避免圈复杂度过高。
    static let iconByExtension: [String: String] = {
        let groups: [(String, [String])] = [
            ("photo", ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico", "heic"]),
            ("archivebox.fill", ["zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz"]),
            ("terminal", ["sh", "bash", "zsh", "fish"]),
            ("gearshape", ["conf", "cnf", "ini", "cfg", "toml", "yaml", "yml", "env", "properties"]),
            ("curlybraces", ["json", "xml", "plist"]),
            ("doc.text", ["md", "markdown", "txt", "text", "rst"]),
            ("chevron.left.forwardslash.chevron.right",
             ["js", "ts", "py", "go", "rb", "php", "c", "cpp", "h", "swift", "rs", "java", "sql"]),
            ("cylinder.split.1x2", ["db", "sqlite", "sqlite3"]),
            ("doc.richtext", ["pdf"]),
            ("doc.text.magnifyingglass", ["log"])
        ]
        var map: [String: String] = [:]
        for (symbol, extensions) in groups {
            for ext in extensions { map[ext] = symbol }
        }
        return map
    }()

    func icon(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isSymlink { return "arrow.up.right" }
        return Self.iconByExtension[(entry.name as NSString).pathExtension.lowercased()] ?? "doc"
    }

    func iconColor(_ entry: FileEntry) -> Color {
        if entry.isDirectory { return .connAccent }
        if entry.isSymlink { return .connInfo }
        return .connMuted
    }

    func subtitle(_ entry: FileEntry) -> String {
        if entry.isDirectory {
            return entry.modifiedAt.map { Self.dateFormatter.string(from: $0) } ?? entry.permissionString
        }
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .binary)]
        if let date = entry.modifiedAt { parts.append(Self.dateFormatter.string(from: date)) }
        return parts.joined(separator: " · ")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = ConnLanguage.currentLocale
        formatter.dateFormat = "yy-MM-dd HH:mm"
        return formatter
    }()

    func handlePrompt() {
        let prompt = textPrompt
        textPrompt = nil
        switch prompt {
        case .mkdir: Task { await viewModel.createDirectory(named: promptText) }
        case .touchFile: Task { await viewModel.createFile(named: promptText) }
        case let .rename(entry): Task { await viewModel.rename(entry, to: promptText) }
        case let .chmod(entry): Task { await viewModel.chmod(entry, octal: promptText) }
        case .jumpPath: Task { await viewModel.jumpTo(path: promptText) }
        case nil: break
        }
    }

    var promptTitle: String {
        switch textPrompt {
        case .mkdir: L("新建文件夹")
        case .touchFile: L("新建文件")
        case .rename: L("重命名")
        case .chmod: L("修改权限（八进制）")
        case .jumpPath: L("跳转指定目录")
        case nil: ""
        }
    }

    var promptPlaceholder: String {
        switch textPrompt {
        case .chmod: L("如 644")
        case .jumpPath: L("绝对路径，如 /var/log")
        default: L("名称")
        }
    }

    var deletionBinding: Binding<Bool> {
        Binding(get: { viewModel.pendingDeletion != nil }, set: { if !$0 { viewModel.pendingDeletion = nil } })
    }

    var promptBinding: Binding<Bool> {
        Binding(get: { textPrompt != nil }, set: { if !$0 { textPrompt = nil } })
    }

    var messageBinding: Binding<Bool> {
        Binding(get: { viewModel.actionMessage != nil }, set: { if !$0 { viewModel.actionMessage = nil } })
    }
}
