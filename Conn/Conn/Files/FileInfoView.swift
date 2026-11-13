import ConnSSH
import ConnUI
import SwiftUI

/// 文件/文件夹基础信息。进入页面时用远端 stat 刷新一次，失败则保留列表快照。
struct FileInfoView: View {
    let viewModel: FileBrowserViewModel
    @State private var entry: FileEntry

    init(entry: FileEntry, viewModel: FileBrowserViewModel) {
        self.viewModel = viewModel
        _entry = State(initialValue: entry)
    }

    var body: some View {
        List {
            Section {
                infoRow(L("名称"), value: entry.name)
                infoRow(L("类型"), value: typeLabel)
                infoRow(
                    L("大小"),
                    value: entry.isDirectory ? "—" : MetricFormat.bytes(Double(entry.size))
                )
                infoRow(L("修改时间"), value: modifiedTime)
            }

            Section(L("路径")) {
                Text(entry.path)
                    .font(.connData(.footnote))
                    .foregroundStyle(.connInk)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("file-info.path")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("信息"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("file-info")
        .task {
            guard !entry.isSymlink else { return }
            if let fresh = try? await viewModel.fileInfo(for: entry) {
                entry = fresh
            }
        }
    }

    private var typeLabel: String {
        switch entry.kind {
        case .directory: L("文件夹")
        case .file: L("普通文件")
        case .symlink: L("符号链接")
        case .other: L("其他")
        }
    }

    private var modifiedTime: String {
        entry.modifiedAt?.formatted(date: .abbreviated, time: .standard) ?? L("未知")
    }

    private func infoRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.connMuted)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 文件/文件夹 POSIX 权限、所有者与用户组。权限只读展示，修改仍走长按菜单的“修改权限”。
struct FilePermissionsView: View {
    let viewModel: FileBrowserViewModel
    @State private var entry: FileEntry

    init(entry: FileEntry, viewModel: FileBrowserViewModel) {
        self.viewModel = viewModel
        _entry = State(initialValue: entry)
    }

    var body: some View {
        List {
            Section {
                permissionRow(L("权限"), value: entry.permissionString)
                permissionRow(L("八进制"), value: entry.octalPermissions.map { "0\($0)" } ?? L("未知"))
            }

            Section(L("权限明细")) {
                permissionRow(L("所有者"), value: bits(for: 6))
                permissionRow(L("用户组"), value: bits(for: 3))
                permissionRow(L("其他"), value: bits(for: 0))
            }

            Section {
                permissionRow("UID", value: idLabel(entry.uid))
                permissionRow("GID", value: idLabel(entry.gid))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("权限"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("file-permissions")
        .task {
            guard !entry.isSymlink else { return }
            if let fresh = try? await viewModel.fileInfo(for: entry) {
                entry = fresh
            }
        }
    }

    private func bits(for shift: UInt32) -> String {
        guard let mode = entry.permissions else { return "—" }
        let value = (mode >> shift) & 0o7
        var result = ""
        result += value & 0o4 != 0 ? "r" : "-"
        result += value & 0o2 != 0 ? "w" : "-"
        result += value & 0o1 != 0 ? "x" : "-"
        return result
    }

    private func idLabel(_ id: UInt32?) -> String {
        guard let id else { return L("未知") }
        return String(id)
    }

    private func permissionRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.connData(.footnote))
                .foregroundStyle(.connMuted)
        }
    }
}
