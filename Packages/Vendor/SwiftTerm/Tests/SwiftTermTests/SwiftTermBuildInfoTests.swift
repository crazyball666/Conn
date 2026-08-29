import Testing
import SwiftTerm

struct SwiftTermBuildInfoTests {
    @Test func vendoredBuildInfoIsDeterministic() {
        #expect(SwiftTermBuildInfo.branch == nil)
        #expect(SwiftTermBuildInfo.tag == "v1.19.0")
        #expect(SwiftTermBuildInfo.commit == "464df5207fc2432e16c9a23abe538187196daf5f")
        #expect(SwiftTermBuildInfo.hasUncommittedChanges == false)
        #expect(SwiftTermBuildInfo.version == "v1.19.0")
    }

    @Test func versionContainsTheBestAvailableIdentifier() {
        let expectedBase = SwiftTermBuildInfo.tag
            ?? SwiftTermBuildInfo.commit.map { String($0.prefix(12)) }
            ?? "unknown"

        #expect(SwiftTermBuildInfo.version.hasPrefix(expectedBase))
        #expect(
            SwiftTermBuildInfo.version.hasSuffix("-modified")
                == (SwiftTermBuildInfo.hasUncommittedChanges == true)
        )
    }

    @Test func commitIsAFullGitObjectIdentifierWhenAvailable() {
        if let commit = SwiftTermBuildInfo.commit {
            #expect(commit.count == 40 || commit.count == 64)
            #expect(commit.allSatisfy { $0.isHexDigit })
        }
    }
}
