# Persistent Terminal Configuration Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove database-backed terminal profiles and make each persistent-terminal attachment carry an immutable provider configuration snapshot.

**Architecture:** `ConnMultiplexer` owns a provider-neutral `PersistentTerminalConfiguration` value and provider registry defaults. `ConnTerminal` lists registry options locally, probes only the selected provider, and stores a self-contained descriptor in each in-memory Tab. `ConnStore` returns to host-only persistence and drops the obsolete profile table through a data-preserving migration.

**Tech Stack:** Swift 6, Swift Testing, GRDB, SwiftUI, ConnMultiplexer provider registry, ConnTerminal coordinator, tmux Control Mode

---

## Working-tree constraint

Implementation runs in the current `main` worktree at the user's request. The worktree already contains overlapping uncommitted terminal changes, so every edit must preserve existing changes. Do not make intermediate implementation commits that could accidentally capture unrelated hunks; use focused diffs and verification checkpoints. Commit only when the user explicitly requests it.

### Task 1: Replace durable profile identity with a configuration value

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalConfiguration.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalModels.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProviderRegistry.swift`
- Delete: `Packages/ConnPackages/Sources/ConnKit/Models/TerminalBackendProfile.swift`
- Delete: `Packages/ConnPackages/Sources/ConnKit/Repositories/TerminalBackendProfileRepository.swift`
- Delete test: `Packages/ConnPackages/Tests/ConnKitTests/TerminalBackendProfileTests.swift`
- Create test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/PersistentTerminalConfigurationTests.swift`
- Modify test: `Packages/ConnPackages/Tests/ConnMultiplexerTests/PersistentTerminalProviderRegistryTests.swift`

- [x] **Step 1: Add failing configuration and descriptor tests**

Cover value equality/Codable, provider ID mismatch, unsupported configuration version, and descriptor round trip without `profileID`.

```swift
let configuration = PersistentTerminalConfiguration(
    providerID: "fake",
    configurationKey: "default",
    payloadVersion: 1,
    providerPayload: Data("{}".utf8)
)
let descriptor = PersistentAttachmentDescriptor(
    providerID: "fake",
    configuration: configuration,
    workspace: workspace,
    payloadVersion: 1,
    providerPayload: Data()
)
#expect(descriptor.configuration == configuration)
```

- [x] **Step 2: Run targeted tests and verify compile/test failure**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter PersistentTerminalConfigurationTests
swift test --package-path Packages/ConnPackages --filter PersistentTerminalProviderRegistryTests
```

Expected: FAIL because the configuration type/default-provider contract does not exist and descriptor still requires `profileID`.

- [x] **Step 3: Implement the configuration envelope and registry validation**

Add:

```swift
public struct PersistentTerminalConfiguration: Sendable, Codable, Equatable, Hashable {
    public let providerID: String
    public let configurationKey: String
    public let payloadVersion: Int
    public let providerPayload: Data
}
```

Make every `PersistentTerminalProvider` expose `defaultConfiguration`. Replace `PersistentTerminalContext.backendProfile` with `backendConfiguration`. Make descriptor embed the configuration value. Registry validation must check provider ID and supported configuration version before calling provider code.

Add a provider-neutral enumeration result and deterministic registry API so callers never need access to private `providersByID` or bypass routing validation:

```swift
public struct PersistentTerminalProviderDefault: Sendable, Equatable {
    public let descriptor: PersistentTerminalProviderDescriptor
    public let configuration: PersistentTerminalConfiguration
}

public func registeredDefaults() -> [PersistentTerminalProviderDefault]
```

`registeredDefaults()` returns entries sorted by provider ID and validates that each default configuration's provider ID and version match its descriptor.

- [x] **Step 4: Remove ConnKit profile model/repository and update test fixtures**

Move provider configuration fixtures into ConnMultiplexer tests. Do not create a replacement repository or in-memory profile service.

- [x] **Step 5: Run focused tests**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter PersistentTerminalConfigurationTests
swift test --package-path Packages/ConnPackages --filter PersistentTerminalProviderRegistryTests
```

Expected: PASS.

