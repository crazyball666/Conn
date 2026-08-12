import Foundation

/// Converts push-based transport output into a bounded async stream.
///
/// The bridge serializes producer calls to preserve arrival order. If the consumer falls
/// behind beyond `maxBufferedChunks`, the first dropped chunk terminates the stream with a
/// structured error and invokes `onTermination`; transports use that callback to close the
/// affected child channel and stop reading.
package final class RemoteProcessOutputBridge: @unchecked Sendable {
    package let stream: AsyncThrowingStream<RemoteProcessOutput, Error>

    private let continuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let maxBufferedChunks: Int
    private let onTermination: @Sendable () -> Void
    private let lock = NSRecursiveLock()
    private var isTerminated = false

    package init(
        maxBufferedChunks: Int,
        onTermination: @escaping @Sendable () -> Void = {}
    ) {
        precondition(maxBufferedChunks > 0)
        self.maxBufferedChunks = maxBufferedChunks
        self.onTermination = onTermination
        (stream, continuation) = AsyncThrowingStream.makeStream(
            bufferingPolicy: .bufferingOldest(maxBufferedChunks)
        )
        continuation.onTermination = { [weak self] _ in
            self?.finishFromConsumer()
        }
    }

    /// Returns false once this chunk could not be delivered or the stream had terminated.
    @discardableResult
    package func yield(_ output: RemoteProcessOutput) -> Bool {
        lock.lock()
        guard !isTerminated else {
            lock.unlock()
            return false
        }

        let result = continuation.yield(output)
        let shouldReportOverflow: Bool
        let shouldNotifyTermination: Bool
        switch result {
        case .enqueued:
            shouldReportOverflow = false
            shouldNotifyTermination = false
        case .dropped:
            isTerminated = true
            shouldReportOverflow = true
            shouldNotifyTermination = true
        case .terminated:
            isTerminated = true
            shouldReportOverflow = false
            shouldNotifyTermination = true
        @unknown default:
            isTerminated = true
            shouldReportOverflow = false
            shouldNotifyTermination = true
        }
        lock.unlock()

        if shouldReportOverflow {
            continuation.finish(
                throwing: RemoteProcessError.outputBufferOverflow(
                    maxBufferedChunks: maxBufferedChunks
                )
            )
        }
        if shouldNotifyTermination {
            onTermination()
        }
        return !shouldNotifyTermination
    }

    package func finish() {
        guard claimTermination() else { return }
        continuation.finish()
        onTermination()
    }

    package func finish(throwing error: any Error) {
        guard claimTermination() else { return }
        continuation.finish(throwing: error)
        onTermination()
    }

    private func finishFromConsumer() {
        guard claimTermination() else { return }
        onTermination()
    }

    private func claimTermination() -> Bool {
        lock.withLock {
            guard !isTerminated else { return false }
            isTerminated = true
            return true
        }
    }
}
