# tmux Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the provider-neutral persistent-terminal contracts, connection-bound context, and backend-profile persistence required by tmux without starting any remote tmux process yet.

**Architecture:** `ConnKit` owns durable provider-neutral profile values and repository contracts. `ConnSSH` atomically returns connection identity with its pooled session/platform profile and prepares machine-protocol POSIX runtimes. A new pure Swift `ConnMultiplexer` target owns provider registry, descriptor envelope, workspace and attachment lifecycle contracts. `ConnStore` adds SchemaV4 and the GRDB profile repository.

**Tech Stack:** Swift 5.10, Swift Package Manager, Swift Testing, GRDB 7, Foundation, ConnKit/ConnSSH dependency inversion.

---

## Scope and phase boundary

This is phase 1 of the confirmed tmux design. It deliberately does not add `RemoteProcessChannel`, tmux command rendering/parsing, a live `TmuxProvider`, terminal coordinator integration, or UI. Those are separate plans so every phase leaves compiling, testable software:

1. Foundation contracts and profile persistence — this plan.
2. SSH bidirectional remote process transport.
3. tmux protocol, typed operations, codecs, snapshots, and control hub.
4. tmux passthrough attachment and generic terminal coordinator integration.
5. launch chooser, Session Center, management UI, and end-to-end acceptance.

The user explicitly approved implementation on `main`; do not create a worktree. Do not run or alter a simulator in this phase.

## File map

- `Packages/ConnPackages/Package.swift` — publish `ConnMultiplexer`, declare target/test dependencies.
- `Packages/ConnPackages/Sources/ConnKit/Models/TerminalBackendProfile.swift` — durable provider-neutral backend profile.
- `Packages/ConnPackages/Sources/ConnKit/Repositories/TerminalBackendProfileRepository.swift` — profile query/save/delete/primary contract.
- `Packages/ConnPackages/Tests/ConnKitTests/TerminalBackendProfileTests.swift` — profile defaults, identity and Codable preservation.
- `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift` — return `SSHConnectionIdentity` in the same actor claim as session/profile.
- `Packages/ConnPackages/Sources/ConnSSH/RemoteScriptExecutionProvider.swift` — add a prepared POSIX runtime that invokes a previously validated absolute interpreter path.
- `Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift` — prove context identity matches the pooled connection.
- `Packages/ConnPackages/Tests/ConnSSHTests/RemoteScriptExecutionProviderTests.swift` — absolute interpreter validation and invocation.
- `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalModels.swift` — provider IDs, features, availability, workspace summaries and versioned descriptor envelopes.
- `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProvider.swift` — provider/context/attachment lifecycle protocols.
- `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProviderRegistry.swift` — deterministic platform/provider lookup with no fallback.
- `Packages/ConnPackages/Tests/ConnMultiplexerTests/PersistentTerminalProviderRegistryTests.swift` — Linux/macOS matching, Windows/Unknown rejection, descriptor routing, and close semantics.
- `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV4.swift` — `terminal_backend_profile` table and indexes.
- `Packages/ConnPackages/Sources/ConnStore/Records/TerminalBackendProfileRecord.swift` — lossless GRDB mapping.
- `Packages/ConnPackages/Sources/ConnStore/DAO/TerminalBackendProfileStore.swift` — transactional repository implementation.
- `Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift` — register SchemaV4.
- `Packages/ConnPackages/Tests/ConnStoreTests/SchemaV4Tests.swift` — migration, FK, indexes, unknown payload preservation.
- `Packages/ConnPackages/Tests/ConnStoreTests/TerminalBackendProfileStoreTests.swift` — ordering, immutable identity, primary election and dirty timestamps.

### Task 1: Add the backend-profile domain contract

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnKit/Models/TerminalBackendProfile.swift`
- Create: `Packages/ConnPackages/Sources/ConnKit/Repositories/TerminalBackendProfileRepository.swift`
- Test: `Packages/ConnPackages/Tests/ConnKitTests/TerminalBackendProfileTests.swift`

- [ ] **Step 1: Write failing model tests**

Cover:

- `id`, `hostID`, `providerID`, and `providerConfigurationKey` are explicit stable identity fields;
- defaults are enabled, non-primary, version 1, sort order 0, clean, and use millisecond timestamps;
- arbitrary unknown `providerID`, `configurationVersion`, and opaque JSON round-trip through Codable unchanged;
- changing display name does not change identity.

Representative API:

```swift
let profile = TerminalBackendProfile(
    hostID: "host-1",
    providerID: "future-provider",
    providerConfigurationKey: "named:ops",
    displayName: "Ops",
    configurationVersion: 7,
    configurationJSON: #"{"future":true}"#
)
#expect(profile.isEnabled)
#expect(profile.configurationVersion == 7)
```

- [ ] **Step 2: Run RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter TerminalBackendProfileTests
```

Expected: compile failure because the model and repository do not exist.

- [ ] **Step 3: Implement the minimal domain types**