### Task 2: Convert tmux provider and Control Mode scopes from profile ID to configuration key

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxOperation.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlHub.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlHubRuntimeAdapter.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxSnapshotLoader.swift`
- Modify tests matching `Packages/ConnPackages/Tests/ConnMultiplexerTests/Tmux*Tests.swift`
- Modify acceptance fixtures: `Packages/ConnPackages/Tests/ConnSSHCitadelTests/MacHostIntegrationTests.swift`
- Modify acceptance fixtures: `Packages/ConnPackages/Tests/ConnSSHCitadelTests/TmuxLinuxHostIntegrationTests.swift`

- [x] **Step 1: Change tests to construct tmux configuration values**

Replace `makeProfile()` helpers with:

```swift
func makeTmuxConfiguration(
    locator: TmuxServerLocator = .default
) throws -> PersistentTerminalConfiguration {
    let payload = try JSONEncoder().encode(TmuxProviderConfiguration(locator: locator))
    return PersistentTerminalConfiguration(
        providerID: TmuxProvider.providerID,
        configurationKey: locator.configurationKey,
        payloadVersion: TmuxProvider.configurationVersion,
        providerPayload: payload
    )
}
```

Update operation-scope tests to expect `configurationKey` and `invalidConfigurationKey`.

- [x] **Step 2: Run tmux tests and verify failure**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter Tmux
```

Expected: compile failures at remaining profile APIs.

- [x] **Step 3: Implement tmux configuration decoding and self-contained descriptors**

`TmuxProvider.defaultConfiguration` returns the encoded default locator. `decodeConfiguration` reads `context.backendConfiguration`. `makeAttachmentDescriptor` embeds the configuration snapshot. `openAttachment` validates descriptor configuration against the context without a repository lookup.

- [x] **Step 4: Rename runtime scope identity**

Replace every runtime `profileID` with canonical `configurationKey`, including operation scope, Control Hub invalidation, snapshot loaders, control runtime registry keys, interaction facets, errors and diagnostics. Scope identity remains connection identity + configuration key + server token + generation.

- [x] **Step 5: Run tmux and multiplexer tests**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter ConnMultiplexerTests
swift test --package-path Packages/ConnPackages --filter Tmux
```

Expected: PASS with no source-level `profileID` reference in ConnMultiplexer.

### Task 3: Make terminal selection registry-driven and probe only the selected provider

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/PersistentProviderBackend.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalSessionCoordinator.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/NewTerminalFlowModel.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/PersistentTerminalDiagnostics.swift`
- Modify: `Conn/Conn/Terminal/NewTerminalSheet.swift`
- Modify tests: `Packages/ConnPackages/Tests/ConnTerminalTests/PersistentProviderBackendTests.swift`
- Modify tests: `Packages/ConnPackages/Tests/ConnTerminalTests/NewTerminalFlowModelTests.swift`
- Modify tests: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalSessionCoordinatorTests.swift`
- Modify tests: `Packages/ConnPackages/Tests/ConnTerminalTests/PersistentTerminalDiagnosticsTests.swift`

- [x] **Step 1: Add failing option/probe-boundary tests**

Tests must prove:

- listing options is local and causes zero SSH/probe calls;
- plain PTY causes zero provider calls;
- selecting tmux probes and lists only tmux;
- with fake tmux and fake Zellij, selecting one never probes the other;
- descriptor reconnect performs no repository access;
- executable missing/unsupported platform triggers PTY fallback, while SSH/network failure remains visible and retryable.

- [x] **Step 2: Run terminal-flow tests and verify failure**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter PersistentProviderBackendTests
swift test --package-path Packages/ConnPackages --filter NewTerminalFlowModelTests
swift test --package-path Packages/ConnPackages --filter TerminalSessionCoordinatorTests
```

Expected: FAIL because the backend still loads all database profiles and probes all candidates.

- [x] **Step 3: Replace candidates with local options**

Introduce `PersistentBackendOption` carrying provider ID, display name and configuration. `PersistentProviderBackend.options()` maps only `registry.registeredDefaults()` and performs no SSH work. `workspaceOptions(for:)` obtains one platform context, probes that selected provider, and lists workspaces only when availability is `.available` or `.degraded`.

- [x] **Step 4: Remove repository dependencies from backend/coordinator**

Construct `PersistentProviderBackend` directly from the registry. Remove optional `profileRepository` initializer arguments and all `profileUnavailable` branches. All create/attach/catalog/descriptor/open methods consume option or descriptor configuration values.

