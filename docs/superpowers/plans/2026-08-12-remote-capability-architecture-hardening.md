# Remote Capability Architecture Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every snippet execution through platform-aware script and requirement providers, extract Docker probing behind feature-local providers, and verify the real macOS SSH transport surfaces without changing persistence or adding Windows behavior.

**Architecture:** `ConnKit` keeps only shared capability values, `ConnSSH` owns stateless remote-script execution providers, `ConnOps` owns Docker environment providers, and `ConnRunner` owns the host-preparation/execution planner plus requirement adapter contracts. The App target is the composition root that adapts Docker into snippet requirements. Both silent and terminal execution consume the same planner-produced command while audit history stores only the rendered user script.

**Tech Stack:** Swift 5.10, Swift Concurrency, Swift Testing, Swift Package Manager, iOS 17/macOS 15 package targets, Citadel SSH, SwiftUI.

---

## Scope and execution rules

- Keep `Snippet.platforms.isEmpty` meaning “no author restriction”; technical readiness is always checked separately.
- Do not change GRDB schemas, persisted `ShellInterpreter` raw values, snippet records, or run-history records.
- Implement Linux/macOS POSIX support only. Windows/Unknown must return structured unsupported states without executing POSIX probes.
- Keep provider registries feature-local. `ConnRunner` must not depend on `ConnOps`; the App target injects the Docker requirement adapter.
- Work on `main` as explicitly authorized. Do not create a worktree or branch.
- Follow red-green-refactor for every behavior change. Do not begin a later task while focused tests are failing.
- Simulator verification may use only a simulator that is already booted by the user. Never create, boot, reboot, clone, or shut down a simulator.

### Task 1: Add the intrinsic script capability and POSIX execution provider

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/RemotePlatform.swift`
- Modify: `Packages/ConnPackages/Tests/ConnKitTests/RemotePlatformTests.swift`
- Create: `Packages/ConnPackages/Sources/ConnSSH/RemoteScriptExecutionProvider.swift`
- Create: `Packages/ConnPackages/Tests/ConnSSHTests/RemoteScriptExecutionProviderTests.swift`

- [ ] **Step 1: Write failing capability and provider tests**

Add a `RemoteCapability.scriptExecution` Codable round-trip assertion. Add provider tests covering all selection boundaries:

```swift
@Test("默认 registry 只为 Linux/macOS 的已知 POSIX 解释器选 provider")
func defaultRegistrySelection() {
    let registry = RemoteScriptExecutionProviderRegistry.default
    #expect(registry.provider(for: .linux, interpreter: .sh)?.family == .posix)
    #expect(registry.provider(for: .macOS, interpreter: .zsh)?.family == .posix)
    #expect(registry.provider(for: .windows, interpreter: .sh) == nil)
    #expect(registry.provider(for: .unknown, interpreter: .bash) == nil)
}

@Test("POSIX provider 构造只读解释器探测并正确转义完整脚本")
func posixInvocation() throws {
    let provider = POSIXScriptExecutionProvider()
    #expect(provider.interpreterProbeCommand(for: .bash).contains("command -v bash"))
    #expect(try provider.invocation(for: "printf '%s\\n' \"$HOME\"", interpreter: .bash)
        == "bash -c 'printf '\\''%s\\n'\\'' \"$HOME\"'")
}
```

Also inject a test provider into a registry and assert registry selection is driven by both platform and interpreter, with no fallback.

- [ ] **Step 2: Confirm RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter RemotePlatformTests
swift test --package-path Packages/ConnPackages --filter RemoteScriptExecutionProviderTests
```

Expected: compile failures because `.scriptExecution` and provider types do not exist.

- [ ] **Step 3: Implement minimal provider contracts and registry**