Add a `Codable`, `Sendable`, `Equatable`, `Identifiable` struct following existing `Host` timestamp conventions. Add:

```swift
public protocol TerminalBackendProfileRepository: Sendable {
    func profiles(hostID: String, providerID: String?) throws -> [TerminalBackendProfile]
    func profile(id: String) throws -> TerminalBackendProfile?
    func save(_ profile: TerminalBackendProfile) throws
    func delete(id: String) throws
    func setPrimary(id: String?, hostID: String, providerID: String) throws
}
```

The domain layer keeps `configurationJSON` opaque and does not import tmux types.

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path Packages/ConnPackages --filter TerminalBackendProfileTests
swift test --package-path Packages/ConnPackages --filter ConnKitTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnKit Packages/ConnPackages/Tests/ConnKitTests
git commit -m "feat: add terminal backend profiles"
```

### Task 2: Bind platform context to connection identity

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`
- Modify: `Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift`

- [ ] **Step 1: Write a failing identity-context test**

Assert that `platformContext(for:)` returns `connectionIdentity == SSHConnectionIdentity(host:)`, and that an identity-changing host edit receives a different context identity even when address happens to match.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path Packages/ConnPackages --filter ConnectionManagerTests
```

Expected: compile failure because `RemotePlatformContext.connectionIdentity` is absent.

- [ ] **Step 3: Return identity atomically**

Add `public let connectionIdentity: SSHConnectionIdentity` to `RemotePlatformContext`. Construct it from the same `PoolKey` used to validate that the returned session remains the actor-owned pooled session. Do not let callers reconstruct identity separately.

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path Packages/ConnPackages --filter ConnectionManagerTests
swift test --package-path Packages/ConnPackages --filter ConnSSHTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift
git commit -m "feat: bind platform context to connection identity"
```

### Task 3: Prepare an absolute POSIX machine-protocol runtime

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnSSH/RemoteScriptExecutionProvider.swift`
- Modify: `Packages/ConnPackages/Tests/ConnSSHTests/RemoteScriptExecutionProviderTests.swift`

- [ ] **Step 1: Write failing prepared-runtime tests**

Cover absolute paths with spaces/single quotes, rejection of relative/empty/newline/NUL paths, unsupported platform/interpreter, and exact one-argument POSIX quoting of the complete script.

Representative API:

```swift
let provider = POSIXScriptExecutionProvider()
let runtime = try provider.prepareRuntime(
    resolvedExecutablePath: "/bin/sh",
    interpreter: .sh
)
#expect(try runtime.invocation(for: "printf '%s\\n' ok") == "/bin/sh -c 'printf '\\''%s\\n'\\'' ok'")
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path Packages/ConnPackages --filter RemoteScriptExecutionProviderTests
```

Expected: compile failure for `prepareRuntime`.

- [ ] **Step 3: Implement minimal prepared runtime**

Add a `PreparedRemoteScriptRuntime` value containing family, interpreter and validated absolute executable path. Its `invocation(for:)` reuses one internal POSIX argument encoder. Preserve the existing `invocation(for:interpreter:)` API for current snippet callers; the new overload is for machine protocols that must pin the probed path.

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path Packages/ConnPackages --filter RemoteScriptExecutionProviderTests
swift test --package-path Packages/ConnPackages --filter ConnSSHTests
```

Expected: PASS with existing snippet behavior unchanged.

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnSSH/RemoteScriptExecutionProvider.swift Packages/ConnPackages/Tests/ConnSSHTests/RemoteScriptExecutionProviderTests.swift
git commit -m "feat: prepare pinned POSIX script runtimes"
```

### Task 4: Add provider-neutral persistent-terminal contracts

**Files:**
- Modify: `Packages/ConnPackages/Package.swift`
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalModels.swift`
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProvider.swift`
- Create: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalProviderRegistry.swift`
- Create: `Packages/ConnPackages/Tests/ConnMultiplexerTests/PersistentTerminalProviderRegistryTests.swift`

- [ ] **Step 1: Declare target/test and write failing registry tests**

Add product/target `ConnMultiplexer` depending only on `ConnKit` and `ConnSSH`, plus `ConnMultiplexerTests`. Tests use fake providers and attachments to assert:

- exact provider ID and supported platform are both required;
- Windows/Unknown never select a POSIX-only provider;
- duplicate provider IDs are rejected deterministically;
- unknown provider and unsupported descriptor payload versions remain diagnosable and are never opened;
- registry routes initial/reconnect descriptors without provider-specific switches;
- attachment `close()` is provider-owned and idempotent.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path Packages/ConnPackages --filter ConnMultiplexerTests
```

Expected: compile failure because the target/contracts are absent.

- [ ] **Step 3: Implement focused model envelopes**

Implement public `Sendable`/`Codable`/`Equatable` values:

```swift
struct RemoteWorkspaceRef {
    let workspaceID: String
    let instancePayloadVersion: Int
    let providerInstancePayload: Data
}

