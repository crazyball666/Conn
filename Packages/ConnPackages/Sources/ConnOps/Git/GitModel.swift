import Foundation

/// Git 文件状态
public enum GitFileStatus: String, Sendable, Equatable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case ignored = "!"
    case unmerged = "U"

    public var displayLabel: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "U"
        case .ignored: "I"
        case .unmerged: "!"
        }
    }
}

/// 单个文件的 Git 变更条目
public struct GitFileChange: Identifiable, Sendable, Equatable {
    public var id: String { path }
    /// 文件在仓库中的相对路径
    public let path: String
    /// 原路径（用于重命名）
    public let oldPath: String?
    /// 暂存区状态（Index）
    public let indexStatus: GitFileStatus?
    /// 工作区状态（Worktree）
    public let worktreeStatus: GitFileStatus?

    public init(
        path: String,
        oldPath: String? = nil,
        indexStatus: GitFileStatus?,
        worktreeStatus: GitFileStatus?
    ) {
        self.path = path
        self.oldPath = oldPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
    }

    /// 是否已暂存
    public var isStaged: Bool {
        guard let index = indexStatus else { return false }
        return index != .untracked && index != .ignored
    }

    /// 是否有未暂存工作区改动
    public var hasUnstagedChanges: Bool {
        guard let worktree = worktreeStatus else { return false }
        return worktree != .ignored
    }

    /// 是否为未跟踪新文件
    public var isUntracked: Bool {
        indexStatus == .untracked || worktreeStatus == .untracked
    }

    /// 主要展示的状态
    public var primaryStatus: GitFileStatus {
        worktreeStatus ?? indexStatus ?? .modified
    }
}

/// 仓库状态概览
public struct GitRepoStatus: Sendable, Equatable {
    /// 当前工作目录所在的 Git 根目录绝对路径
    public let rootPath: String
    /// 当前分支名（如 detached 则为 HEAD commit 摘要）
    public let branch: String
    /// 关联的上游追踪分支（如 origin/main）
    public let upstream: String?
    /// 领先上游提交数
    public let aheadCount: Int
    /// 落后上游提交数
    public let behindCount: Int
    /// 变更文件列表
    public let changes: [GitFileChange]

    public init(
        rootPath: String,
        branch: String,
        upstream: String? = nil,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        changes: [GitFileChange] = []
    ) {
        self.rootPath = rootPath
        self.branch = branch
        self.upstream = upstream
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.changes = changes
    }

    public var isClean: Bool {
        changes.isEmpty
    }

    public var stagedChanges: [GitFileChange] {
        changes.filter { $0.isStaged }
    }

    public var unstagedChanges: [GitFileChange] {
        changes.filter { $0.hasUnstagedChanges }
    }

    public var untrackedChanges: [GitFileChange] {
        changes.filter { $0.isUntracked }
    }
}

/// Git 分支
public struct GitBranch: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool

    public init(name: String, isCurrent: Bool, isRemote: Bool) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
    }
}

/// Diff 单行类型
public enum GitDiffLineType: Sendable, Equatable {
    case context
    case addition
    case deletion
    case header
}

/// Diff 单行
public struct GitDiffLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public let type: GitDiffLineType
    public let text: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public init(
        id: Int,
        type: GitDiffLineType,
        text: String,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// Diff 分块（Hunk）
public struct GitDiffHunk: Identifiable, Sendable, Equatable {
    public var id: String { header }
    public let header: String
    public let lines: [GitDiffLine]

    public init(header: String, lines: [GitDiffLine]) {
        self.header = header
        self.lines = lines
    }
}

/// 单个文件的完整 Diff
public struct GitFileDiff: Sendable, Equatable {
    public let filePath: String
    public let hunks: [GitDiffHunk]
    public let additions: Int
    public let deletions: Int

    public init(
        filePath: String,
        hunks: [GitDiffHunk] = [],
        additions: Int = 0,
        deletions: Int = 0
    ) {
        self.filePath = filePath
        self.hunks = hunks
        self.additions = additions
        self.deletions = deletions
    }
}
