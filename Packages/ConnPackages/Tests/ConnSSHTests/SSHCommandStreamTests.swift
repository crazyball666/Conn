import ConnSSH
import Foundation
import Testing

@Suite("SSHCommandStream")
struct SSHCommandStreamTests {
    private let endpoint = SSHEndpoint(host: "demo.local", port: 22)

    private func session(
        response: MockSSHTransport.CommandResponse
    ) async throws -> any SSHSession {
        let transport = MockSSHTransport(behavior: .init(commandResponses: [
            "docker pull bad:tag": response
        ]))
        return try await transport.connect(
            endpoint,
            username: "root",
            auth: .password("x"),
            hostKeyPolicy: .tofu
        )
    }

    @Test("流输出与非零退出都可观察")
    func preservesOutputAndExitCode() async throws {
        let session = try await session(response: .init(
            streamChunks: [Data("layer 1\n".utf8), Data("layer 2\n".utf8)],
            exitCode: 17
        ))

        let stream = try await session.execCommandStream("docker pull bad:tag", timeout: .seconds(30))
        let text = try await collect(stream.output)
        let result = try await stream.result()

        #expect(text == "layer 1\nlayer 2\n")
        #expect(result.exitCode == 17)
    }

    @Test("成功流返回完整输出和零退出码")
    func returnsSuccessAfterStreamingOutput() async throws {
        let session = try await session(response: .init(
            streamChunks: [Data("pulling ".utf8), Data("complete\n".utf8)]
        ))

        let stream = try await session.execCommandStream("docker pull bad:tag", timeout: .seconds(30))
        let text = try await collect(stream.output)
        let first = try await stream.result()
        let second = try await stream.result()

        #expect(text == "pulling complete\n")
        #expect(first == ExecResult(exitCode: 0, stdout: Data("pulling complete\n".utf8), stderr: Data()))
        #expect(second == first)
    }

    @Test("公共结果闭包只执行一次")
    func invokesPublicResultClosureOnlyOnce() async throws {
        let calls = ResultCallCounter()
        let expected = ExecResult(exitCode: 0, stdout: Data("done".utf8), stderr: Data())
        let stream = SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) {
            await calls.increment()
            return expected
        }

        let first = try await stream.result()
        let second = try await stream.result()

        #expect(first == expected)
        #expect(second == expected)
        #expect(await calls.count == 1)
    }

    @Test("流中断后已到达的输出仍可读取")
    func preservesOutputWhenStreamFails() async throws {
        let session = try await session(response: .init(
            streamChunks: [Data("layer 1\n".utf8)],
            streamFailure: .channelClosed
        ))

        let stream = try await session.execCommandStream("docker pull bad:tag", timeout: .seconds(30))
        let collected = await collectIncludingFailure(stream.output)

        #expect(collected.text == "layer 1\n")
        #expect(collected.error as? SSHError == .channelClosed)
        await #expect(throws: SSHError.channelClosed) {
            _ = try await stream.result()
        }
    }

    @Test("结果等待超过 timeout 时抛命令超时且保留输出")
    func timesOutAfterStreamingOutput() async throws {
        let session = try await session(response: .init(
            streamChunks: [Data("layer 1\n".utf8), Data("layer 2\n".utf8)],
            streamChunkDelay: .milliseconds(100)
        ))

        let stream = try await session.execCommandStream("docker pull bad:tag", timeout: .milliseconds(50))
        let collected = await collectIncludingFailure(stream.output)

        #expect(collected.text == "layer 1\n")
        #expect(collected.error as? SSHError == .commandTimeout(endpoint: endpoint, seconds: 1))
        await #expect(throws: SSHError.commandTimeout(endpoint: endpoint, seconds: 1)) {
            _ = try await stream.result()
        }
    }

    @Test("fallback 输出读取被取消会取消后台生产者")
    func cancellingFallbackOutputCancelsProducer() async throws {
        let session = try await session(response: .init(
            streamChunks: nil,
            streamChunkDelay: .seconds(1),
            stdout: "first\nsecond\n"
        ))
        let stream = try await session.execCommandStream("docker pull bad:tag", timeout: .seconds(30))
        let firstChunk = FirstChunkLatch()
        let reader = Task {
            do {
                for try await _ in stream.output {
                    await firstChunk.receive()
                }
            } catch {}
        }

        await firstChunk.wait()
        reader.cancel()
        await reader.value

        await #expect(throws: CancellationError.self) {
            _ = try await stream.result()
        }
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> String {
        var output = Data()
        for try await chunk in stream {
            output.append(chunk)
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func collectIncludingFailure(
        _ stream: AsyncThrowingStream<Data, Error>
    ) async -> (text: String, error: (any Error)?) {
        var output = Data()
        do {
            for try await chunk in stream {
                output.append(chunk)
            }
            return (String(decoding: output, as: UTF8.self), nil)
        } catch {
            return (String(decoding: output, as: UTF8.self), error)
        }
    }
}

private actor ResultCallCounter {
    private var calls = 0

    var count: Int { calls }

    func increment() {
        calls += 1
    }
}

private actor FirstChunkLatch {
    private var received = false
    private var waiting: CheckedContinuation<Void, Never>?

    func receive() {
        received = true
        waiting?.resume()
        waiting = nil
    }

    func wait() async {
        if received { return }
        await withCheckedContinuation { waiting = $0 }
    }
}
