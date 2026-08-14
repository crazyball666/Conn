import Citadel
import ConnSSH
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// Citadel-backed implementation of ConnSSH's long-lived exec contract.
///
/// Citadel owns the NIO child channel inside `SSHClient.withProcess`. This adapter
/// keeps that closure alive for the lifetime of the remote process, exposes the
/// output through the shared bounded bridge, and only closes the child channel on
/// detach. It never enters an interactive/login shell.
final class CitadelRemoteProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    private enum PumpOutcome {
        case exited(Int32)
        case stopped
        case failed(any Error)
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: PumpOutcome?

        func set(_ outcome: PumpOutcome) {
            lock.withLock { self.outcome = outcome }
        }

        func get() -> PumpOutcome? {
            lock.withLock { outcome }
        }
    }

    let output: AsyncThrowingStream<RemoteProcessOutput, Error>

    private let bridge: RemoteProcessOutputBridge
    private let writerBox = NIOLockedValueBox<TTYStdinWriter?>(nil)
    private let lifecycle = ShellChannelLifecycleGate()
    private let hasPTY: Bool
    private var processTask: Task<RemoteProcessExit, Error>!

    private init(hasPTY: Bool, maxBufferedChunks: Int) {
        self.hasPTY = hasPTY
        let bridge = RemoteProcessOutputBridge(maxBufferedChunks: maxBufferedChunks) { [weak lifecycle] in
            lifecycle?.terminate()
        }
        self.bridge = bridge
        self.output = bridge.stream
    }

    /// Opens a direct SSH exec channel and waits until its input writer is usable.
    static func open(
        client: SSHClient,
        request: RemoteProcessRequest,
        maxBufferedChunks: Int = 512
    ) async throws -> CitadelRemoteProcessChannel {
        let channel = CitadelRemoteProcessChannel(
            hasPTY: request.terminal != nil,
            maxBufferedChunks: maxBufferedChunks
        )
        channel.processTask = Task { [channel] in
            try await channel.run(client: client, request: request)
        }
        do {
            try await channel.lifecycle.waitForReady()
            return channel
        } catch {
            _ = try? await channel.processTask.value
            throw error
        }
    }

    private func run(
        client: SSHClient,
        request: RemoteProcessRequest
    ) async throws -> RemoteProcessExit {
        let terminal = request.terminal.map(makePTYRequest)
        let outcomeBox = OutcomeBox()

        do {
            try await client.withProcess(request.command, terminal: terminal) { inbound, outbound in
                writerBox.withLockedValue { $0 = outbound }
                lifecycle.markReady()

                let pumpTask = Task { [weak self] in
                    await self?.pump(inbound) ?? .stopped
                }

                let first: PumpOutcome = await withTaskGroup(of: PumpOutcome.self) { group in
                    group.addTask { await pumpTask.value }
                    group.addTask {
                        await self.lifecycle.waitForStop()
                        return .stopped
                    }
                    let outcome = await group.next() ?? .stopped
                    group.cancelAll()
                    return outcome
                }

                outcomeBox.set(first)
                if case .stopped = first {
                    pumpTask.cancel()
                } else {
                    lifecycle.terminate()
                }
                writerBox.withLockedValue { $0 = nil }
            }
        } catch {
            writerBox.withLockedValue { $0 = nil }
            bridge.finish(throwing: error)
            lifecycle.markOpenFailed(error)
            throw error
        }

        writerBox.withLockedValue { $0 = nil }
        let outcome = outcomeBox.get() ?? .stopped
        switch outcome {
        case let .exited(code):
            bridge.finish()
            return RemoteProcessExit(exitCode: code, signal: nil)
        case .stopped:
            bridge.finish()
            return RemoteProcessExit(exitCode: nil, signal: nil)
        case let .failed(error):
            bridge.finish(throwing: error)
            throw error
        }
    }

    private func pump(_ inbound: TTYOutput) async -> PumpOutcome {
        do {
            for try await chunk in inbound {
                let output: RemoteProcessOutput
                switch chunk {
                case let .stdout(buffer):
                    output = .stdout(Data(buffer.readableBytesView))
                case let .stderr(buffer):
                    output = .stderr(Data(buffer.readableBytesView))
                }
                guard bridge.yield(output) else { return .stopped }
            }
            return .exited(0)
        } catch is CancellationError {
            return .stopped
        } catch let failure as SSHClient.CommandFailed {
            return .exited(Int32(failure.exitCode))
        } catch {
            return .failed(error)
        }
    }

    private func makePTYRequest(_ request: RemoteTerminalRequest) -> SSHChannelRequestEvent.PseudoTerminalRequest {
        let modes = request.modes.reduce(into: [SSHTerminalModes.Opcode: SSHTerminalModes.OpcodeValue]()) {
            $0[SSHTerminalModes.Opcode(rawValue: $1.key.rawValue)] =
                SSHTerminalModes.OpcodeValue(rawValue: $1.value)
        }
        return SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: request.type,
            terminalCharacterWidth: request.size.cols,
            terminalRowHeight: request.size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes(modes)
        )
    }

    func write(_ data: Data) async throws {
        guard lifecycle.isWritable,
              let writer = writerBox.withLockedValue({ $0 }) else {
            throw SSHError.channelClosed
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await writer.write(buffer)
    }

    func resize(_ size: TermSize) async throws {
        guard hasPTY else { throw RemoteProcessError.terminalNotAllocated }
        guard lifecycle.isWritable,
              let writer = writerBox.withLockedValue({ $0 }) else {
            throw SSHError.channelClosed
        }
        try await writer.changeSize(cols: size.cols, rows: size.rows, pixelWidth: 0, pixelHeight: 0)
    }

    func result() async throws -> RemoteProcessExit {
        try await processTask.value
    }

    func close() async {
        lifecycle.terminate()
        _ = try? await processTask.value
    }
}
