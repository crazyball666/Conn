# tmux State Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the transport-independent tmux snapshot codec, normalized state graph, client-risk projections, and generation-aware reducer required by the future Control Hub and provider.

**Architecture:** `ConnMultiplexer` keeps negotiated wire grammar separate from feature capabilities and enabled client configuration. Snapshot decoding converts bounded command-output bytes into strict fields before any IDs enter the graph. A validated normalized snapshot owns Sessions, shared Windows, Panes, links, groups, and clients; a pure reducer applies only self-contained events and requests scoped reconciliation whenever a notification lacks enough information to preserve graph invariants.

**Tech Stack:** Swift 5.10, Foundation `Data`/`Date`, ConnSSH `TermSize`, Swift Testing, SwiftPM.

**Execution constraint:** Work on the existing `main` branch as explicitly requested by the user. Do not create a worktree or dispatch subagents.

---

### Task 1: Separate protocol dialect, negotiated capability, and enabled configuration

**Files:**

- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProtocol.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProtocolDialectTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProtocolParserTests.swift`

- [x] **Step 1: Write failing tests** proving snapshot codec kind is an explicit dialect field, while supported client flags and actually enabled flags/subscriptions are distinct values.
- [x] **Step 2: Run RED:** `swift test --package-path Packages/ConnPackages --filter TmuxProtocolDialectTests` must fail because the new types do not exist.
- [x] **Step 3: Implement** `TmuxSnapshotCodecKind`, `TmuxClientFlag`, `TmuxNegotiatedCapabilities`, and `TmuxControlClientConfiguration`; extend `TmuxProtocolDialect` with required `snapshotCodec`.
- [x] **Step 4: Update parser fixtures** to choose a codec explicitly; parser behavior must remain independent of that choice.
- [x] **Step 5: Run GREEN:** dialect and parser suites pass.
- [x] **Step 6: Commit:** `feat: model tmux protocol negotiation`.

### Task 2: Decode bounded quoted and legacy snapshot output

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshotCodec.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxSnapshotCodecTests.swift`

- [x] **Step 1: Write failing quoted-codec tests** for empty fields, Unicode, spaces, quotes, backslashes, tabs, embedded newlines, multiple records, arbitrary chunk-derived output lines, and strict field counts.
- [x] **Step 2: Write failing rejection tests** for unterminated quotes/escapes, invalid UTF-8, unexpected bytes between fields, field/record/output limits, and malformed records.
- [x] **Step 3: Run RED:** `swift test --package-path Packages/ConnPackages --filter TmuxSnapshotCodecTests` must fail because the codecs do not exist.
- [x] **Step 4: Implement `TmuxQuotedSnapshotCodec`** as a byte lexer for records rendered as `"#{q:field}"`; a backslash quotes exactly the following byte, including a physical LF, while only an unescaped LF outside a field ends a record.
- [x] **Step 5: Implement `TmuxLegacySnapshotCodec`** for one independently queried untrusted text field by joining command-output lines with LF. It must never split multiple untrusted fields on a delimiter.
- [x] **Step 6: Bound every pending/output/field/record collection** and decode UTF-8 only after framing is complete.
- [x] **Step 7: Run GREEN** and `git diff --check`.
- [x] **Step 8: Commit:** `feat: decode tmux snapshot fields`.

### Task 3: Add a validated normalized tmux snapshot graph

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshot.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxSnapshotTests.swift`

- [x] **Step 1: Write failing construction tests** for one Window linked into multiple Sessions, grouped Sessions, Pane membership, current Window/Pane references, and dictionary-key identity.
- [x] **Step 2: Write failing validation tests** for dangling/mismatched IDs, duplicate links, invalid active Pane ownership, missing group members, and a Conn Control Client that incorrectly participates in size.
- [x] **Step 3: Write failing client-projection tests** for external, affected, interactive, size-participating, and relative-to-attachment counts. Unknown kind/size must be conservative and the Hub Control Client must be excluded where specified.
- [x] **Step 4: Run RED:** `swift test --package-path Packages/ConnPackages --filter TmuxSnapshotTests` must fail because snapshot types do not exist.
- [x] **Step 5: Implement** `TmuxServerInstance`, normalized Session/Window/Pane/Link/Client snapshots, metadata freshness, client role/kind/size participation, and throwing graph validation.
- [x] **Step 6: Implement graph projections** without copying shared Windows into per-Session trees.
- [x] **Step 7: Run GREEN** and all `ConnMultiplexerTests`.
- [x] **Step 8: Commit:** `feat: model normalized tmux snapshots`.

### Task 4: Apply safe events with generation-aware reconciliation

**Files:**

- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxStateReducer.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxStateReducerTests.swift`

- [ ] **Step 1: Write failing generation tests** proving stale snapshots/events are discarded and a server-token change invalidates all old IDs.
- [ ] **Step 2: Write failing mutation tests** for Session/Window rename, current Window, active Pane, and independent Pane metadata freshness updates.
- [ ] **Step 3: Write failing revision tests** proving every applied change increments `revision`, while ordinary title/path/command metadata does not increment `impactRevision`; names, topology, groups, Panes, and clients do.
- [ ] **Step 4: Write failing reconciliation tests** proving layout, add/close/link/group/client-dirty, unknown notification, missing targets, and invalid relationships do not partially corrupt state and instead return a scoped reconciliation request.
- [ ] **Step 5: Run RED:** `swift test --package-path Packages/ConnPackages --filter TmuxStateReducerTests` must fail because reducer types do not exist.
- [ ] **Step 6: Implement a pure `TmuxStateReducer`** that owns one generation/token and validated snapshot. Apply only events carrying sufficient typed data; return `.reconcile(scope:)` for incomplete topology information.
- [ ] **Step 7: Keep Pane output out of snapshot state** and keep protocol parsing out of the reducer.
- [ ] **Step 8: Run GREEN** and all `ConnMultiplexerTests`.
- [ ] **Step 9: Commit:** `feat: reduce tmux snapshot events`.

## Completion gate

- [ ] Every production behavior has a focused RED before implementation.
- [ ] `swift test --package-path Packages/ConnPackages --filter ConnMultiplexerTests` passes.
- [ ] `swift test --package-path Packages/ConnPackages` passes from current artifacts.
- [ ] `git diff --check` passes.
- [ ] Quoted snapshot decoding matches tmux `q:` byte escaping and never uses naïve tab/pipe splitting.
- [ ] Legacy decoding never combines multiple untrusted fields in one delimiter-based record.
- [ ] Snapshot graph has one Window entity even when linked into multiple Sessions.
- [ ] Unknown client kind/size is counted conservatively; Conn Control Clients are not user-risk or size participants.
- [ ] Old generations and changed server tokens cannot mutate current state.
- [ ] Incomplete topology events request reconciliation instead of speculative mutation.
