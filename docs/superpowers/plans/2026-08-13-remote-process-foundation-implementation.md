# Remote Process Channel Foundation Implementation Plan

> Execute on the existing `main` branch as explicitly requested by the user. Keep each behavior change test-first and commit atomically.

**Goal:** Add a provider-independent, bidirectional remote-process API with bounded ordered output and a production-quality Mock implementation, while keeping the Citadel PTY+Exec gap explicit instead of routing machine protocols through an interactive shell.

**Architecture:** `ConnSSH` owns request/output/exit values and the channel protocol. A bounded stream bridge converts push-based transport output into the public async stream; overflow terminates the process channel with a structured error rather than silently dropping bytes. Existing SSH engines receive a structured unsupported default for source compatibility, while `MockSSHTransport` supplies a full implementation. `ConnSSHCitadel` only overrides the method after a source-controlled upstream/fork API can create PTY+Exec child channels and expose exit status/signal.

**Tech Stack:** Swift 5.10, Swift Concurrency, AsyncThrowingStream, Swift Testing, SwiftPM, NIOSSH/Citadel inspection.

## Scope and reviewed constraints

In scope:

- provider-neutral process request, optional PTY request, terminal modes, ordered stdout/stderr events and exit result;
- `SSHSession.openProcess` capability with a structured unsupported default;
- bounded output bridge with overflow termination and exactly-once completion;
- scripted Mock process channel with writable stdin, resize, result and idempotent close;
- unit and full-package regression tests.

Out of scope for this subphase:

- pretending `withPTY` + interactive shell is equivalent to PTY+Exec;
- vendoring/forking Citadel without an explicit dependency-maintenance decision;
- tmux command rendering, Control Mode parsing, provider and terminal UI wiring.

Reviewed dependency fact:

- Citadel 0.12.1 exposes bidirectional no-PTY `withExec`, and PTY-backed `withPTY` that starts a shell;
- its PTY setup does not expose a public PTY+Exec child-channel API;
- its current stream bridge is unbounded;
- therefore the exact engine adapter needs a small source-controlled upstream/fork API, not a wrapper-only change in Conn.

## Public contracts

Add to `ConnSSH`:

```swift
public struct RemoteTerminalMode: RawRepresentable, Hashable, Sendable
public struct RemoteTerminalRequest: Sendable, Equatable
public struct RemoteProcessRequest: Sendable, Equatable
public enum RemoteProcessOutput: Sendable, Equatable
public struct RemoteProcessExit: Sendable, Equatable
public enum RemoteProcessError: Error, Sendable, Equatable
public protocol RemoteProcessChannel: AnyObject, Sendable
```

`RemoteTerminalMode` uses SSH opcode raw values so future modes do not require changing the transport-neutral type. Static constants cover modes needed by terminal/control providers. Opcode zero is rejected at the engine boundary because it is the SSH end marker.

`SSHSession` gains:

```swift
func openProcess(_ request: RemoteProcessRequest) async throws -> any RemoteProcessChannel
```

The protocol extension returns `.unsupported` by default so existing third-party/test transports remain source compatible. Production feature probing must treat that as unavailable; it is never an implicit fallback to `openShell`.

## Task 1: Add process value contracts and SSHSession capability

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnSSH/RemoteProcessChannel.swift`
- Modify: `Packages/ConnPackages/Sources/ConnSSH/SSHTransport.swift`
- Create: `Packages/ConnPackages/Tests/ConnSSHTests/RemoteProcessChannelTests.swift`

- [ ] Write failing value/capability tests for optional PTY, terminal modes, stdout/stderr identity, exit status/signal and unsupported default.
- [ ] Run `swift test --package-path Packages/ConnPackages --filter RemoteProcessChannelTests` and witness compile failure.
- [ ] Implement only the public values/protocol/default.
- [ ] Run focused tests green.

## Task 2: Add a bounded ordered output bridge

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnSSH/RemoteProcessOutputBridge.swift`
- Extend: `Packages/ConnPackages/Tests/ConnSSHTests/RemoteProcessChannelTests.swift`

- [ ] Write failing tests proving ordered delivery up to the configured chunk limit.
- [ ] Prove the first overflow finishes with `.outputBufferOverflow(maxBufferedChunks:)`; it may terminate the channel but may not silently continue after a dropped chunk.
- [ ] Prove normal finish, failure, overflow and consumer cancellation each invoke terminal callbacks at most once.
- [ ] Implement with a lock-protected completion gate around `AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit))` and inspect every `yield` result.
- [ ] Run focused tests green.

## Task 3: Implement the scripted Mock process channel

**Files:**

- Modify: `Packages/ConnPackages/Sources/ConnSSH/Mock/MockSSHTransport.swift`
- Extend: `Packages/ConnPackages/Tests/ConnSSHTests/MockSSHTransportTests.swift`

- [ ] Write failing tests for exact request capture, ordered stdout/stderr, writable stdin, PTY resize, result, local close and sibling-session survival.
- [ ] Add a sendable `ProcessResponse`/factory to `MockSSHTransport.Behavior` without changing existing command behavior.
- [ ] Implement a Mock channel that uses the bounded bridge, memoizes one result, and makes close idempotent.
- [ ] Ensure resize without a requested PTY returns `.terminalNotAllocated`.
- [ ] Run `ConnSSHTests` and full package tests green.

## Task 4: Citadel dependency decision gate

Do not implement the engine adapter by entering an interactive shell.

The acceptable long-term paths are:

1. contribute a minimal public child-channel API upstream and temporarily pin a reviewed revision; or
2. maintain a minimal fork that exposes PTY request + Exec request + channel writer/output/exit events with no Conn types in Citadel.

The patch surface must:

- create one session child channel;
- install handlers before network reads;
- optionally send `PseudoTerminalRequest(wantReply: true)`;
- then send `ExecRequest(wantReply: true)`;
- expose channel write/resize/close and exit-status/exit-signal;
- support bounded/controlled reads instead of an unbounded stream;
- never expose Citadel/NIOSSH types through `ConnSSH`.

After the dependency path is explicitly authorized, write engine tests first and implement `CitadelRemoteProcessChannel` in `ConnSSHCitadel`.

## Completion gate for this subphase

- [ ] focused RED was observed before each implementation;
- [ ] `swift test --package-path Packages/ConnPackages --filter ConnSSHTests` passes;
- [ ] `swift test --package-path Packages/ConnPackages` passes;
- [ ] `git diff --check` passes;
- [ ] no production code maps `openProcess` to `openShell`;
- [ ] no Citadel/NIOSSH type appears in `ConnSSH` public API.