struct PersistentAttachmentDescriptor {
    let providerID: String
    let profileID: String
    let workspace: RemoteWorkspaceRef
    let payloadVersion: Int
    let providerPayload: Data
}
```

Also add provider features, availability/freshness, workspace summary/count, create request, open reason, presentation, error enums, and descriptor metadata exactly needed by the design. Keep provider-specific topology out.

- [ ] **Step 4: Implement context, lifecycle protocols and registry**

`PersistentTerminalContext` contains one `SSHConnectionIdentity`, session, platform profile, and backend profile. `PersistentTerminalProvider` supplies probe/list/create/rename/destroy/make descriptor/open attachment. `PersistentTerminalAttachment` exposes descriptor/presentation and idempotent close. The registry performs exact provider lookup and validates provider/instance/attachment versions before opening; it never falls back to POSIX or another provider.

- [ ] **Step 5: Run GREEN**

```bash
swift test --package-path Packages/ConnPackages --filter ConnMultiplexerTests
swift test --package-path Packages/ConnPackages
```

Expected: PASS; no existing target gains UIKit/Citadel dependencies.

- [ ] **Step 6: Commit**

```bash
git add Packages/ConnPackages/Package.swift Packages/ConnPackages/Sources/ConnMultiplexer Packages/ConnPackages/Tests/ConnMultiplexerTests
git commit -m "feat: add persistent terminal provider contracts"
```

### Task 5: Add SchemaV4 for backend profiles

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV4.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift`
- Test: `Packages/ConnPackages/Tests/ConnStoreTests/SchemaV4Tests.swift`

- [ ] **Step 1: Write failing migration tests**

Start from V1+V2+V3, apply V4, and assert exact columns/types/defaults, FK `host_uuid → host(uuid) ON DELETE CASCADE`, unique identity index `(host_uuid, provider_id, provider_configuration_key)`, and partial unique primary index `(host_uuid, provider_id) WHERE is_primary = 1`.

Also assert host deletion cascades profile rows and duplicate identity/primary inserts fail.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path Packages/ConnPackages --filter SchemaV4Tests
```

Expected: compile failure because SchemaV4 is absent.

- [ ] **Step 3: Implement and register SchemaV4**

Create `terminal_backend_profile` using the exact schema from the design. Register `SchemaV4` after V3 in `AppDatabase.migrator`; never edit older migrations.

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path Packages/ConnPackages --filter SchemaV4Tests
swift test --package-path Packages/ConnPackages --filter AppDatabaseTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV4.swift Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift Packages/ConnPackages/Tests/ConnStoreTests/SchemaV4Tests.swift
git commit -m "feat: add terminal backend profile schema"
```

### Task 6: Implement the GRDB profile repository

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnStore/Records/TerminalBackendProfileRecord.swift`
- Create: `Packages/ConnPackages/Sources/ConnStore/DAO/TerminalBackendProfileStore.swift`
- Test: `Packages/ConnPackages/Tests/ConnStoreTests/TerminalBackendProfileStoreTests.swift`

- [ ] **Step 1: Write failing repository tests**

Cover:

- ordered lookup by host and optional provider;
- opaque unknown provider/configuration values round-trip unchanged;
- save refreshes `updatedAt` and sets `syncDirty`;
- an existing profile cannot mutate host/provider/configuration key under the same ID;
- setting primary atomically clears the previous primary;
- primary must be enabled;
- disabling/deleting primary elects the first enabled profile by `sort_order, created_at, uuid` or leaves none;
- all transaction failures roll back;
- deleting a host cascades profiles.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path Packages/ConnPackages --filter TerminalBackendProfileStoreTests
```

Expected: compile failure because the record/store are absent.

- [ ] **Step 3: Implement record mapping and transactional repository**

Use GRDB `DatabaseWriter.write` for save/delete/setPrimary. Define structured `TerminalBackendProfileStoreError` cases for missing profile, identity mutation, disabled primary, and scope mismatch. Do not decode provider JSON in ConnStore.

- [ ] **Step 4: Run GREEN and full regression**

```bash
swift test --package-path Packages/ConnPackages --filter TerminalBackendProfileStoreTests
swift test --package-path Packages/ConnPackages --filter ConnStoreTests
swift test --package-path Packages/ConnPackages
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnStore Packages/ConnPackages/Tests/ConnStoreTests
git commit -m "feat: persist terminal backend profiles"
```

## Completion gate

- [ ] `swift test --package-path Packages/ConnPackages` passes from a clean build graph.
- [ ] `git diff --check` passes.
- [ ] Only provider-neutral contracts exist; no tmux command, socket, parser, Hub, or UI behavior leaks into this phase.
- [ ] `ConnMultiplexer` depends on `ConnKit` and `ConnSSH` only.
- [ ] Unknown provider/configuration payloads survive persistence but cannot be executed without a matching provider/version.
- [ ] Every production behavior was preceded by a focused failing test.

