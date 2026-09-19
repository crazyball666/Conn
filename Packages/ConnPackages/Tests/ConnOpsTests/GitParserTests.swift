import Foundation
import Testing
@testable import ConnOps

struct GitParserTests {
    @Test("解析 git status porcelain 输出")
    func parsePorcelainStatus() {
        let sample = """
        ## main...origin/main [ahead 1, behind 2]
        M  staged_modified.swift
         M unstaged_modified.swift
        A  staged_new.swift
        ?? untracked.swift
        D  deleted.swift
        R  new_name.swift -> old_name.swift
        """

        let status = GitPorcelainParser.parse(stdout: sample, rootPath: "/workspace/repo")

        #expect(status.rootPath == "/workspace/repo")
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.aheadCount == 1)
        #expect(status.behindCount == 2)
        #expect(status.changes.count == 6)

        // staged_modified
        let stagedMod = status.changes.first { $0.path == "staged_modified.swift" }
        #expect(stagedMod?.isStaged == true)
        #expect(stagedMod?.indexStatus == .modified)

        // unstaged_modified
        let unstagedMod = status.changes.first { $0.path == "unstaged_modified.swift" }
        #expect(unstagedMod?.hasUnstagedChanges == true)
        #expect(unstagedMod?.worktreeStatus == .modified)

        // untracked
        let untracked = status.changes.first { $0.path == "untracked.swift" }
        #expect(untracked?.isUntracked == true)

        // rename
        let rename = status.changes.first { $0.path == "old_name.swift" }
        #expect(rename?.oldPath == "new_name.swift")
    }

    @Test("解析无上游或新仓库状态")
    func parseInitialOrDetachedStatus() {
        let sample = """
        ## Initial commit on feature/my-branch
        ?? first_file.txt
        """

        let status = GitPorcelainParser.parse(stdout: sample, rootPath: "/repo")
        #expect(status.branch == "feature/my-branch")
        #expect(status.upstream == nil)
        #expect(status.aheadCount == 0)
        #expect(status.changes.count == 1)
    }

    @Test("解析 Unified Diff 块与行号")
    func parseUnifiedDiff() {
        let sample = """
        diff --git a/test.txt b/test.txt
        index 1234..5678 100644
        --- a/test.txt
        +++ b/test.txt
        @@ -1,3 +1,4 @@
         line 1
        -line 2
        +line 2 edited
        +line 3 added
         line 4
        """

        let diff = GitDiffParser.parse(rawDiff: sample, filePath: "test.txt")
        #expect(diff.filePath == "test.txt")
        #expect(diff.hunks.count == 1)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 1)

        let hunk = diff.hunks[0]
        #expect(hunk.lines.count == 5)
        #expect(hunk.lines[0].type == .context)
        #expect(hunk.lines[1].type == .deletion)
        #expect(hunk.lines[2].type == .addition)
        #expect(hunk.lines[3].type == .addition)
        #expect(hunk.lines[4].type == .context)
    }
}