- [x] **Step 5: Implement precise fallback semantics in NewTerminalFlowModel**

When selected provider reports executable missing or unsupported platform, launch `.plainPTY` through the existing launch-attempt transaction and expose one non-blocking explanation. Authentication, transport, timeout, invalid configuration and uncertain mutation errors remain in the sheet and never auto-fallback.

- [x] **Step 6: Run terminal tests**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter ConnTerminalTests
```

Expected: PASS.

### Task 4: Remove profile persistence from host save and App composition

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnStore/DAO/HostStore.swift`
- Delete: `Packages/ConnPackages/Sources/ConnStore/DAO/TerminalBackendProfileStore.swift`
- Delete: `Packages/ConnPackages/Sources/ConnStore/Records/TerminalBackendProfileRecord.swift`
- Create: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV5.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift`
- Modify: `Conn/Conn/ConnApp.swift`
- Modify tests: `Packages/ConnPackages/Tests/ConnStoreTests/HostStoreTests.swift`
- Delete tests: `Packages/ConnPackages/Tests/ConnStoreTests/TerminalBackendProfileStoreTests.swift`
- Add/replace tests: `Packages/ConnPackages/Tests/ConnStoreTests/SchemaV5Tests.swift`
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`

- [x] **Step 1: Add failing final-schema and pure-host tests**

Build a V4 database containing a host and a profile, migrate through V5, then assert:

```swift
#expect(try tableExists("terminal_backend_profile", db: db) == false)
#expect(try HostRecord.fetchCount(db) == 1)
```

Add a static/runtime HostStore test proving save has no provider factory, query or write.

- [x] **Step 2: Run store tests and verify failure**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter HostStoreTests
swift test --package-path Packages/ConnPackages --filter SchemaV5Tests
```

Expected: FAIL because HostStore still provisions profiles and V5 is absent.

- [x] **Step 3: Restore pure HostStore and add SchemaV5**

Remove `defaultTerminalProfiles`, profile-host validation and provisioning methods. V5 executes only:

```sql
DROP TABLE IF EXISTS terminal_backend_profile
```

Register V5 after V4 so other user data survives.

- [x] **Step 4: Simplify App composition**

Construct `HostStore(database:)` directly. Remove profile store construction, startup provisioning, default profile factories and profile repository injection in both live and demo dependencies.

- [x] **Step 5: Run store and app consistency tests**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter ConnStoreTests
xcodebuild build-for-testing -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS'
```

Expected: PASS and `TEST BUILD SUCCEEDED`.

### Task 5: Remove obsolete profile vocabulary and verify extension boundaries

**Files:**
- Modify all remaining tests returned by the profile-vocabulary search.
- Modify: `docs/superpowers/specs/2026-08-12-tmux-integration-design.md` only to add a supersession notice linking the approved replacement spec; do not rewrite historical implementation detail.
- Modify any package exports/source lists discovered by compilation.

- [x] **Step 1: Add fake second-provider extension test**

Register fake tmux and fake Zellij providers. Assert both options appear locally, selecting Zellij uses its configuration payload, and no ConnStore type is required.

- [x] **Step 2: Eliminate obsolete runtime vocabulary**

Run:

```bash
rg -n "TerminalBackendProfile|TerminalBackendProfileRepository|TerminalBackendProfileStore|profileRepository|profileID|backendProfile|invalidProfileID|profileUnavailable|providerDisabled" Packages/ConnPackages/Sources Conn/Conn
```

Expected: no runtime matches. Historical migration/spec text may remain only where intentionally documented.

- [x] **Step 3: Run the complete package suite**

Run:

```bash
swift test --package-path Packages/ConnPackages
```

Expected: all tests pass.

- [x] **Step 4: Build the complete iOS workspace**

Run:

```bash
xcodebuild build-for-testing -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS'
```

Expected: `TEST BUILD SUCCEEDED`. This generic build does not create, start, stop or switch simulators.

- [x] **Step 5: Final review**

Run:

```bash
git diff --check
git status --short --branch
```

Review only actual Critical/Important correctness issues: host save isolation, selected-provider-only probing, descriptor self-containment, runtime scope identity, migration data preservation and cancellation/resource ownership.