Add public `RemoteScriptFamily`, `RemoteScriptExecutionProvider`, `RemoteScriptExecutionError`, `POSIXScriptExecutionProvider`, and an injectable `RemoteScriptExecutionProviderRegistry`. The default registry contains one POSIX provider supporting Linux/macOS and `sh`/`bash`/`zsh`. Its lookup must return nil for Windows/Unknown or unsupported interpreters, never a POSIX fallback.

The provider owns interpreter probing and POSIX single-quote escaping. It is stateless and `Sendable`; it must reject an interpreter outside `supportedInterpreters` even when called directly.

The probe command must leave the discovered executable path on stdout. This gives the planner a platform-neutral result contract: nonzero exit means the enumerated executable is missing, zero exit plus a non-empty path means available, and zero exit with empty/whitespace output is an abnormal query result. Do not redirect successful `command -v` output to `/dev/null`.

- [ ] **Step 4: Run focused and module tests**

```bash
swift test --package-path Packages/ConnPackages --filter RemotePlatformTests
swift test --package-path Packages/ConnPackages --filter RemoteScriptExecutionProviderTests
swift test --package-path Packages/ConnPackages --filter ConnSSHTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnKit/Models/RemotePlatform.swift Packages/ConnPackages/Tests/ConnKitTests/RemotePlatformTests.swift Packages/ConnPackages/Sources/ConnSSH/RemoteScriptExecutionProvider.swift Packages/ConnPackages/Tests/ConnSSHTests/RemoteScriptExecutionProviderTests.swift
git commit -m "feat: add remote script execution providers"
```

### Task 2: Extract Docker probing into platform providers

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnOps/DockerEnvironmentProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerRuntimeContext.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerService.swift`
- Modify: `Packages/ConnPackages/Tests/ConnOpsTests/DockerOperationServiceTests.swift`

- [ ] **Step 1: Write failing provider and facade tests**

Extend `DockerRuntimeProbeTests` to assert:

- the default registry selects distinct Linux and Darwin providers;
- Windows/Unknown have no provider and execute zero commands;
- Linux discovery contains Linux candidates but not the Docker Desktop bundle;
- Darwin discovery contains Homebrew and Docker Desktop candidates;
- direct success, sudo success, CLI missing, daemon stopped, and permission denied preserve current classifications;
- `DockerService.probe(on:profile:)` delegates to an injectable registry/provider instead of owning a platform switch.

Use `RecordingSSHSession.invocations` to prove each successful preparation performs one discovery and one direct availability probe, adding the sudo probe only when direct access fails.

- [ ] **Step 2: Confirm RED**

```bash
swift test --package-path Packages/ConnPackages --filter DockerRuntimeProbeTests
```

Expected: compile failures for the new provider/registry APIs.

- [ ] **Step 3: Implement feature-local providers**

Add:

```swift
public protocol DockerEnvironmentProvider: Sendable {
    var platform: RemotePlatformKind { get }
    func probe(on session: any SSHSession) async throws -> DockerProbeResult
}
```

Create `LinuxDockerEnvironmentProvider`, `DarwinDockerEnvironmentProvider`, and `DockerEnvironmentProviderRegistry`. Share the daemon/permission/Compose parsing in a private POSIX probe helper, but pass platform-owned executable candidates into that helper. Move platform candidate construction out of `DockerRuntimeContext.discoveryCommand(for:)`; runtime context remains a value describing an already discovered executable.

Keep `DockerService.probe(on:profile:)` as a compatibility facade. Its default registry returns `.unsupportedPlatform` without calling SSH when no provider exists. Add an overload or parameter that allows tests/composition to inject a registry.

- [ ] **Step 4: Verify Docker regressions**

```bash
swift test --package-path Packages/ConnPackages --filter DockerRuntimeProbeTests
swift test --package-path Packages/ConnPackages --filter ConnOpsTests
```

Expected: PASS with existing Docker command and runtime behavior unchanged.

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnOps/DockerEnvironmentProvider.swift Packages/ConnPackages/Sources/ConnOps/DockerRuntimeContext.swift Packages/ConnPackages/Sources/ConnOps/DockerService.swift Packages/ConnPackages/Tests/ConnOpsTests/DockerOperationServiceTests.swift
git commit -m "refactor: extract Docker environment providers"
```

