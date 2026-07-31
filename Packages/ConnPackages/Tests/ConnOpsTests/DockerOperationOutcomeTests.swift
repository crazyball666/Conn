import ConnOps
import ConnSSH
import Foundation
import Testing

@Suite("Docker 写操作结果")
struct DockerOperationOutcomeTests {
    @Test("已知失败保留退出码与远端 stderr")
    func knownFailureKeepsRemoteReason() {
        let result = ExecResult(
            exitCode: 1,
            stdout: Data("private stdout".utf8),
            stderr: Data("volume name already in use\n".utf8)
        )

        #expect(
            DockerOperationOutcome(result: result)
                == .knownFailure(
                    exitCode: 1,
                    remoteMessage: "volume name already in use"
                )
        )
    }

    @Test("空白 stderr 不会回退展示可能含敏感信息的 stdout")
    func emptyStderrDoesNotExposeStdout() {
        let result = ExecResult(
            exitCode: 23,
            stdout: Data("TOKEN=secret".utf8),
            stderr: Data(" \n".utf8)
        )

        #expect(
            DockerOperationOutcome(result: result)
                == .knownFailure(exitCode: 23, remoteMessage: nil)
        )
    }
}
