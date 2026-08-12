# tmux Control Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a transport-independent Control Mode command state machine, an actor owning one injected bidirectional process channel, and a generation/lease-aware Hub core that serializes operations and reconciles normalized state.

**Architecture:** A pure `TmuxControlCommandMachine` owns protocol readiness, exactly one in-flight command, bounded output, guard correlation, timeout quarantine, and reconciliation barriers. `TmuxControlClient` owns parser + injected `RemoteProcessChannel`, feeds events into the machine in wire order, and never replays an uncertain mutation. `TmuxControlHub` owns generation, reducer, leases, destructive nonce consumption, and operation serialization; opening the SSH PTY+exec channel remains a separate adapter seam.

**Tech Stack:** Swift 5.10 actors, Foundation `Data`, ConnSSH `RemoteProcessChannel`, Swift Testing, SwiftPM.

**Execution constraint:** Work on the existing `main` branch as explicitly requested by the user. Do not create a worktree or dispatch subagents. Do not add a fake interactive-shell fallback for tmux Control Mode.

---

### Task 1: Correlate one bounded Control Mode command at a time

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlCommandMachine.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlCommandMachineTests.swift`

- [x] Write failing tests for protocol readiness, one in-flight command, begin/output/end/error correlation, notifications before/between commands, and bounded output.
- [x] Write failing tests proving invalid ordering and guard mismatch fail closed.
- [x] Implement a pure state machine with local command IDs and typed command outcomes.
- [x] Run focused tests and all `ConnMultiplexerTests`.
- [x] Commit: `feat: correlate tmux control commands`.

### Task 2: Quarantine timeouts and require reconciliation

**Files:**

- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlCommandMachine.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlCommandMachineTests.swift`

- [ ] Write failing tests for timeout before/after `%begin`, late `%end/%error`, channel loss, old generation events, and reconciliation barriers.
- [ ] Implement dirty/recovering states: no subsequent mutation is accepted until the late terminator plus reconciliation, or a strictly newer generation is installed.
- [ ] Keep timed-out mutation outcome permanently unknown; a late success is diagnostic only.
- [ ] Run focused/module tests and commit: `feat: quarantine uncertain tmux commands`.

### Task 3: Own an injected process channel in `TmuxControlClient`

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlClient.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlClientTests.swift`

- [ ] Write scripted-channel tests for arbitrary chunks, stdout-only protocol input, stderr diagnostics, serialized writes, deadline behavior, close/result races, and exactly-once completion.
- [ ] Implement an actor that owns parser/channel/read loop and forwards notifications in wire order.
- [ ] Never retry or switch channel after a command may have been written; mark outcome unknown and request reconciliation.
- [ ] Run focused/module tests and commit: `feat: run tmux control client`.

### Task 4: Coordinate generation, reducer, leases, and nonce consumption

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlHub.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlHubTests.swift`

- [ ] Write tests for observation/identity lease lifetimes, old-generation discard, snapshot stream ordering, operation serialization, and profile/connection invalidation.
- [ ] Write destructive tests proving validation and nonce consumption are atomic and duplicate submissions cannot queue twice.
- [ ] Implement the Hub without opening SSH itself; inject channel/snapshot factories at the adapter seam.
- [ ] Run module/full-package regression and commit: `feat: coordinate tmux control hub`.

## Completion gate

- [ ] No more than one response-bearing command is in flight per Control Client.
- [ ] Output is bounded independently of parser line bounds.
- [ ] Timed-out/transport-lost mutations are never auto-replayed or later reported as success.
- [ ] Dirty generations reject new mutations until reconciliation or replacement.
- [ ] Old-generation events/results cannot mutate current state.
- [ ] Notification order matches wire order.
- [ ] Destructive nonce is consumed at most once atomically with queueing.
- [ ] Control orchestration depends only on ConnSSH abstractions, never Citadel/UI.
- [ ] Full package tests and `git diff --check` pass.
