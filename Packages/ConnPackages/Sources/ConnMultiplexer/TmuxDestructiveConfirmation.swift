import Foundation

public enum TmuxDestructiveConfirmationError: Error, Sendable, Equatable {
    case invalidPolicy
    case operationIsNotDestructive
    case scopeInstanceMismatch
    case snapshotRefreshRequired
    case clientTopologyRefreshRequired(TmuxClientID)
    case staleConfirmation
}

public struct TmuxDestructiveConfirmationPolicy: Sendable, Equatable {
    public static let maximumAllowedDuration: TimeInterval = 300
    public static let standard = TmuxDestructiveConfirmationPolicy(
        uncheckedMaximumSnapshotAge: 15,
        claimLifetime: 15
    )

    public let maximumSnapshotAge: TimeInterval
    public let claimLifetime: TimeInterval

    public init(maximumSnapshotAge: TimeInterval, claimLifetime: TimeInterval) throws {
        guard maximumSnapshotAge.isFinite,
              claimLifetime.isFinite,
              maximumSnapshotAge > 0,
              claimLifetime > 0,
              maximumSnapshotAge <= Self.maximumAllowedDuration,
              claimLifetime <= Self.maximumAllowedDuration
        else {
            throw TmuxDestructiveConfirmationError.invalidPolicy
        }
        self.maximumSnapshotAge = maximumSnapshotAge
        self.claimLifetime = claimLifetime
    }

    private init(uncheckedMaximumSnapshotAge: TimeInterval, claimLifetime: TimeInterval) {
        maximumSnapshotAge = uncheckedMaximumSnapshotAge
        self.claimLifetime = claimLifetime
    }
}

/// An exact structural digest rather than a process-random or collision-prone integer hash.
/// Its representation is intentionally opaque outside this module.
public struct TmuxOperationImpactDigest: Sendable, Equatable {
    fileprivate let operation: TmuxOperation
    fileprivate let context: TmuxOperationImpactContext
    fileprivate let impact: TmuxOperationImpact

    fileprivate init(
        operation: TmuxOperation,
        context: TmuxOperationImpactContext,
        impact: TmuxOperationImpact
    ) {
        self.operation = operation
        self.context = context
        self.impact = impact
    }
}

/// Short-lived authority created from the exact impact shown to the user. It is intentionally
/// not Codable or persisted. The future Hub must consume each nonce at most once when queueing.
public struct TmuxDestructiveConfirmationClaim: Sendable, Equatable {
    public let nonce: UUID
    public let scope: TmuxOperationScope
    public let impactRevision: UInt64
    public let impactDigest: TmuxOperationImpactDigest
    public let expiresAt: Date

    fileprivate init(
        nonce: UUID,
        scope: TmuxOperationScope,
        impactRevision: UInt64,
        impactDigest: TmuxOperationImpactDigest,
        expiresAt: Date
    ) {
        self.nonce = nonce
        self.scope = scope
        self.impactRevision = impactRevision
        self.impactDigest = impactDigest
        self.expiresAt = expiresAt
    }
}

/// Value presented by UI before the user confirms. Both presentation facts and executable
/// request come from the same analysis.
public struct TmuxPreparedDestructiveOperation: Sendable, Equatable {
    public let request: TmuxOperationRequest
    public let impact: TmuxOperationImpact
    public let claim: TmuxDestructiveConfirmationClaim

    fileprivate init(
        request: TmuxOperationRequest,
        impact: TmuxOperationImpact,
        claim: TmuxDestructiveConfirmationClaim
    ) {
        self.request = request
        self.impact = impact
        self.claim = claim
    }
}

/// Result handed to the operation queue after revalidation. Possession of a raw claim alone is
/// insufficient; the Hub must obtain this value from the current snapshot immediately before
/// queueing and atomically reject a previously consumed `confirmationNonce`.
public struct TmuxValidatedDestructiveOperation: Sendable, Equatable {
    public let request: TmuxOperationRequest
    public let impact: TmuxOperationImpact
    public let confirmationNonce: UUID

    fileprivate init(
        request: TmuxOperationRequest,
        impact: TmuxOperationImpact,
        confirmationNonce: UUID
    ) {
        self.request = request
        self.impact = impact
        self.confirmationNonce = confirmationNonce
    }
}

public struct TmuxDestructiveConfirmationGuard: Sendable {
    public let policy: TmuxDestructiveConfirmationPolicy

