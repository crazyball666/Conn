# tmux Product Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Complete the user-facing tmux lifecycle from launch choice through Session/Window/Pane management, while preserving provider-neutral routing and safe POSIX/macOS/Linux degradation.

**Architecture:** Keep `ConnMultiplexer` as the tmux domain/runtime boundary. Expose the existing tmux catalog-management facet through a narrow coordinator API without teaching the generic coordinator tmux commands. Add App views that consume topology snapshots and submit typed operations with the existing impact/confirmation guard. Extend Control Mode negotiation as an explicit capability result; never infer unsupported flags from version alone.

**Tech Stack:** Swift 5.10 actors, SwiftUI, Swift Testing, SwiftPM, Xcode iOS target, Citadel SSH integration tests.

---

### Task 1: Make launch selection choose an existing workspace or create one

**Files:**

- Modify: `Packages/ConnPackages/Sources/ConnTerminal/PersistentProviderBackend.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`
- Modify: `Conn/Conn/Terminal/TerminalScreen.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/PersistentProviderBackendTests.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [x] Add provider-neutral workspace option/create-selection APIs containing the selected backend candidate and current workspace summaries.
- [x] Add tests proving selecting a specific remote workspace creates a descriptor for that workspace and selecting “new” calls `createWorkspace` exactly once.
- [x] Replace first-workspace auto-selection in the startup picker with explicit Attach/New/Plain PTY choices; keep automatic plain PTY fallback when no usable candidate exists.
- [x] Run focused terminal tests and App source consistency/build checks.

### Task 2: Expose and consume the tmux management facet

**Files:**

- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`
- Modify: `Conn/Conn/Terminal/TerminalSessionCenterView.swift`
- Create: `Conn/Conn/Terminal/TmuxWorkspaceManagementView.swift`
- Test: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionCoordinatorTests.swift`
- Test: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [x] Add narrow coordinator methods that return the provider-owned catalog attachment without downcasting or parsing commands in the coordinator.
- [x] Add a Session → Window → Pane management view that consumes `TmuxWorkspaceCatalogManaging.topology` and submits typed operations only.
- [x] Implement Session/Window/Pane select, rename, split, zoom, close, and Session kill actions; destructive actions use `prepareDestructive`/`executeDestructive` and display the returned impact.
- [x] Add “new Session” and empty-catalog actions so a server with no Session is usable from Session Center.
- [x] Ensure closing the view cancels observation and closes the catalog attachment.
- [x] Run focused coordinator tests and App source/build checks.

### Task 3: Negotiate Control Mode capabilities and truthful freshness

**Files:**

- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlRuntime.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlHub.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProvider.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProviderTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlHubTests.swift`

- [x] Add an explicit negotiated-capability result for Control Mode flags and metadata subscriptions.
- [x] Probe/enable only flags confirmed by the target tmux instance; preserve pass-through attach when optional negotiation fails.
- [x] Apply `ignore-size`/`active-pane` only when confirmed and expose the negotiated result otherwise.
- [x] Mark catalog metadata as live only while a live Control Mode observation stream is active; expose snapshot freshness for fallback catalogs and report format-subscription state separately.
- [x] Add coverage for optional capability/fallback models and freshness mapping.

### Task 4: Add real remote acceptance coverage

**Files:**

- Modify: `Packages/ConnPackages/Package.swift`
- Create: `Packages/ConnPackages/Tests/ConnSSHCitadelTests/TmuxMacHostIntegrationTests.swift`
- Create: `Packages/ConnPackages/Tests/ConnSSHCitadelTests/TmuxLinuxHostIntegrationTests.swift`
- Modify: `Spikes/S1-ssh-matrix/README.md`

- [x] Add opt-in, environment-gated SSH acceptance suites for macOS and Linux tmux lifecycle/Attach/catalog paths; installed/absent, server-absent and Control Mode fallback remain deterministic unit coverage.
- [x] Keep tests bounded and cleanup-safe; never kill pre-existing user Sessions.
- [x] Document required environment variables and the exact commands for macOS/Linux runs.
- [x] Run package tests; real acceptance suites are available and skip without explicit credentials/flags.

### Completion gate

- [x] Launch flow can attach a chosen Session or create a named new Session.
- [x] Session Center can inspect and manage Session/Window/Pane without provider-specific command construction in UI.
- [x] Control Mode optional capabilities are negotiated and freshness is truthful.
- [x] Real SSH acceptance is available and package tests pass.
- [x] Generic iOS build and `git diff --check` pass.
