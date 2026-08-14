# tmux End-to-End Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining tmux end-to-end gaps without changing the approved provider/profile/attachment architecture or introducing a database migration.

**Architecture:** Keep `ConnTerminal` provider-neutral and put tmux protocol/runtime behavior in `ConnMultiplexer`. Treat catalogs and attachments as profile-scoped runtime handles, give every local attachment a unique ephemeral identity, provision default profiles at the application composition boundary, and make UI state accurately reflect catalog/capability degradation. Existing persisted profile and descriptor envelopes remain the extension point for tmux, Zellij, Windows-native providers, and future backends.

**Tech Stack:** Swift 6, Swift Concurrency, Swift Testing, SwiftUI, SQLite-backed repositories, SSH remote process channels, tmux Control Mode.

---

## File map

- `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift`: tmux catalog/attachment orchestration and unique runtime attachment identity.
- `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlRuntime.swift`: negotiated Control Mode client configuration and subscriptions.
- `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlClient.swift`: bounded Control Mode request/close behavior.
- `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxOperation.swift`: typed internal client-flag operation when size policy needs it.
- `Packages/ConnPackages/Sources/ConnTerminal/PersistentProviderBackend.swift`: provider-neutral profile-scoped catalog API.
- `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`: application-facing forwarding API only; no tmux switch.
- `Conn/Conn/ConnApp.swift`: composition-root default profile provisioning for newly saved hosts.
- `Conn/Conn/Terminal/TerminalScreen.swift`: one startup choice flow for initial and additional ordinary terminals.
- `Conn/Conn/Terminal/TerminalSessionCenterView.swift`: profile-scoped catalog lifecycle, create-first-session route, stale state, retry, and resource release.
- `Conn/Conn/Terminal/TmuxWorkspaceManagementView.swift`: negotiated capability/metadata warnings and shared-operation impact presentation.
- Corresponding `*Tests.swift` files: regression and source-wiring coverage.

### Task 1: Make attachment identity local and unique

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProviderTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxOperationImpactTests.swift`

- [ ] Add a test opening two local attachments to the same tmux Session and assert their ownership IDs differ.
- [ ] Run `swift test --package-path Packages/ConnPackages --filter TmuxProviderTests` and verify the new test fails for the Session-ID collision.
- [ ] Generate one UUID-backed attachment ID per `openAttachment`, pass it through hub context/identity registration, and never persist it in the durable descriptor.
- [ ] Run the focused provider and impact tests and verify both attachments are classified/countable independently.

### Task 2: Represent a server-absent catalog as create-capable empty state

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProviderTests.swift`

- [ ] Add a test where static probe returns no server and `openCatalog` emits an empty snapshot with `instance == nil` instead of throwing.
- [ ] Run the focused test and verify the current implementation fails.
- [ ] Build the server-absent snapshot from the profile/provider scope; creation continues through the existing typed, atomic bootstrap path, with no fabricated instance token or persisted claim.
- [ ] Keep static catalog streams open for the attachment lifetime and finish them only from idempotent `close()`, so normal snapshot-only catalogs cannot be mistaken for a disconnected live stream.
- [ ] Verify server-running empty, server-absent empty, and degraded static catalog tests all pass.

### Task 3: Apply truthful Control Mode negotiation

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlRuntime.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlClient.swift`
- Create or modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlRuntimeTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlClientTests.swift`

- [ ] Add channel-harness tests proving supported safe flags are enabled, failed flags are not reported enabled, and subscriptions are registered only after a successful probe.
- [ ] Verify tests fail because the current runtime only probes and always reports an empty enabled configuration.
- [ ] Enable `no-output` and defensive Control Client `ignore-size`; enable `wait-exit` only with a bounded close handshake.
- [ ] Register the approved Session/Pane metadata subscriptions through typed Control requests and keep capability support separate from enabled configuration.
- [ ] Bound event buffering/coalescing so a slow UI cannot create unbounded memory growth.
- [ ] Run focused runtime/client/protocol tests.

