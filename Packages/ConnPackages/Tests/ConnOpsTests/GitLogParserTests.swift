import Foundation
import Testing
@testable import ConnOps

struct GitLogParserTests {
    @Test("解析标准格式 git log 输出")
    func parseGitLogOutput() {
        let sample = """
        a1b2c3d4e5f67890123456789abcdef012345678\u{1F}a1b2c3d\u{1F}Alice\u{1F}2026-09-20 18:00:00 +0800\u{1F}2 hours ago\u{1F}feat: support mobile git log\u{1F}HEAD -> main, origin/main
        f9e8d7c6b5a43210987654321fedcba098765432\u{1F}f9e8d7c\u{1F}Bob\u{1F}2026-09-20 16:30:00 +0800\u{1F}3 hours ago\u{1F}fix: handle null path gracefully
        """

        let commits = GitService.parseLog(sample)
        #expect(commits.count == 2)

        let first = commits[0]
        #expect(first.hash == "a1b2c3d4e5f67890123456789abcdef012345678")
        #expect(first.shortHash == "a1b2c3d")
        #expect(first.author == "Alice")
        #expect(first.relativeDate == "2 hours ago")
        #expect(first.message == "feat: support mobile git log")
        #expect(first.refs == ["HEAD -> main", "origin/main"])

        let second = commits[1]
        #expect(second.shortHash == "f9e8d7c")
        #expect(second.author == "Bob")
        #expect(second.message == "fix: handle null path gracefully")
    }

    @Test("解析空输出返回空数组")
    func parseEmptyLogOutput() {
        let commits = GitService.parseLog("")
        #expect(commits.isEmpty)

        let whitespaceCommits = GitService.parseLog("   \n\n  \n")
        #expect(whitespaceCommits.isEmpty)
    }

    @Test("解析分支列表的当前标记、远程分类和最新提交")
    func parseBranchList() {
        let sample = [
            "main\trefs/heads/main\t*\tfeat: current\t1700000000\t[ahead 1]",
            "feature/x\trefs/heads/feature/x\t\tfix: local\t1700000000\t[behind 2]",
            "origin/main\trefs/remotes/origin/main\t\tfeat: remote\t1700000000\t",
            "origin/HEAD\trefs/remotes/origin/HEAD\t\t\t1700000000\t",
        ].joined(separator: "\n")

        let branches = GitService.parseBranches(sample)
        #expect(branches.count == 3)
        #expect(branches[0].name == "main")
        #expect(branches[0].isCurrent)
        #expect(!branches[0].isRemote)
        #expect(branches[0].latestCommit == "feat: current")
        #expect(branches[0].latestCommitDate != nil)
        #expect(branches[0].aheadCount == 1)
        #expect(branches[1].name == "feature/x")
        #expect(!branches[1].isRemote)
        #expect(branches[1].latestCommit == "fix: local")
        #expect(branches[1].behindCount == 2)
        #expect(branches[2].name == "origin/main")
        #expect(branches[2].isRemote)
    }
}
