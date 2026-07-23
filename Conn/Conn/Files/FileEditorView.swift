import ConnKit
import ConnSSH
import ConnUI
import Observation
import SwiftUI

/// 文本文件在线编辑 ViewModel（Phase 6）。
@Observable
@MainActor
final class FileEditorViewModel {
    enum LoadState: Equatable {
        case loading
        case editing
        case readOnly(String)
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    var content = ""
    private(set) var isSaving = false
    var saveMessage: String?

    private let host: Host
    private let connectionManager: ConnectionManager
    let entry: FileEntry
    private let maxEditBytes: UInt64 = 1024 * 1024

    init(host: Host, dependencies: AppDependencies, entry: FileEntry) {
        self.host = host
        connectionManager = dependencies.connectionManager
        self.entry = entry
    }

    func load() async {
        if entry.size > maxEditBytes {
            loadState = .readOnly(L("文件超过 1MB，暂不支持在线编辑。请下载后查看。"))
            return
        }
        do {
            let data = try await filesystem().readAll(entry.path)
            if data.contains(0) {
                loadState = .readOnly(L("二进制文件，无法以文本方式编辑。"))
                return
            }
            guard let text = String(bytes: data, encoding: .utf8) else {
                loadState = .readOnly(L("非 UTF-8 编码，暂不支持在线编辑。"))
                return
            }
            content = text
            loadState = .editing
        } catch {
            loadState = .failed(friendly(error))
        }
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            // 以「打开既有文件 + 截断写入」保持同一 inode → 权限/属主不变。
            try await filesystem().writeAll(Data(content.utf8), to: entry.path)
            saveMessage = L("已保存")
        } catch {
            saveMessage = "保存失败：\(friendly(error))"
        }
    }

    private func filesystem() async throws -> any RemoteFileSystem {
        try await connectionManager.session(for: host).sftp()
    }

    private func friendly(_ error: Error) -> String {
        if let sshError = error as? SSHError {
            return sshError.diagnosis.split(separator: "\n").first.map(String.init) ?? sshError.diagnosis
        }
        return error.localizedDescription
    }
}

/// 文本文件编辑器（Phase 6）。monospace `TextEditor`；语法高亮是 P1。
struct FileEditorView: View {
    @State private var viewModel: FileEditorViewModel

    init(host: Host, dependencies: AppDependencies, entry: FileEntry) {
        _viewModel = State(initialValue: FileEditorViewModel(host: host, dependencies: dependencies, entry: entry))
    }

    var body: some View {
        content
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(viewModel.entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load() }
            .toolbar {
                if case .editing = viewModel.loadState {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("保存")) { Task { await viewModel.save() } }
                            .fontWeight(.semibold)
                            .disabled(viewModel.isSaving)
                    }
                }
            }
            .alert(L("保存"), isPresented: saveBinding) {
                Button(L("好"), role: .cancel) { viewModel.saveMessage = nil }
            } message: {
                Text(viewModel.saveMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView(L("读取文件…")).font(.connFootnote).foregroundStyle(.connMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .editing:
            TextEditor(text: $viewModel.content)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.connInk)
                .scrollContentBackground(.hidden)
                .background(Color.connBg)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, ConnSpacing.sm)
        case let .readOnly(message):
            infoState(icon: "doc.plaintext", message: message)
        case let .failed(message):
            infoState(icon: "exclamationmark.triangle", message: message)
        }
    }

    private func infoState(icon: String, message: String) -> some View {
        VStack(spacing: ConnSpacing.sm) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(.connMuted)
            Text(message).font(.connSubheadline).foregroundStyle(.connMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ConnSpacing.page)
    }

    private var saveBinding: Binding<Bool> {
        Binding(get: { viewModel.saveMessage != nil }, set: { if !$0 { viewModel.saveMessage = nil } })
    }
}
