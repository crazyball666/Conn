import Foundation

/// 解析 `git status --porcelain=v1 -b` 输出。
///
/// 典型格式：
/// ```
/// ## main...origin/main [ahead 1, behind 2]
/// M  modified_file.swift
///  M unstaged_file.swift
/// ?? untracked_file.swift
/// D  deleted_file.swift
/// R  new_name.swift -> old_name.swift
/// ```
public enum GitPorcelainParser {
    public static func parse(stdout: String, rootPath: String) -> GitRepoStatus {
        let lines = stdout.components(separatedBy: .newlines)
        var branchName = "HEAD"
        var upstreamName: String?
        var ahead = 0
        var behind = 0
        var changes: [GitFileChange] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if rawLine.hasPrefix("## ") {
                let headerContent = String(rawLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let branchInfo = parseBranchHeader(headerContent)
                branchName = branchInfo.branch
                upstreamName = branchInfo.upstream
                ahead = branchInfo.ahead
                behind = branchInfo.behind
                continue
            }

            guard rawLine.count >= 3 else { continue }
            let chars = Array(rawLine)
            let indexChar = chars[0]
            let worktreeChar = chars[1]
            let filePathSection = String(chars[3...]).trimmingCharacters(in: .whitespaces)

            let indexStatus = GitFileStatus(rawValue: String(indexChar))
            let worktreeStatus = GitFileStatus(rawValue: String(worktreeChar))

            let (path, oldPath) = parseFilePaths(filePathSection)
            changes.append(GitFileChange(
                path: path,
                oldPath: oldPath,
                indexStatus: indexStatus,
                worktreeStatus: worktreeStatus
            ))
        }

        return GitRepoStatus(
            rootPath: rootPath,
            branch: branchName,
            upstream: upstreamName,
            aheadCount: ahead,
            behindCount: behind,
            changes: changes
        )
    }

    private static func parseBranchHeader(_ header: String) -> (branch: String, upstream: String?, ahead: Int, behind: Int) {
        // 例: main...origin/main [ahead 1, behind 2]
        // 或: Initial commit on main
        // 或: No commits yet on main
        // 或: HEAD (no branch)
        var branch = header
        var upstream: String?
        var ahead = 0
        var behind = 0

        var rest = header
        if let bracketStart = rest.firstIndex(of: "["), let bracketEnd = rest.firstIndex(of: "]") {
            let trackerInfo = String(rest[rest.index(after: bracketStart)..<bracketEnd])
            let parts = trackerInfo.components(separatedBy: ",")
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ahead ") {
                    ahead = Int(trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? 0
                } else if trimmed.hasPrefix("behind ") {
                    behind = Int(trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            rest = String(rest[..<bracketStart]).trimmingCharacters(in: .whitespaces)
        }

        if let tripleDot = rest.range(of: "...") {
            branch = String(rest[..<tripleDot.lowerBound]).trimmingCharacters(in: .whitespaces)
            upstream = String(rest[tripleDot.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            if rest.hasPrefix("Initial commit on ") {
                branch = String(rest.dropFirst("Initial commit on ".count))
            } else if rest.hasPrefix("No commits yet on ") {
                branch = String(rest.dropFirst("No commits yet on ".count))
            } else {
                branch = rest
            }
        }

        return (branch, upstream, ahead, behind)
    }

    private static func parseFilePaths(_ section: String) -> (path: String, oldPath: String?) {
        // 针对重命名：`old -> new` 或带引号 `"old" -> "new"`
        if section.contains(" -> ") {
            let parts = section.components(separatedBy: " -> ")
            if parts.count == 2 {
                return (stripQuotes(parts[1]), stripQuotes(parts[0]))
            }
        }
        return (stripQuotes(section), nil)
    }

    private static func stripQuotes(_ str: String) -> String {
        var s = str.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            s.removeFirst()
            s.removeLast()
        }
        return s
    }
}
