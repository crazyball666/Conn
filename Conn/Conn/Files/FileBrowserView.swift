import ConnKit
import ConnSSH
import ConnUI
import SwiftUI
import UniformTypeIdentifiers

/// SFTP 文件浏览（Phase 6）——系统「文件」App 风格：面包屑导航 + 搜索 +
/// 分组列表（按类型着色图标）+ 操作收进右上角「•••」菜单，逐条操作走长按菜单。
struct FileBrowserView: View {
    let viewModel: FileBrowserViewModel
    @State private var showUpload = false
    @State private var textPrompt: TextPrompt?
    @State private var promptText = ""
    @State private var editorEntry: FileEntry?
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

    enum SortField { case name, date, size }

    private enum TextPrompt: Identifiable {
        case mkdir
        case rename(FileEntry)
        case chmod(FileEntry)

        var id: String {
            switch self {
            case .mkdir: "mkdir"
            case let .rename(entry): "rename-\(entry.path)"
            case let .chmod(entry): "chmod-\(entry.path)"
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
        .task { await viewModel.loadIfNeeded() }
        .fileImporter(isPresented: $showUpload, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                Task { await viewModel.upload(from: url) }
            }
        }
        .navigationDestination(item: $editorEntry) { entry in
            FileEditorView(host: host, dependencies: dependencies, entry: entry)
        }
        .alert(L("删除"), isPresented: deletionBinding, presenting: viewModel.pendingDeletion) { entry in
            Button(String(format: L("删除 %@"), entry.name), role: .destructive) {
                Task { await viewModel.confirmDeletion() }
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
                    ? AnyView(Image(systemName: "externaldrive").font(.system(size: 13)))
                    : AnyView(Text(crumb.label).font(.connData(.footnote)))
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
        Divider()
        Menu {
            sortMenuButton(.name, L("名称"))
            sortMenuButton(.date, L("修改日期"))
            sortMenuButton(.size, L("大小"))
        } label: { Label(L("排序方式"), systemImage: "arrow.up.arrow.down") }
        Toggle(isOn: Binding(get: { viewModel.showHidden }, set: { viewModel.showHidden = $0 })) {
            Label(L("显示隐藏文件"), systemImage: "eye.slash")
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
        Divider()
        Button(role: .destructive) { viewModel.pendingDeletion = entry } label: {
            Label(L("删除"), systemImage: "trash")
        }
    }
}

// MARK: - 派生 / 辅助

private extension FileBrowserView {
    /// 过滤（隐藏项 + 搜索）+ 排序（目录优先，再按字段）后的条目。
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
            ("chevron.left.forward.slash.chevron.right",
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
        case let .rename(entry): Task { await viewModel.rename(entry, to: promptText) }
        case let .chmod(entry): Task { await viewModel.chmod(entry, octal: promptText) }
        case nil: break
        }
    }

    var promptTitle: String {
        switch textPrompt {
        case .mkdir: L("新建文件夹")
        case .rename: L("重命名")
        case .chmod: L("修改权限（八进制）")
        case nil: ""
        }
    }

    var promptPlaceholder: String {
        switch textPrompt {
        case .chmod: L("如 644")
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
