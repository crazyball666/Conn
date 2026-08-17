import Foundation
import NIOConcurrencyHelpers

/// `withPTY` 的就绪与关闭状态机。
///
/// Citadel 的 PTY 生命周期由闭包约束：writer 出现前 open 必须等待，reader 结束后
/// 闭包又必须被主动放行。这个小型锁保护状态机保证两个 continuation 各自最多恢复一次。
final class ShellChannelLifecycleGate: @unchecked Sendable {
    private enum Readiness {
        case pending
        case ready
        case failed(Error)
    }

    private struct State {
        var readiness: Readiness = .pending
        var readinessContinuation: CheckedContinuation<Void, Error>?
        var stopContinuation: (
            id: UUID,
            continuation: CheckedContinuation<Void, Never>
        )?
        var stopRequested = false
        var terminated = false
    }

    private let state = NIOLockedValueBox(State())

    var isWritable: Bool {
        state.withLockedValue { state in
            if case .ready = state.readiness {
                !state.terminated
            } else {
                false
            }
        }
    }

    func waitForReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result = state.withLockedValue { state -> Result<Void, Error>? in
                switch state.readiness {
                case .pending:
                    state.readinessContinuation = continuation
                    return nil
                case .ready:
                    return .success(())
                case let .failed(error):
                    return .failure(error)
                }
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func markReady() {
        let continuation = state.withLockedValue { state -> CheckedContinuation<Void, Error>? in
            guard case .pending = state.readiness else { return nil }
            state.readiness = .ready
            defer { state.readinessContinuation = nil }
            return state.readinessContinuation
        }
        continuation?.resume()
    }

    /// 只在 writer 尚未就绪时结束 `open()`；就绪后错误走 output/lifecycle 终止路径。
    func markOpenFailed(_ error: Error) {
        let continuations = state.withLockedValue { state -> (CheckedContinuation<Void, Error>?, CheckedContinuation<Void, Never>?)? in
            guard case .pending = state.readiness else { return nil }
            state.readiness = .failed(error)
            state.terminated = true
            state.stopRequested = true
            let readiness = state.readinessContinuation
            let stop = state.stopContinuation?.continuation
            state.readinessContinuation = nil
            state.stopContinuation = nil
            return (readiness, stop)
        }
        continuations?.0?.resume(throwing: error)
        continuations?.1?.resume()
    }

    func waitForStop() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResume = state.withLockedValue { state -> Bool in
                    if state.stopRequested || Task.isCancelled {
                        return true
                    } else {
                        state.stopContinuation = (waiterID, continuation)
                        return false
                    }
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            let continuation = state.withLockedValue {
                state -> CheckedContinuation<Void, Never>? in
                guard state.stopContinuation?.id == waiterID else { return nil }
                defer { state.stopContinuation = nil }
                return state.stopContinuation?.continuation
            }
            continuation?.resume()
        }
    }

    /// 终止是幂等的，返回后 PTY 闭包可安全退出。
    func terminate() {
        let continuation = state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            guard !state.terminated else { return nil }
            state.terminated = true
            state.stopRequested = true
            defer { state.stopContinuation = nil }
            return state.stopContinuation?.continuation
        }
        continuation?.resume()
    }
}
