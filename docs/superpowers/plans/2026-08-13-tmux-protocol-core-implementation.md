# tmux Protocol Core Implementation Plan

> Execute on the existing `main` branch as explicitly requested by the user. Use test-first, atomic commits. This phase is transport-independent and does not weaken the explicit Citadel PTY+Exec dependency gate.

**Goal:** Build the provider-owned tmux identity, command-rendering, and Control Mode parsing core so later provider/Hub/UI work consumes typed values rather than constructing commands or parsing protocol text ad hoc.

**Architecture:** `ConnMultiplexer` owns normalized server locators, scoped tmux IDs, server-instance tokens, a closed `TmuxOperation` AST, two independent renderers, and an incremental byte parser. Control rendering emits only tmux command language. Shell rendering emits a trusted POSIX script containing the pinned tmux executable and locator; callers still execute that script through ConnSSH's prepared POSIX runtime. The parser frames `tmux -CC` DCS/ST markers, validates command blocks against a negotiated dialect, preserves unknown notifications, and bounds all pending input.

**Tech Stack:** Swift 5.10, Foundation `Data`, Swift Testing, SwiftPM.

## Task 1: Model and validate tmux identity/configuration

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxIdentity.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxIdentityTests.swift`

- [x] Write failing tests for default, named-socket, and normalized absolute socket-path locators.
- [x] Reject empty/control/NUL/slash named sockets and relative or parent-traversing socket paths.
- [x] Add validated `$session`, `@window`, and `%pane` ID wrappers that cannot cross entity kinds.
- [x] Add a structured, Codable `TmuxServerInstanceToken` containing normalized socket path, PID, and start time.
- [x] Prove PID reuse/start-time changes and locator changes produce unequal tokens and payloads round-trip losslessly.

## Task 2: Add the typed operation AST and Control Mode renderer

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxOperation.swift`
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlCommandRenderer.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlCommandRendererTests.swift`

- [x] Write failing tests for all first-release Session, Window, and Pane operations.
- [x] Keep bootstrap creation separate from ordinary token-bound operations.
- [x] Validate Conn-created names for non-empty bounded UTF-8 and reject C0/C1 controls.
- [x] Encode every tmux argument with a dedicated tmux command-language encoder.
- [x] Prove rendered Control commands contain no tmux executable, `-L`/`-S`, or POSIX shell quoting.

## Task 3: Add the independent Shell invocation renderer

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxShellInvocationRenderer.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxShellInvocationRendererTests.swift`

- [x] Write failing fixtures for default, `-L`, and `-S` profiles and hostile-but-valid names.
- [x] Require a validated absolute tmux executable path.
- [x] Render executable, locator, subcommand, and argv with POSIX argument encoding independent from Control rendering.
- [x] Add same-invocation server-token guard support; no write operation may use a separate preflight SSH call.
- [x] Prove the result can be wrapped by a prepared ConnSSH POSIX runtime without a PATH lookup.

## Task 4: Implement negotiated Control Mode grammar and byte parser

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProtocol.swift`
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProtocolParser.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProtocolParserTests.swift`

- [x] Write failing tests for split DCS/ST markers, byte-at-a-time lines, CRLF, and multiple messages per chunk.
- [x] Cover tmux 2.6 two-field and newer three-field `%begin/%end/%error` guards.
- [x] Preserve ordered command output and known/unknown asynchronous notifications.
- [x] Decode `%output` pane bytes using tmux octal escapes, including non-UTF-8 payload.
- [x] Reject malformed escapes, unmatched/nested blocks, guard mismatch, line overflow, preamble overflow, and EOF with partial protocol state.
- [x] Run a deterministic chunk-partition matrix proving every partition yields identical events.

## Completion gate

- [x] Focused RED is observed before every production type/behavior.
- [x] `swift test --package-path Packages/ConnPackages --filter ConnMultiplexerTests` passes.
- [ ] `swift test --package-path Packages/ConnPackages` passes from coherent build artifacts.
- [x] `git diff --check` passes.
- [x] `ConnMultiplexer` contains no Citadel, NIOSSH, UIKit, SwiftUI, or SwiftTerm imports.
- [x] Control and Shell renderers share typed operations but no final command string or quoting implementation.
- [x] No parser buffer is unbounded and unknown notifications never crash parsing.
