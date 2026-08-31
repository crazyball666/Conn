import Citadel
import ConnSSH
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// The bridge between Conn's host-key policy/store and Citadel's callback-based validator.
///
/// Citadel invokes this delegate during SSH key exchange. The delegate therefore performs
/// only synchronous, in-memory work: derive the OpenSSH SHA-256 fingerprint, consult the
/// injected store, and complete the NIO promise. A TOFU mismatch is never auto-overwritten.
final class CitadelHostKeyVerifier: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: SSHEndpoint
    private let hostKeyStore: any HostKeyStore
    private let policy: HostKeyPolicy

    init(endpoint: SSHEndpoint, hostKeyStore: any HostKeyStore, policy: HostKeyPolicy) {
        self.endpoint = endpoint
        self.hostKeyStore = hostKeyStore
        self.policy = policy
    }

    /// Evaluates a key without touching NIO, which keeps policy decisions deterministic and testable.
    func evaluate(_ hostKey: NIOSSHPublicKey) -> Result<String, SSHError> {
        let fingerprint = Self.fingerprint(for: hostKey)
        switch policy {
        case .tofu:
            switch hostKeyStore.evaluate(fingerprint, for: endpoint) {
            case .trustedFirstUse, .matches:
                return .success(fingerprint)
            case let .mismatch(known):
                return .failure(.hostKeyMismatch(endpoint: endpoint, expected: known, actual: fingerprint))
            case .unavailable:
                return .failure(.hostKeyStoreUnavailable)
            }

        case let .strict(expectedFingerprint):
            guard expectedFingerprint == fingerprint else {
                return .failure(.hostKeyMismatch(endpoint: endpoint, expected: expectedFingerprint, actual: fingerprint))
            }
            return .success(fingerprint)

        case .acceptOnce:
            // This policy is an explicit, one-connection user confirmation. Do not mutate
            // the persistent TOFU store; callers can call `remember` after confirmation.
            return .success(fingerprint)
        }
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        switch evaluate(hostKey) {
        case .success:
            validationCompletePromise.succeed(())
        case let .failure(error):
            validationCompletePromise.fail(CitadelHostKeyValidationError(sshError: error))
        }
    }

    /// OpenSSH-compatible SHA256 fingerprint of the complete SSH public-key blob.
    static func fingerprint(for hostKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        hostKey.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        let base64 = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    static func validator(
        endpoint: SSHEndpoint,
        hostKeyStore: any HostKeyStore,
        policy: HostKeyPolicy
    ) -> SSHHostKeyValidator {
        SSHHostKeyValidator.custom(
            CitadelHostKeyVerifier(endpoint: endpoint, hostKeyStore: hostKeyStore, policy: policy)
        )
    }
}

/// NIO needs an `Error` to fail the handshake promise. Keep the domain error intact so
/// `AuthMapping` can expose a precise host-key mismatch instead of a generic refusal.
struct CitadelHostKeyValidationError: Error, Equatable {
    let sshError: SSHError
}