### Task 4: Make default profiles and catalogs profile-scoped

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/PersistentProviderBackend.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`
- Modify: `Conn/Conn/ConnApp.swift`
- Modify: `Conn/Conn/Servers/ServersView.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/PersistentProviderBackendTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionCoordinatorTests.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] Add tests that catalog candidates include every enabled profile and opening a catalog requires the explicit provider/profile candidate.
- [ ] Add a composition/wiring test that saving a new host provisions its default tmux profile immediately and idempotently.
- [ ] Verify the tests fail against first-profile selection and boot-only provisioning.
- [ ] Add provider-neutral catalog candidates/open-by-candidate APIs and keep profile creation in the composition root.
- [ ] Forward the APIs through the coordinator and invoke idempotent provisioning after host save.
- [ ] Run focused ConnTerminal and app consistency tests.

### Task 5: Use one PTY/tmux picker for all ordinary terminal starts

**Files:**
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Modify: `Conn/Conn/Terminal/TerminalSessionCenterView.swift`
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] Add source/wiring tests that Session Center's “new terminal” route does not prelaunch plain PTY and that additional terminal creation invokes the same backend-choice state machine.
- [ ] Verify the tests fail against the two direct `TerminalLaunchRequest` call sites.
- [ ] Allow a terminal route with no existing tab and start `.createNew` through the normal picker.
- [ ] Refactor initial/additional launch into one policy-aware choice method; keep Docker/script entry points explicitly unchanged.
- [ ] Run app tests and a generic iOS build.

### Task 6: Close catalogs deterministically and expose stale/retry state

**Files:**
- Modify: `Conn/Conn/Terminal/TerminalSessionCenterView.swift`
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] Add tests for profile-keyed catalog handles, close-on-collapse/disappear, unexpected terminal stream completion becoming stale, and explicit retry. Static catalog streams remain open until explicit close and therefore do not enter this path after their first snapshot.
- [ ] Verify those tests fail against host-only dictionaries and retained live snapshots.
- [ ] Introduce a `CatalogKey(hostID, providerID, profileID)`, centralize close/cancel/removal, and release attachments on collapse/disappear/reload.
- [ ] Preserve the last snapshot as stale on unexpected stream end, show a concise issue, and provide retry/refresh.
- [ ] Run app tests and inspect concurrency diagnostics from the build.

### Task 7: Complete data-client size policy and safety/degradation UX

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxOperation.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlCommandRenderer.swift`
- Modify: `Conn/Conn/Terminal/TmuxWorkspaceManagementView.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProviderTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlCommandRendererTests.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [ ] Add tests for initial `ignore-size` followed by verified removal when no other size participant exists, and retention when another/unknown participant exists.
- [ ] Add tests that degraded `active-pane`, `ignore-size`, and metadata freshness are visible and that shared non-destructive mutations disclose affected clients.
- [ ] Verify the tests fail against attach-once flags and current UI.
- [ ] Add a typed internal client-flag mutation guarded by verified client identity and current instance scope; reevaluate on relevant topology snapshots while the attachment is active.
- [ ] Render capability/metadata degradation and require acknowledgement for operations that change a workspace currently used by other clients; keep destructive confirmation claims unchanged.
- [ ] Run focused operation/provider/app tests.

### Task 8: Full verification and review

**Files:**
- Modify only files required by review findings.

- [ ] Run `swift test --package-path Packages/ConnPackages` and record suite/test counts with zero failures.
- [ ] Run the app test target on the one already-booted simulator only if such a simulator is available; otherwise stop simulator testing and report it without creating another device.
- [ ] Run `xcodebuild build -workspace Conn.xcworkspace -scheme Conn -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`.
- [ ] Run `git diff --check` and inspect `git diff --stat` plus the complete scoped diff.
- [ ] Dispatch an independent code reviewer against the approved design and this remediation plan; fix every valid Critical/Important finding and repeat focused/full verification.
- [ ] Leave real macOS/Linux SSH acceptance explicitly reported as environment-gated unless credentials are present; never claim it ran when it skipped.
