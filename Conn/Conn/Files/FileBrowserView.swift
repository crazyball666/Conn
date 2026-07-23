import ConnKit
import ConnSSH
import ConnUI
import SwiftUI
import UniformTypeIdentifiers

/// SFTP 文件浏览（Phase 6）：导航 + 上传/下载 + 编辑 + 目录操作。
struct FileBrowserView: View {
    @State private var viewModel: FileBrowserViewModel
    @State private var showUpload = false
    @State private var textPrompt: TextPrompt?
    @State private var promptText = ""
    @State private var actionEntry: FileEntry?
    @State private var editorEntry: FileEntry?
    private let host: Host
    private let dependencies: AppDependencies

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        self.dependencies = dependencies
        _viewModel = State(initialValue: FileBrowserViewModel(host: host, dependencies: dependencies))
    }

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
            toolbar
            if let transfer = viewModel.transfer { transferBar(transfer) }
            if let url = viewModel.downloadedURL { downloadedBar(url) }
            content
        }
        .padding(.bottom, ConnSpacing.md)
        .task { await viewModel.load() }
        .fileImporter(isPresented: $showUpload, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                Task { await viewModel.upload(from: url) }
            }
        }
        .navigationDestination(item: $editorEntry) { entry in
            FileEditorView(host: host, dependencies: dependencies, entry: entry)
        }
        .confirmationDialog(actionEntry?.name ?? "", isPresented: actionBinding, presenting: actionEntry) { entry in
            fileActions(entry)
        }
        .alert(L("删除"), isPresented: deletionBinding, presenting: viewModel.pendingDeletion) { entry in
            Button("删除 \(entry.name)", role: .destructive) { Task { await viewModel.confirmDeletion() } }
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

    // MARK: - 顶部

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack(spacing: ConnSpacing.sm) {
                Button { Task { await viewModel.goUp() } } label: {
                    Image(systemName: "chevron.up").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(viewModel.canGoUp ? .connAccent : .connMuted)
                }
                .disabled(!viewModel.canGoUp)
                Text(viewModel.currentPath)
                    .font(.connData(.footnote)).foregroundStyle(.connInk).lineLimit(1).truncationMode(.head)
                Spacer()
            }
            HStack(spacing: ConnSpacing.sm) {
                iconButton("square.and.arrow.up", L("上传")) { showUpload = true }
                iconButton("folder.badge.plus", L("新建")) { promptText = ""; textPrompt = .mkdir }
                iconButton(viewModel.showHidden ? "eye" : "eye.slash",
                           viewModel.showHidden ? L("隐藏文件") : L("显示隐藏")) { viewModel.showHidden.toggle() }
                iconButton("arrow.clockwise", L("刷新")) { Task { await viewModel.refresh() } }
                Spacer()
            }
        }
        .padding(.horizontal, ConnSpacing.page)
    }

    private func iconButton(_ systemName: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemName).font(.system(size: 16))
                Text(label).font(.system(size: 9))
            }
            .foregroundStyle(.connAccent)
            .frame(width: 56, height: 40)
            .connSurface(cornerRadius: ConnRadius.control)
        }
        .buttonStyle(ConnPressStyle())
    }

    private func transferBar(_ transfer: FileTransferState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(transfer.direction == .download ? "下载" : "上传") \(transfer.name) · \(Int(transfer.progress * 100))%")
                .font(.connFootnote).foregroundStyle(.connMuted)
            ProgressView(value: transfer.progress).tint(.connAccent)
        }
        .padding(.horizontal, ConnSpacing.page)
    }

    private func downloadedBar(_ url: URL) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.connGood)
            Text("已下载 \(url.lastPathComponent)").font(.connFootnote).foregroundStyle(.connInk)
            Spacer()
            ShareLink(item: url) { Text(L("分享")).font(.connFootnote).foregroundStyle(.connAccent) }
            Button { viewModel.downloadedURL = nil } label: {
                Image(systemName: "xmark").font(.footnote).foregroundStyle(.connMuted)
            }
        }
        .padding(.horizontal, ConnSpacing.cardPadding).padding(.vertical, ConnSpacing.sm)
        .connSurface(cornerRadius: ConnRadius.card)
        .padding(.horizontal, ConnSpacing.page)
    }

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
            LazyVStack(spacing: ConnSpacing.xs) {
                if viewModel.visibleEntries.isEmpty {
                    Text(L("空目录")).font(.connSubheadline).foregroundStyle(.connMuted)
                        .padding(.vertical, ConnSpacing.xl)
                }
                ForEach(viewModel.visibleEntries) { entry in
                    row(entry)
                }
            }
            .padding(.horizontal, ConnSpacing.page)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func row(_ entry: FileEntry) -> some View {
        Button {
            if entry.isDirectory {
                Task { await viewModel.enter(entry) }
            } else {
                actionEntry = entry
            }
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: icon(for: entry.kind))
                    .font(.system(size: 17)).foregroundStyle(entry.isDirectory ? .connAccent : .connMuted)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.connBody).foregroundStyle(.connInk).lineLimit(1)
                    Text(subtitle(entry)).font(.connData(.caption2)).foregroundStyle(.connMuted).lineLimit(1)
                }
                Spacer(minLength: ConnSpacing.xs)
                Image(systemName: entry.isDirectory ? "chevron.right" : "ellipsis")
                    .font(.footnote).foregroundStyle(.connMuted)
            }
            .padding(.horizontal, ConnSpacing.cardPadding).padding(.vertical, 10)
            .connSurface(cornerRadius: ConnRadius.card)
        }
        .buttonStyle(ConnPressStyle())
    }

    @ViewBuilder
    private func fileActions(_ entry: FileEntry) -> some View {
        Button(L("编辑")) { editorEntry = entry }
        Button(L("下载")) { Task { await viewModel.download(entry) } }
        Button(L("重命名")) { promptText = entry.name; textPrompt = .rename(entry) }
        Button(L("修改权限")) { promptText = entry.octalPermissions ?? "644"; textPrompt = .chmod(entry) }
        Button(L("删除"), role: .destructive) { viewModel.pendingDeletion = entry }
        Button(L("取消"), role: .cancel) {}
    }

    // MARK: - 辅助

    private func handlePrompt() {
        let prompt = textPrompt
        textPrompt = nil
        switch prompt {
        case .mkdir:
            Task { await viewModel.createDirectory(named: promptText) }
        case let .rename(entry):
            Task { await viewModel.rename(entry, to: promptText) }
        case let .chmod(entry):
            Task { await viewModel.chmod(entry, octal: promptText) }
        case nil:
            break
        }
    }

    private func icon(for kind: FileKind) -> String {
        switch kind {
        case .directory: "folder.fill"
        case .file: "doc"
        case .symlink: "link"
        case .other: "questionmark.square.dashed"
        }
    }

    private func subtitle(_ entry: FileEntry) -> String {
        var parts: [String] = []
        if !entry.isDirectory {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .binary))
        }
        parts.append(entry.permissionString)
        if let date = entry.modifiedAt {
            parts.append(Self.dateFormatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = ConnLanguage.currentLocale
        formatter.dateFormat = "yy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 绑定

    private var promptTitle: String {
        switch textPrompt {
        case .mkdir: L("新建文件夹")
        case .rename: L("重命名")
        case .chmod: L("修改权限（八进制）")
        case nil: ""
        }
    }

    private var promptPlaceholder: String {
        switch textPrompt {
        case .chmod: L("如 644")
        default: L("名称")
        }
    }

    private var actionBinding: Binding<Bool> {
        Binding(get: { actionEntry != nil }, set: { if !$0 { actionEntry = nil } })
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { viewModel.pendingDeletion != nil }, set: { if !$0 { viewModel.pendingDeletion = nil } })
    }

    private var promptBinding: Binding<Bool> {
        Binding(get: { textPrompt != nil }, set: { if !$0 { textPrompt = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { viewModel.actionMessage != nil }, set: { if !$0 { viewModel.actionMessage = nil } })
    }
}
