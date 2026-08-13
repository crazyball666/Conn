# tmux Runtime Adapter and Snapshot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the completed tmux protocol/Hub core into a transport-neutral runtime that can execute typed read-only queries, build validated snapshots, safely run token-guarded one-shot mutations, and route Hub operations without introducing UI or a concrete terminal attachment yet.

**Architecture:** A typed `TmuxControlRequest` generalizes the existing operation-only Control Client without admitting raw UI strings. A framed snapshot plan renders official `list-* -F`/`display-message` queries and a strict assembler constructs the normalized graph; a loader runs that plan through an injected read-only command executor and enforces generation/token boundaries. A Hub adapter then chooses an already-ready Control Client or a token-guarded one-shot executor, and delegates observation demand to a lifecycle driver that will be implemented by the later provider/attachment phase.

**Tech Stack:** Swift 5.10 actors, Foundation `Data`, ConnSSH `SSHSession`/prepared POSIX runtime, Swift Testing, SwiftPM.

---

## Scope and execution constraints

- Work directly on the existing `main` branch as explicitly requested by the user.
- Do not create a worktree or dispatch subagents.
- This plan does not implement `TmuxProvider`, Control/data process handshake, pass-through PTY, `ConnTerminal` integration, or UI.
- No adapter may retry a mutation after a Control or one-shot invocation may have been dispatched.
- Linux/macOS shell execution remains behind ConnSSH prepared POSIX runtimes. Windows/Unknown routing is a later provider concern and must not be guessed here.
- The official tmux Control Mode contract and formats are documented in the [tmux Control Mode wiki](https://github.com/tmux/tmux/wiki/Control-Mode), [Formats wiki](https://github.com/tmux/tmux/wiki/Formats), and [tmux manual](https://man.openbsd.org/tmux).

## File map

- `TmuxControlRequest.swift` — typed operation/query envelope and semantics.
- `TmuxControlCommandMachine.swift` — correlate a rendered typed request rather than constructing operations internally.
- `TmuxControlClient.swift` — execute typed read-only requests while retaining the operation convenience API.
- `TmuxSnapshotQuery.swift` — framed query sections, official tmux format strings, quoted/legacy plans.
- `TmuxSnapshotAssembler.swift` — strict string-to-ID/number/graph conversion and client ownership classification.
- `TmuxSnapshotLoader.swift` — execute query plans, enforce initial/final server identity, and return one coherent snapshot.
- `TmuxOneShotOperationExecutor.swift` — run one mutation through the existing same-invocation token guard.
- `TmuxControlHubRuntimeAdapter.swift` — route Hub operations/snapshots/demand through injected runtime seams.

### Task 1: Generalize one Control Mode request without exposing raw commands

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlRequest.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlCommandMachine.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlClient.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlCommandMachineTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlClientTests.swift`

- [ ] Write failing `@testable` tests proving the package-visible envelope carries pre-rendered bounded wire data and `.readOnly` semantics. Keep its production initializer module-internal so package sibling targets and UI code cannot construct an arbitrary tmux command.
- [ ] Write a failing Client test proving a read-only request uses the same one-in-flight correlation and bounded output as a mutation.
- [ ] Introduce `TmuxControlRequest` with a module-internal initializer available to trusted ConnMultiplexer renderers but not to package sibling targets such as ConnTerminal; expose only read access to `wireData` and explicit `TmuxOperationSemantics`.
- [ ] Change `TmuxControlCommandMachine.submit` to consume `TmuxControlRequest`; keep `submit(_ operation:)` and `TmuxControlClient.execute(_ operation:)` as convenience adapters through `TmuxControlCommandRenderer`.
- [ ] Run `TmuxControlCommandMachineTests`, `TmuxControlClientTests`, and all `ConnMultiplexerTests`.
- [ ] Commit: `feat: generalize tmux control requests`.

### Task 2: Render bounded framed snapshot query plans

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshotQuery.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxSnapshotQueryTests.swift`

- [ ] Write failing quoted-plan tests for server identity, Sessions, all Session→Window links, unique Windows, Panes, and Clients using official `display-message`/`list-* -F` commands.
- [ ] Prove every section is bracketed by a validated invocation nonce plus a fixed section enum, so remote names can never be mistaken for section boundaries.
- [ ] Prove the quoted plan uses `#{q:...}` for every untrusted text field and only typed IDs/numbers are parsed without quoting.
- [ ] Write legacy-plan tests proving bulk queries contain only IDs/numbers and every untrusted name/path/title/command is requested as an independent field; require server identity at both plan boundaries.
- [ ] Implement immutable `TmuxSnapshotQueryPlan`, `TmuxSnapshotQueryStep`, `TmuxSnapshotSection`, and `TmuxSnapshotQueryRenderer`. All generated Control requests are `.readOnly`; no request contains executable/locator/POSIX quoting.
- [ ] Bound section count, step count, expected fields, and marker length at construction.
- [ ] Run focused tests and `git diff --check`.
- [ ] Commit: `feat: render tmux snapshot queries`.

### Task 3: Assemble a validated normalized snapshot

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshotAssembler.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxSnapshotAssemblerTests.swift`

- [ ] Write failing full-graph fixtures covering grouped Sessions, a Window linked into multiple Sessions, Pane metadata/freshness, current Window/active Pane, external clients, one verified Conn interactive client, and one Conn Control Client.
- [ ] Write failing rejection tests for duplicate/conflicting entities, invalid `$`/`@`/`%` IDs, negative/overflow numeric fields, invalid booleans, missing links, mismatched active Pane ownership, malformed client flags, and a server token that does not match the requested scope.
- [ ] Define typed decoded records per section rather than passing `[[String]]` through the runtime.
- [ ] Implement `TmuxSnapshotAssembler` that accepts decoded section records plus `Set<TmuxControlInteractiveIdentity>` and an optional verified Control Client ID, classifies all unclaimed clients as external, and constructs `TmuxServerSnapshot` only after complete validation.
- [ ] Deduplicate shared Window rows only when all Window fields match; preserve every distinct `TmuxWindowLink`.
- [ ] Mark quoted snapshot metadata as `.snapshot(observedAt:)`; legacy unavailable fields remain `.unavailable` rather than guessed.
- [ ] Run focused tests and all snapshot/reducer tests.
- [ ] Commit: `feat: assemble tmux runtime snapshots`.

### Task 4: Execute coherent snapshot plans behind a read-only seam

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshotLoader.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxSnapshotLoaderTests.swift`

- [ ] Define `TmuxReadOnlyCommandExecuting` with exact scope/generation and bounded `[Data]` output; adapters for a ready `TmuxControlClient` and later one-shot transport live outside the loader.
- [ ] Write failing tests for quoted single-generation loading, legacy multi-step loading, arbitrary command-output line boundaries, and identity ownership passed to the assembler.
- [ ] Write race tests proving old-generation results are discarded, quoted identity mismatch fails the whole load, and legacy initial/final token mismatch discards every intermediate record.
- [ ] Implement `TmuxSnapshotLoader` as an actor so only one plan runs per scope/generation. It must never retry a failed step automatically and must not publish partial snapshots.
- [ ] Decode each section with the existing quoted/legacy codecs, then invoke `TmuxSnapshotAssembler` once.
- [ ] Run focused tests and all `ConnMultiplexerTests`.
- [ ] Commit: `feat: load coherent tmux snapshots`.

### Task 5: Run token-guarded one-shot operations without replay

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxOneShotOperationExecutor.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxOneShotOperationExecutorTests.swift`

- [ ] Inject `SSHSession`, `PreparedRemoteScriptRuntime`, `TmuxExecutablePath`, and `TmuxServerLocator`; assert their connection/profile/token scope is exact before rendering.
- [ ] Write failing success/rejection tests around `TmuxShellInvocationRenderer` guard-accepted and instance-changed markers, including ordinary command output and nonzero exits.
- [ ] Write timeout/transport tests proving once `SSHSession.exec` is entered every mutation failure is reported as outcome unknown and is never retried.
- [ ] Prove an instance-changed marker returns a structured stale-instance error and never reports command success.
- [ ] Implement a bounded marker/result parser that redacts the nonce and does not expose arbitrary stderr as a Swift type name.
- [ ] Return a transport-level `TmuxOneShotOperationResult` only after exact request/scope validation. The executor must not depend on `TmuxControlHubOperationReceipt`; post-operation snapshot loading and Hub receipt construction remain the runtime adapter's responsibility.
- [ ] Run focused tests and `ConnSSH` mock contract tests.
- [ ] Commit: `feat: execute guarded tmux one-shot operations`.

### Task 6: Route Hub runtime work through injected lifecycle seams

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlHubRuntimeAdapter.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlHubRuntimeAdapterTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlHub.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlHubTests.swift`

- [ ] Define small protocols for exact-generation ready Control Client lookup, one-shot execution, snapshot loading, and observation-demand lifecycle. Do not inject `SSHSession` directly into the Hub.
- [ ] Write routing tests: ready exact-generation Control Client wins; absent/not-ready client uses one-shot; catalog-only work uses snapshot loader; stale generation never routes.
- [ ] Write safety tests proving any Control execution error after submission—including timeout, channel loss, protocol failure, or rejected command—never falls through to one-shot replay.
- [ ] Extend `TmuxControlHubOperationReceipt` with an optional exact-generation reconciliation snapshot. Require one-shot success to load that coherent post-operation snapshot; the Hub validates and installs it before reporting the operation complete. Do not create an adapter→Hub callback or ownership cycle.
- [ ] Forward `TmuxControlHubDemand` in sequence to the lifecycle driver; identity-only demand must not open Control Mode, while observation/pending-operation demand may.
- [ ] Implement `TmuxControlHubRuntimeAdapter: TmuxControlHubAdapter` with no Citadel/UI imports and no platform switch.
- [ ] Run focused tests, all `ConnMultiplexerTests`, and `git diff --check`.
- [ ] Commit: `feat: route tmux hub runtime operations`.

## Completion gate

- [ ] Snapshot text fields are decoded only through quoted or independent legacy field codecs.
- [ ] Quoted snapshots are one coherent plan; legacy plans verify the same server token before and after all steps.
- [ ] Snapshot assembly never publishes a partial or structurally invalid graph.
- [ ] Every runtime request remains bound to connection identity, profile ID, instance token, and generation.
- [ ] No mutation can fall back or retry after Control/one-shot dispatch may have occurred.
- [ ] One-shot operations use one tmux invocation for token guard plus mutation.
- [ ] Hub and runtime adapter remain independent of Citadel, SwiftUI, UIKit, SwiftTerm, and platform-specific process APIs.
- [ ] Full package tests and `git diff --check` pass.
