# tmux Operation Safety Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every typed tmux operation stable execution semantics, calculate its complete graph/client impact, and require a fresh scope-bound confirmation claim before any destructive operation can be queued.

**Architecture:** `ConnMultiplexer` remains transport-independent. A value-type operation scope binds SSH connection identity, backend profile, tmux instance token, and Hub generation. A pure analyzer resolves typed targets against the normalized snapshot and derives affected/destroyed entities, removed links, client risk, created entity kinds, and shared-state effects. A confirmation guard prepares a short-lived structural digest from a fresh snapshot and re-analyzes the operation at consumption time; metadata-only changes do not invalidate it, while any scope, impact revision, target, client, topology, or operation change does.

**Tech Stack:** Swift 5.10, Foundation, ConnSSH identity values, Swift Testing, SwiftPM.

**Execution constraint:** Work on the existing `main` branch as explicitly requested by the user. Do not create a worktree or dispatch subagents.

---

### Task 1: Model operation semantics and execution scope

**Files:**

- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxOperation.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxOperationSemanticsTests.swift`

- [x] **Step 1: Write failing tests** classifying every closed `TmuxOperation` as idempotent mutation, non-idempotent mutation, or destructive, with no unclassified case.
- [x] **Step 2: Write failing scope tests** proving a request binds connection identity, profile ID, server instance token, and Hub generation, and rejects an empty/controlled profile ID.
- [x] **Step 3: Run RED:** `swift test --package-path Packages/ConnPackages --filter TmuxOperationSemanticsTests` must fail because the new contracts do not exist.
- [x] **Step 4: Implement** `TmuxOperationSemantics`, exhaustive metadata on `TmuxOperation`, `TmuxOperationScope`, and `TmuxOperationRequest`.
- [x] **Step 5: Run GREEN** plus existing renderer suites; renderers must continue to consume only the typed operation.
- [x] **Step 6: Commit:** `feat: classify scoped tmux operations`.

### Task 2: Analyze normalized graph and client impact

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxOperationImpact.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxOperationImpactTests.swift`

- [ ] **Step 1: Write failing target tests** for missing Session/Window/Pane/client, ambiguous client target names, and Window/Pane targets not reachable from the selected client Session.
- [ ] **Step 2: Write failing shared-state tests** for grouped `createWindow`, linked Window rename/split/zoom/select, client-local Pane focus when active-pane isolation is enabled, and conservative shared focus otherwise.
- [ ] **Step 3: Write failing destructive tests** proving Kill Session only destroys orphaned Windows/Panes, Kill Window destroys the Window across every link and any now-windowless Session, and closing a final Pane cascades through Window/Session destruction.
- [ ] **Step 4: Write failing client-risk tests** proving the initiating attachment and Conn Control Clients are excluded, unknown/third-party Control Mode clients remain affected, and interactive risk is a strict projection of affected clients.
- [ ] **Step 5: Run RED:** `swift test --package-path Packages/ConnPackages --filter TmuxOperationImpactTests` must fail because the analyzer does not exist.
- [ ] **Step 6: Implement** `TmuxOperationImpactAnalyzer` and immutable impact values containing target presentation, created kinds, affected/destroyed IDs, removed links, other affected/interactive client IDs, and shared-state effects.
- [ ] **Step 7: Keep analysis pure and deterministic:** never consult UI, SSH, names as command targets, or renderer strings; sort public projections by typed identity.
- [ ] **Step 8: Run GREEN** and all `ConnMultiplexerTests`.
- [ ] **Step 9: Commit:** `feat: analyze tmux operation impact`.

### Task 3: Prepare and revalidate destructive confirmation claims

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxDestructiveConfirmation.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxDestructiveConfirmationTests.swift`

- [ ] **Step 1: Write failing preparation tests** requiring destructive semantics, a scope token matching the snapshot, fresh snapshot/client observations, and positive bounded policy durations.
- [ ] **Step 2: Write failing validation tests** for expiration, changed connection/profile/token/generation, changed `impactRevision`, changed operation/target/context, and same-count-but-different-client topology.
- [ ] **Step 3: Write stability tests** proving ordinary Pane title/path/command observation updates and snapshot `revision/observedAt` refreshes do not invalidate an otherwise current claim.
- [ ] **Step 4: Run RED:** `swift test --package-path Packages/ConnPackages --filter TmuxDestructiveConfirmationTests` must fail because the confirmation guard does not exist.
- [ ] **Step 5: Implement** a short-lived `TmuxDestructiveConfirmationClaim` with an opaque structural impact digest and nonce, plus `TmuxDestructiveConfirmationGuard.prepare/validate`.
- [ ] **Step 6: Make expiry bounded** by both policy lifetime and the remaining snapshot/client freshness window; future Hub code must consume each nonce at most once when queueing.
- [ ] **Step 7: Run GREEN**, all `ConnMultiplexerTests`, and `git diff --check`.
- [ ] **Step 8: Commit:** `feat: guard destructive tmux operations`.

## Completion gate

- [ ] Every production behavior has a focused RED before implementation.
- [ ] Every `TmuxOperation` has explicit retry/destructive semantics.
- [ ] All requests bind connection identity, profile, instance token, and generation.
- [ ] Linked/grouped topology is represented in impact results without duplicating Window entities.
- [ ] Kill Session distinguishes removed links from truly destroyed Windows/Panes.
- [ ] Final-Pane and final-Window cascades include destroyed Sessions and affected clients.
- [ ] Conn Control Clients and the initiating attachment are excluded from “other client” risk.
- [ ] Confirmation cannot cross scope, operation, target, context, impact revision, or freshness boundaries.
- [ ] Metadata-only updates do not invalidate destructive confirmation.
- [ ] `swift test --package-path Packages/ConnPackages --filter ConnMultiplexerTests` passes.
- [ ] `swift test --package-path Packages/ConnPackages` passes from current artifacts.
- [ ] `git diff --check` passes.
