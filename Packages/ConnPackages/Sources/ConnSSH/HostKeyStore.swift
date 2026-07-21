import Foundation

/// 对一个呈现指纹的裁决结果。
public enum HostKeyVerdict: Sendable, Equatable {
    /// 首次见到此主机，已入库信任。
    case trustedFirstUse
    /// 与已记录指纹一致。
    case matches
    /// 与已记录指纹不符，带出旧指纹。**必须全屏阻断**（技术方案 §4.1）。
    case mismatch(known: String)
}

/// TOFU（Trust On First Use）主机指纹库。
///
/// 由 GRDB 实现（`known_host` 表，见 `ConnStore.GRDBHostKeyStore`），
/// 内存实现供测试。ConnSSH 通过此协议注入，不直接依赖 GRDB。
public protocol HostKeyStore: Sendable {
    func knownFingerprint(for endpoint: SSHEndpoint) -> String?
    /// 手动记住指纹（首次信任，或用户在告警里确认覆盖变更）。
    func remember(_ fingerprint: String, for endpoint: SSHEndpoint)
    /// 裁决呈现的指纹。首次会自动 `remember`；变更**不**自动覆盖。
    func evaluate(_ presented: String, for endpoint: SSHEndpoint) -> HostKeyVerdict
}

public extension HostKeyStore {
    /// 默认裁决逻辑，供各实现复用：首次入库、相同放行、变更阻断。
    func defaultEvaluate(_ presented: String, for endpoint: SSHEndpoint) -> HostKeyVerdict {
        guard let known = knownFingerprint(for: endpoint) else {
            remember(presented, for: endpoint)
            return .trustedFirstUse
        }
        return known == presented ? .matches : .mismatch(known: known)
    }
}

/// 内存指纹库（测试与演示模式用）。
///
/// 线程安全：内部用锁保护，满足 `Sendable`。
public final class InMemoryHostKeyStore: HostKeyStore, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func knownFingerprint(for endpoint: SSHEndpoint) -> String? {
        lock.withLock { store[endpoint.identifier] }
    }

    public func remember(_ fingerprint: String, for endpoint: SSHEndpoint) {
        lock.withLock { store[endpoint.identifier] = fingerprint }
    }

    public func evaluate(_ presented: String, for endpoint: SSHEndpoint) -> HostKeyVerdict {
        defaultEvaluate(presented, for: endpoint)
    }
}