### Task 3: Build the generic snippet preparation and execution planner

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnRunner/SnippetExecutionPlanner.swift`
- Create: `Packages/ConnPackages/Tests/ConnRunnerTests/SnippetExecutionPlannerTests.swift`

- [ ] **Step 1: Write failing planner tests with test providers/adapters**

Create fixture script providers and requirement adapters plus `MockSSHTransport`/an injected platform detector. Cover these cases independently:

1. Empty `snippet.platforms` still probes script readiness.
2. Windows/Unknown with no provider returns `.blocked` containing only `.scriptExecution = .unsupported(.unsupportedPlatform)` and executes no interpreter or requirement probe.
3. An explicit author-platform mismatch blocks before provider selection and omits unprobed requirement keys.
4. A missing interpreter reports `.unavailable(.executableMissing)` and does not run requirement adapters.
5. A zero-exit interpreter probe with empty/whitespace output reports `.unavailable(.queryFailed)` rather than executable missing.
6. Interpreter-probe transport errors propagate and do not fabricate a capability state.
7. A provider/interpreter match with a non-empty discovered path reports `.scriptExecution = .supported`.
8. `.scriptExecution` present in `requiredCapabilities` is satisfied intrinsically and never looked up as an adapter.
9. Required adapters are selected by `(capability, scriptFamily)`; a missing adapter or wrong-family adapter reports unsupported and contributes no prelude.
10. Once the requirement phase starts, all declared requirements are prepared and included in the report even if one blocks execution.
11. `.degraded` is executable; `.unavailable` and `.unsupported` block.
12. Prelude order follows capability raw-value order rather than `Set` iteration order.
13. Re-rendering variables creates a new plan from the same preparation without another SSH probe.
14. `auditScript` excludes trusted preludes, while `preparedCommand` contains ordered preludes followed by rendered user script and exactly one provider wrapper.
15. Provider invocation failure propagates without creating a partial plan.
16. Preparations for multiple hosts retain independent profiles, reports, providers, and preludes.

Representative assertion:

```swift
let preparation = try #requireReady(await planner.prepare(snippet: snippet, on: host))
let plan = try planner.makeExecutionPlan(renderedScript: "echo prod", from: preparation)
#expect(plan.auditScript == "echo prod")
#expect(plan.preparedCommand.contains("docker()"))
#expect(plan.preparedCommand.contains("echo prod"))
#expect(adapter.calls == 1)
```

- [ ] **Step 2: Confirm RED**

```bash
swift test --package-path Packages/ConnPackages --filter SnippetExecutionPlannerTests
```

Expected: compile failure because the planner contracts do not exist.

- [ ] **Step 3: Implement requirement contracts and immutable results**

Implement public, `Sendable` types:

- `SnippetRequirementAdapter` with `capability`, `scriptFamily`, and async `prepare`;
- `SnippetRequirementResolution` with `CapabilityState` and optional trusted prelude;
- injectable `SnippetRequirementAdapterRegistry` keyed by capability plus family;
- `SnippetHostPreparation` containing profile, report, stable preludes, interpreter, and the selected stateless execution-provider existential;
- `SnippetExecutionPlan` containing `auditScript`, `preparedCommand`, interpreter, and report;
- `SnippetHostPreparationResult.ready/blocked`;
- `SnippetExecutionPlanner` with injected `ConnectionManager`, script-provider registry, and requirement-adapter registry.

Keep session ownership inside `ConnectionManager`; preparations must not retain sessions or Docker types. A duplicate adapter key uses deterministic registration order and is covered/documented rather than silently changing across runs.

- [ ] **Step 4: Implement the exact preparation algorithm**

`prepare(snippet:on:)` must:

1. obtain the cached platform profile/session;
2. enforce author restrictions when non-empty;
3. select by platform and interpreter;
4. execute the selected provider's interpreter probe and classify nonzero as `.executableMissing`, zero plus non-empty stdout as supported, and zero plus empty/whitespace stdout as `.queryFailed`; let transport errors propagate;
5. always record the intrinsic `.scriptExecution` state;
6. sort non-intrinsic required capabilities by raw value;
7. resolve every adapter in that phase and collect states/preludes;
8. return blocked for any unavailable/unsupported state, ready otherwise.

Do not write fake states for requirements skipped by an earlier block. `makeExecutionPlan` is pure: concatenate trusted non-empty preludes plus rendered script with newlines, do not inject global `set -e`, and ask the stored provider to wrap the combined script.

- [ ] **Step 5: Run focused and module tests**

```bash
swift test --package-path Packages/ConnPackages --filter SnippetExecutionPlannerTests
swift test --package-path Packages/ConnPackages --filter ConnRunnerTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnRunner/SnippetExecutionPlanner.swift Packages/ConnPackages/Tests/ConnRunnerTests/SnippetExecutionPlannerTests.swift
git commit -m "feat: plan snippet execution from remote capabilities"
```

### Task 4: Adapt Docker requirements in the App composition root

**Files:**
- Create: `Conn/Conn/Commands/DockerSnippetRequirementAdapter.swift`
- Create: `Conn/Conn/Commands/SnippetCapabilityPresentation.swift`
- Modify: `Conn/Conn/ConnApp.swift`
- Create: `Conn/ConnTests/DockerSnippetRequirementAdapterTests.swift`
- Create: `Conn/ConnTests/SnippetCapabilityPresentationTests.swift`
- Modify: `Conn/ConnTests/DockerModelsTests.swift`
- Modify: `Conn/ConnTests/RemoteFileIntegrityTests.swift`

- [ ] **Step 1: Write failing adapter and presentation tests**

Inject fake `DockerEnvironmentProvider` results and assert this exact mapping:

| Docker result | Capability state | Prelude |
|---|---|---|
| `.available` + runtime | `.supported` | runtime bootstrap |
| `.available` + nil runtime | `.unavailable(.queryFailed)` | nil |
| `.notInstalled` | `.unavailable(.executableMissing)` | nil |
| `.permissionDenied` | `.unavailable(.permissionDenied)` | nil |
| `.daemonNotRunning` | `.unavailable(.daemonNotRunning)` | nil |
| no platform provider / `.unsupportedPlatform` | `.unsupported(.unsupportedPlatform)` | nil |

Assert the adapter is `.docker` + `.posix`, probes exactly once, and never emits bootstrap for an unusable result. Add pure presentation tests so reports produce stable localized blocker/degraded messages without UI code knowing Docker-specific probe types.

- [ ] **Step 2: Confirm RED**

Using only the user's currently booted simulator UDID if available:

```bash
xcrun simctl list devices booted
xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,id=<BOOTED_UDID>' -only-testing:ConnTests/DockerSnippetRequirementAdapterTests -only-testing:ConnTests/SnippetCapabilityPresentationTests
```

If CoreSimulatorService or the booted device is unavailable, stop simulator operations, record that limitation, and use the generic build plus package tests in later steps.

- [ ] **Step 3: Implement the adapter and capability presentation**

`DockerSnippetRequirementAdapter` lives in the App target because it imports both `ConnRunner` and `ConnOps`. It owns an injected `DockerEnvironmentProviderRegistry`, selects from the profile, probes once, maps the result, and converts a usable runtime to `shellBootstrapCommand` immediately.

`SnippetCapabilityPresentation` consumes only `RemoteCapabilityReport`/`CapabilityState`, prioritizes `.scriptExecution`, and maps reason codes to user-facing text. It must not import or switch on Docker availability.

- [ ] **Step 4: Inject one planner into all App dependency graphs**

Add `snippetExecutionPlanner` to `AppDependencies`. In `live()` and `demo()`, create it from the shared `ConnectionManager`, the default remote-script registry, and a requirement registry containing the POSIX Docker adapter. Update the two test dependency builders in `DockerModelsTests.swift` and `RemoteFileIntegrityTests.swift`.

- [ ] **Step 5: Verify App compilation/tests**

```bash
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator'
```

If an existing user simulator is available, rerun the two focused `ConnTests`; otherwise do not boot one.

- [ ] **Step 6: Commit**

```bash
git add Conn/Conn/Commands/DockerSnippetRequirementAdapter.swift Conn/Conn/Commands/SnippetCapabilityPresentation.swift Conn/Conn/ConnApp.swift Conn/ConnTests/DockerSnippetRequirementAdapterTests.swift Conn/ConnTests/SnippetCapabilityPresentationTests.swift Conn/ConnTests/DockerModelsTests.swift Conn/ConnTests/RemoteFileIntegrityTests.swift
git commit -m "feat: compose snippet capability requirements"
```

### Task 5: Atomically migrate runner, readiness UI, terminal, and silent execution to plans

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnRunner/SnippetRunner.swift`
- Modify: `Packages/ConnPackages/Tests/ConnRunnerTests/SnippetRunnerBatchTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnSSH/SSHTransport.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/ShellInterpreter.swift`
- Modify: `Packages/ConnPackages/Sources/ConnSSH/Mock/MockSSHTransport.swift`
- Modify: `Packages/ConnPackages/Tests/ConnSSHTests/MockSSHTransportTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnKitTests/SnippetTests.swift`
- Modify: `Conn/Conn/Commands/SnippetRunView.swift`
- Modify: `Conn/ConnTests/SnippetCapabilityPresentationTests.swift`