    private let analyzer: TmuxOperationImpactAnalyzer

    public init(policy: TmuxDestructiveConfirmationPolicy = .standard) {
        self.policy = policy
        analyzer = TmuxOperationImpactAnalyzer()
    }

    /// Creates the value shown by a confirmation surface. A stale snapshot never produces a
    /// claim: callers must reconcile first and then prepare again.
    public func prepare(
        _ request: TmuxOperationRequest,
        snapshot: TmuxServerSnapshot,
        context: TmuxOperationImpactContext = .init(),
        now: Date = Date()
    ) throws -> TmuxPreparedDestructiveOperation {
        guard request.operation.isDestructive else {
            throw TmuxDestructiveConfirmationError.operationIsNotDestructive
        }
        guard request.scope.instanceToken == snapshot.instance.token else {
            throw TmuxDestructiveConfirmationError.scopeInstanceMismatch
        }

        let impact = try analyzer.analyze(request.operation, in: snapshot, context: context)
        let freshnessDeadline = try requireFreshTopology(
            snapshot: snapshot,
            impact: impact,
            now: now
        )
        let policyDeadline = now.addingTimeInterval(policy.claimLifetime)
        let expiresAt = min(policyDeadline, freshnessDeadline)
        let digest = TmuxOperationImpactDigest(
            operation: request.operation,
            context: context,
            impact: impact
        )
        let claim = TmuxDestructiveConfirmationClaim(
            nonce: UUID(),
            scope: request.scope,
            impactRevision: snapshot.impactRevision,
            impactDigest: digest,
            expiresAt: expiresAt
        )
        return TmuxPreparedDestructiveOperation(
            request: request,
            impact: impact,
            claim: claim
        )
    }

    /// Recomputes impact from current state. Every mismatch intentionally collapses to
    /// `staleConfirmation`, so callers cannot execute a narrower/different operation using an
    /// old confirmation even when a displayed count happens to remain equal.
    public func validate(
        _ claim: TmuxDestructiveConfirmationClaim,
        for request: TmuxOperationRequest,
        snapshot: TmuxServerSnapshot,
        context: TmuxOperationImpactContext = .init(),
        now: Date = Date()
    ) throws -> TmuxValidatedDestructiveOperation {
        guard request.operation.isDestructive else {
            throw TmuxDestructiveConfirmationError.operationIsNotDestructive
        }
        guard now < claim.expiresAt,
              claim.scope == request.scope,
              request.scope.instanceToken == snapshot.instance.token,
              claim.impactRevision == snapshot.impactRevision
        else {
            throw TmuxDestructiveConfirmationError.staleConfirmation
        }

        let impact: TmuxOperationImpact
        do {
            impact = try analyzer.analyze(request.operation, in: snapshot, context: context)
            _ = try requireFreshTopology(snapshot: snapshot, impact: impact, now: now)
        } catch {
            throw TmuxDestructiveConfirmationError.staleConfirmation
        }

        let digest = TmuxOperationImpactDigest(
            operation: request.operation,
            context: context,
            impact: impact
        )
        guard digest == claim.impactDigest else {
            throw TmuxDestructiveConfirmationError.staleConfirmation
        }
        return TmuxValidatedDestructiveOperation(
            request: request,
            impact: impact,
            confirmationNonce: claim.nonce
        )
    }

    private func requireFreshTopology(
        snapshot: TmuxServerSnapshot,
        impact: TmuxOperationImpact,
        now: Date
    ) throws -> Date {
        var deadline = snapshot.observedAt.addingTimeInterval(policy.maximumSnapshotAge)
        guard now < deadline else {
            throw TmuxDestructiveConfirmationError.snapshotRefreshRequired
        }

        // The initiating attachment is actively owned by the caller and excluded from "other"
        // risk. Every other affected client must have an independently fresh observation.
        for clientID in impact.otherAffectedClientIDs {
            guard let client = snapshot.clients[clientID] else {
                throw TmuxDestructiveConfirmationError.clientTopologyRefreshRequired(clientID)
            }
            let clientDeadline = client.observedAt.addingTimeInterval(policy.maximumSnapshotAge)
            guard now < clientDeadline else {
                throw TmuxDestructiveConfirmationError.clientTopologyRefreshRequired(clientID)
            }
            deadline = min(deadline, clientDeadline)
        }
        return deadline
    }
}
