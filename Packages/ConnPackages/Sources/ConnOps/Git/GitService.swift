import ConnKit
import ConnSSH
import Foundation

/// Git 操作错误
public struct GitOpError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }
    public var errorDescription: String? { message }
}

/// 远端 Git 核心服务（POSIX Shell CLI 驱动，零外部庞大 C 依赖）
public actor GitService {
    private let session: any SSHSession

    public init(session: any SSHSession) {
        self.session = session
    }

    // MARK: - 仓库探测

    /// 探测指定路径是否处于 Git 仓库工作树内，并返回仓库根目录路径。
    /// 若不在仓库内或未安装 git，返回 nil。
    public func probeRepoRoot(at path: String) async -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd: String
        if trimmed.isEmpty {
            cmd = "git rev-parse --show-toplevel 2>/dev/null"
        } else {
            cmd = "cd \(shellQuote(trimmed)) 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null"
        }
        guard let result = try? await session.exec(cmd, timeout: .seconds(5)),
              result.isSuccess
        else {
            return nil
        }
        let root = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// 解析当前有效的工作目录路径。若 hint 为空，回退执行远程 `pwd` 获取当前用户目录。
    public func resolveWorkingDirectory(hint: String?) async -> String {
        let trimmed = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if let result = try? await session.exec("pwd", timeout: .seconds(3)), result.isSuccess {
            let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        return "~"
    }

    // MARK: - 状态查询

    /// 获取仓库当前状态（分支、领先/落后、变更文件）。
    public func status(at repoRoot: String) async throws -> GitRepoStatus {
        let cmd = "cd \(shellQuote(repoRoot)) && git status --porcelain=v1 -b"
        let result = try await session.exec(cmd, timeout: .seconds(10))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "获取 Git 状态失败" : result.stderrText)
        }
        return GitPorcelainParser.parse(stdout: result.stdoutText, rootPath: repoRoot)
    }

    // MARK: - 分支查询与切换

    /// 列出本地与远程分支。
    public func branches(at repoRoot: String) async throws -> [GitBranch] {
        let cmd = "cd \(shellQuote(repoRoot)) && git branch -a --format='%(refname:short)|%(refname)|%(HEAD)'"
        let result = try await session.exec(cmd, timeout: .seconds(10))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "获取分支列表失败" : result.stderrText)
        }

        var branches: [GitBranch] = []
        let lines = result.stdoutText.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.components(separatedBy: "|")
            guard let name = parts.first?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty,
                  !name.contains(" -> ")
            else { continue }
            let ref = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if ref.hasSuffix("/HEAD") { continue }
            let isCurrent = parts.count > 2 && parts[2].trimmingCharacters(in: .whitespaces) == "*"
            let isRemote = ref.hasPrefix("refs/remotes/")
            branches.append(GitBranch(name: name, isCurrent: isCurrent, isRemote: isRemote))
        }
        return branches
    }

    /// 切换分支。
    public func checkout(branch: String, at repoRoot: String) async throws {
        let cmd = "cd \(shellQuote(repoRoot)) && git checkout \(shellQuote(branch))"
        let result = try await session.exec(cmd, timeout: .seconds(15))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "切换分支失败" : result.stderrText)
        }
    }

    /// 列出远端及 URL。
    public func remotes(at repoRoot: String) async throws -> [GitRemote] {
        let cmd = "cd \(shellQuote(repoRoot)) && git remote -v"
        let result = try await session.exec(cmd, timeout: .seconds(10))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "获取远端信息失败" : result.stderrText)
        }
        var remotes: [GitRemote] = []
        var seen = Set<String>()
        for line in result.stdoutText.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2 else { continue }
            let name = String(parts[0])
            guard seen.insert(name).inserted else { continue }
            remotes.append(GitRemote(name: name, url: String(parts[1])))
        }
        return remotes
    }

    public func fetch(at repoRoot: String) async throws {
        try await run(
            "cd \(shellQuote(repoRoot)) && git fetch --prune",
            timeout: .seconds(60),
            failure: "拉取远端引用失败"
        )
    }

    /// 仅允许 fast-forward，避免移动端直接制造合并冲突。
    public func pullFastForwardOnly(at repoRoot: String) async throws {
        try await run(
            "cd \(shellQuote(repoRoot)) && git pull --ff-only",
            timeout: .seconds(60),
            failure: "拉取失败"
        )
    }

    public func push(at repoRoot: String) async throws {
        try await run(
            "cd \(shellQuote(repoRoot)) && git push",
            timeout: .seconds(60),
            failure: "推送失败"
        )
    }

    public func stashCount(at repoRoot: String) async throws -> Int {
        let cmd = "cd \(shellQuote(repoRoot)) && git stash list --format='%gd'"
        let result = try await session.exec(cmd, timeout: .seconds(10))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "获取 Stash 列表失败" : result.stderrText)
        }
        return result.stdoutText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    public func createBranch(
        name: String,
        at repoRoot: String,
        checkout: Bool = true
    ) async throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw GitOpError("分支名称不能为空")
        }
        let verb = checkout ? "checkout -b" : "branch"
        try await run(
            "cd \(shellQuote(repoRoot)) && git \(verb) \(shellQuote(clean))",
            timeout: .seconds(15),
            failure: "创建分支失败"
        )
    }

    public func deleteBranch(name: String, at repoRoot: String, force: Bool = false) async throws {
        let flag = force ? "-D" : "-d"
        try await run(
            "cd \(shellQuote(repoRoot)) && git branch \(flag) \(shellQuote(name))",
            timeout: .seconds(15),
            failure: "删除分支失败"
        )
    }

    // MARK: - Diff 查询

    /// 获取指定文件的 Unified Diff。对于未跟踪新文件，会自动通过 `/dev/null` 对比生成全新 diff。
    public func diff(for file: GitFileChange, at repoRoot: String) async throws -> GitFileDiff {
        let quotedPath = shellQuote(file.path)
        let cmd: String

        if file.isUntracked {
            // 未跟踪文件：将 /dev/null 与实际文件对比
            cmd = "cd \(shellQuote(repoRoot)) && git diff --no-index -- /dev/null \(quotedPath)"
        } else if file.isStaged {
            // 已暂存：对比暂存区与 HEAD
            cmd = "cd \(shellQuote(repoRoot)) && git diff --cached -U3 -- \(quotedPath)"
        } else {
            // 工作区：对比工作区与暂存区/HEAD
            cmd = "cd \(shellQuote(repoRoot)) && git diff -U3 -- \(quotedPath)"
        }

        let result = try await session.exec(cmd, timeout: .seconds(15))
        // 注意：`git diff --no-index` 遇到差异时退出码为 1，属于正常行为
        let rawDiff = result.stdoutText
        return GitDiffParser.parse(rawDiff: rawDiff, filePath: file.path)
    }

    // MARK: - 常用写操作

    /// 暂存文件（git add）。
    public func stage(files: [String], at repoRoot: String) async throws {
        guard !files.isEmpty else { return }
        let paths = files.map(shellQuote).joined(separator: " ")
        let cmd = "cd \(shellQuote(repoRoot)) && git add -A -- \(paths)"
        let result = try await session.exec(cmd, timeout: .seconds(15))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "暂存失败" : result.stderrText)
        }
    }

    public func stageAll(at repoRoot: String) async throws {
        try await run(
            "cd \(shellQuote(repoRoot)) && git add -A",
            timeout: .seconds(20),
            failure: "暂存全部修改失败"
        )
    }

    public func unstageAll(at repoRoot: String) async throws {
        try await run(
            "cd \(shellQuote(repoRoot)) && git reset",
            timeout: .seconds(20),
            failure: "取消全部暂存失败"
        )
    }

    /// 取消暂存（git restore --staged）。
    public func unstage(files: [String], at repoRoot: String) async throws {
        guard !files.isEmpty else { return }
        let paths = files.map(shellQuote).joined(separator: " ")
        let cmd = "cd \(shellQuote(repoRoot)) && git restore --staged -- \(paths)"
        let result = try await session.exec(cmd, timeout: .seconds(15))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "取消暂存失败" : result.stderrText)
        }
    }

    /// 放弃工作区修改（git restore 或针对未跟踪文件的 rm -rf）。
    public func discard(file: GitFileChange, at repoRoot: String) async throws {
        let quotedPath = shellQuote(file.path)
        let cmd: String
        if file.isUntracked {
            cmd = "cd \(shellQuote(repoRoot)) && rm -rf \(quotedPath)"
        } else {
            cmd = "cd \(shellQuote(repoRoot)) && git checkout HEAD -- \(quotedPath)"
        }
        let result = try await session.exec(cmd, timeout: .seconds(15))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "放弃更改失败" : result.stderrText)
        }
    }

    /// 提交暂存区变更。
    public func commit(message: String, at repoRoot: String) async throws {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw GitOpError("提交信息不能为空")
        }
        let cmd = "cd \(shellQuote(repoRoot)) && git commit -m \(shellQuote(clean))"
        let result = try await session.exec(cmd, timeout: .seconds(20))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "提交失败" : result.stderrText)
        }
    }

    /// 修改最近一次提交；仅改变提交信息，不改变索引内容。
    public func amendCommit(message: String, at repoRoot: String) async throws {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw GitOpError("提交信息不能为空")
        }
        try await run(
            "cd \(shellQuote(repoRoot)) && git commit --amend -m \(shellQuote(clean))",
            timeout: .seconds(20),
            failure: "修改提交失败"
        )
    }

    // MARK: - 提交历史

    /// 获取最近的提交记录列表。
    public func log(at repoRoot: String, limit: Int = 50) async throws -> [GitCommit] {
        // 使用 %x1f (Unit Separator) 分隔字段: hash, shortHash, author, isoDate, relativeDate, subject
        let format = "%H%x1f%h%x1f%an%x1f%ad%x1f%ar%x1f%s"
        let cmd = "cd \(shellQuote(repoRoot)) && git log -n \(limit) --pretty=format:\(shellQuote(format)) --date=iso"
        let result = try await session.exec(cmd, timeout: .seconds(15))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "获取提交记录失败" : result.stderrText)
        }
        return Self.parseLog(result.stdoutText)
    }

    /// 获取特定 commit 的变更详情（支持重命名/拷贝检测与补丁 diff）。
    public func showCommitDiff(hash: String, at repoRoot: String) async throws -> [GitFileDiff] {
        let cmd = "cd \(shellQuote(repoRoot)) && git show -M -C --patch --unified=3 \(shellQuote(hash))"
        let result = try await session.exec(cmd, timeout: .seconds(20))
        guard result.isSuccess else {
            throw GitOpError(result.stderrText.isEmpty ? "获取提交改动详情失败" : result.stderrText)
        }
        return GitDiffParser.parseMultiFile(rawDiff: result.stdoutText)
    }

    /// 解析 git log 格式化输出为 [GitCommit]
    public static func parseLog(_ text: String) -> [GitCommit] {
        let lines = text.components(separatedBy: .newlines)
        var commits: [GitCommit] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 6 else { continue }
            let commit = GitCommit(
                hash: parts[0],
                shortHash: parts[1],
                author: parts[2],
                date: parts[3],
                relativeDate: parts[4],
                message: parts[5]
            )
            commits.append(commit)
        }
        return commits
    }

    // MARK: - 辅助

    private func run(
        _ command: String,
        timeout: Duration,
        failure: String
    ) async throws {
        let result = try await session.exec(command, timeout: timeout)
        guard result.isSuccess else {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitOpError(detail.isEmpty ? failure : detail)
        }
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