- [ ] **Step 1: Write failing audit/command separation tests**

Refactor runner tests around `SnippetExecutionPlan`. Assert:

- `session.exec` receives `preparedCommand` exactly;
- `RunOutcome.script` and pending/final history entries contain `auditScript` only;
- interpreter in outcome/history comes from the plan;
- batch execution requires one plan per host and uses the matching host plan;
- a missing host plan becomes that host's independent failure and never falls back to a raw/default script;
- audit record failure prevents SSH execution;
- final audit update failure preserves the existing `auditUpdateFailed` behavior.

- [ ] **Step 2: Add view-facing boundary coverage**

Extend presentation/planner tests to cover the UI contract:

- empty author platforms do not imply compatibility;
- `.degraded` reports are executable but produce a warning;
- `.scriptExecution` blocker is presented before lower-priority capability blockers;
- regenerating a plan with changed variable text changes the command without re-preparing;
- host preparations remain independent when multiple selected hosts finish out of order.

Preserve and test the existing generation-token rule through a small extracted pure helper if needed: a late result may update state only when the host is still selected and its captured generation equals the current generation. Do not snapshot-test SwiftUI implementation details.

- [ ] **Step 3: Confirm runner RED**

```bash
swift test --package-path Packages/ConnPackages --filter SnippetRunnerBatchTests
```

- [ ] **Step 4: Replace script/interpreter runner APIs with plan APIs**

Change the public entry points to `runSilently(plan:on:)` and `runBatchSilently(plansByHostID:on:)`. Record `plan.auditScript`, call `session.exec(plan.preparedCommand, timeout:)`, and build outcomes from audit script/interpreter. Do not provide a fallback overload that can construct a POSIX invocation without a platform-aware plan.

- [ ] **Step 5: Refactor compatibility state and preparation**

Replace `dockerRuntimeByHostID` with `SnippetHostPreparation` values keyed by host ID. `scheduleCompatibilityCheck` must always call `dependencies.snippetExecutionPlanner`, even when both author platforms and required capabilities are empty. Preserve generation checks so stale async results cannot re-select a removed host.

Map `.ready` to compatible plus stored preparation and `.blocked(report)` to `SnippetCapabilityPresentation`. On deselection clear the preparation and compatibility entry together. The view must not probe Docker or interpret capability implementations.

- [ ] **Step 6: Generate one plan per host from current variables**

At execution time, use each stored preparation plus the latest `snippet.render(values:)` to make one `SnippetExecutionPlan` per selected host. Danger evaluation remains against the rendered user script. If any plan cannot be built, show an error and execute nothing.

For silent mode, pass the host-keyed plan map to `SnippetRunner`. For terminal mode, store `preparedCommand` directly in `TerminalRoute` and pass it unchanged to `TerminalScreen.initialCommand`. Remove `ConnOps` knowledge, Docker probing, bootstrap concatenation, and interpreter invocation from the view.

- [ ] **Step 7: Remove generic POSIX bypasses only after both App paths are migrated**

Remove `ShellInterpreter.invocation(for:)` and `SSHSession.execScript`. Update mock comments/tests so command unwrapping remains a mock implementation detail, not a public execution path. POSIX invocation must now exist only in `POSIXScriptExecutionProvider`.

- [ ] **Step 8: Verify packages, App compilation, and bypass searches before committing**

```bash
swift test --package-path Packages/ConnPackages --filter SnippetRunnerBatchTests
swift test --package-path Packages/ConnPackages --filter ConnRunnerTests
swift test --package-path Packages/ConnPackages --filter ConnSSHTests
swift test --package-path Packages/ConnPackages --filter ConnKitTests
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator'
```

Expected: package tests and App build PASS. Then verify no duplicated execution path remains:

```bash
rg -n "execScript|ShellInterpreter.*invocation|\.invocation\(" Packages/ConnPackages Conn/Conn
rg -n "DockerService\.probe|DockerRuntimeContext|shellBootstrapCommand" Conn/Conn/Commands/SnippetRunView.swift Packages/ConnPackages/Sources/ConnRunner
```

Expected: no generic invocation bypass and no Docker-specific UI/planner knowledge. If a user-booted simulator is available, run focused `ConnTests` on that UDID; never boot one.

- [ ] **Step 9: Commit the atomic migration**

```bash
git add Packages/ConnPackages/Sources/ConnRunner/SnippetRunner.swift Packages/ConnPackages/Tests/ConnRunnerTests/SnippetRunnerBatchTests.swift Packages/ConnPackages/Sources/ConnSSH/SSHTransport.swift Packages/ConnPackages/Sources/ConnKit/Models/ShellInterpreter.swift Packages/ConnPackages/Sources/ConnSSH/Mock/MockSSHTransport.swift Packages/ConnPackages/Tests/ConnSSHTests/MockSSHTransportTests.swift Packages/ConnPackages/Tests/ConnKitTests/SnippetTests.swift Conn/Conn/Commands/SnippetRunView.swift Conn/ConnTests/SnippetCapabilityPresentationTests.swift
git commit -m "refactor: unify snippet readiness and execution"
```

### Task 6: Extend real macOS SSH acceptance coverage

**Files:**
- Modify: `Packages/ConnPackages/Tests/ConnSSHCitadelTests/MacHostIntegrationTests.swift`

- [ ] **Step 1: Add a timeout helper that closes remote resources before returning**

Create a test-local bounded-operation helper whose timeout branch invokes an async cleanup closure before throwing. Cleanup must close the active SFTP filesystem or PTY channel and the dedicated SSH session, so cancellation cannot leave the remote operation/channel alive even if the underlying Citadel await does not immediately observe Swift task cancellation. The normal success/error path also closes the resource; `withSession` performs idempotent final session cleanup.

- [ ] **Step 2: Add gated SFTP acceptance**

Using the existing environment-gated real-host configuration and a fresh `withSession`, open SFTP, resolve `.`, and list the resolved directory inside the bounded helper. Assert the resolved path is non-empty and listing succeeds; do not create, modify, or delete remote files. Close the filesystem on success, ordinary failure, timeout, and cancellation; timeout cleanup must also close the session to unblock an in-flight SFTP operation.

- [ ] **Step 3: Add gated PTY acceptance with deterministic cleanup**

Open an 80x24 shell, write a `printf` sentinel followed by `exit`, and collect output until the sentinel is observed inside the bounded helper. Close the shell on success, ordinary failure, timeout, and cancellation; timeout cleanup also closes the dedicated session.

- [ ] **Step 4: Add gated log-stream transport acceptance**

On another dedicated `withSession`, use `execStream` with a finite macOS `/usr/bin/log show ... | head` command followed by a sentinel. Collect to EOF inside the bounded helper and assert the sentinel. On ordinary failure, cancellation, or timeout, close the dedicated SSH session so the remote channel/process is torn down rather than only cancelling the local consumer. This exercises the streaming SSH path and macOS log CLI without relying on new log arrival.

- [ ] **Step 5: Run the integration suite**

```bash
swift test --package-path Packages/ConnPackages --filter MacHostIntegrationTests
```

Expected without `CONN_MAC_SSH_*`: suite is explicitly skipped. Expected with credentials: existing platform/metrics/process/log/Docker plus new SFTP/PTY/log-stream tests PASS. If credentials are absent, report the skip rather than inventing or requesting secrets.

- [ ] **Step 6: Commit**

```bash
git add Packages/ConnPackages/Tests/ConnSSHCitadelTests/MacHostIntegrationTests.swift
git commit -m "test: extend macOS SSH acceptance coverage"
```

### Task 7: Full regression, architecture audit, and final review

**Files:**
- Modify only files required by failures found in this task.

- [ ] **Step 1: Run the full package suite**

```bash
swift test --package-path Packages/ConnPackages
```

Expected: all unit/integration tests pass; real-host suites may be skipped only by their explicit environment gates.

- [ ] **Step 2: Build the App target**

```bash
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator'
```

Expected: PASS.

- [ ] **Step 3: Run App tests only on the existing user simulator**

First inspect, without changing lifecycle:

```bash
xcrun simctl list devices booted
```

If exactly one user-booted simulator is available, run:

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,id=<BOOTED_UDID>'
```

If CoreSimulatorService/device access is unavailable, stop simulator work and report that App runtime tests were not run. Do not switch destinations or boot another device.

- [ ] **Step 4: Audit architectural invariants**

```bash
rg -n "execScript|ShellInterpreter.*invocation|\.invocation\(" Packages/ConnPackages Conn/Conn
rg -n "DockerService\.probe|DockerRuntimeContext|shellBootstrapCommand" Conn/Conn/Commands/SnippetRunView.swift Packages/ConnPackages/Sources/ConnRunner
rg -n "scriptExecution" Packages/ConnPackages Conn/Conn Conn/ConnTests
git diff --check
git status --short --branch
```

Expected: no generic script bypass; no Docker-specific UI/planner knowledge; `.scriptExecution` is modeled/tested/consumed; no whitespace errors; only intentional changes remain.

- [ ] **Step 5: Request code review and fix confirmed findings**

Use `superpowers:requesting-code-review` against the implementation range. Review specifically for:

- accidental POSIX fallback on Windows/Unknown;
- duplicate Docker probes per preparation;
- capability reports that claim unprobed states;
- prelude leakage into audit/danger evaluation;
- terminal/silent command divergence;
- cross-target dependency inversion;
- retained SSH/SFTP/PTY resources;
- persistence/schema changes.

Apply confirmed fixes with focused regression tests, then rerun Steps 1–4.

- [ ] **Step 6: Final commit if review required fixes**

```bash
git add <only reviewed fix files>
git commit -m "fix: address remote capability review findings"
```

- [ ] **Step 7: Handoff**

Report package/app verification evidence, real-mac test pass or explicit environment skip, simulator limitation if any, commits created, and confirm that no database migration was added.
