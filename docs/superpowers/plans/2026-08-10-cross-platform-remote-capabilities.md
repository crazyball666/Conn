# Cross-Platform Remote Capabilities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Linux-only remote command assumptions with platform profiles and feature-local providers, preserving Linux behavior while fully supporting macOS metrics, processes, logs, built-in commands, and Docker discovery; Windows receives explicit extension points and unsupported states.

**Architecture:** `ConnKit` owns platform/capability values, `ConnSSH` owns profile detection and per-session cache, and each feature module owns narrow provider protocols plus Linux/Darwin implementations. Dynamic availability remains outside the cached profile. Existing normalized models remain the UI boundary.

**Tech Stack:** Swift 5.10, Swift Concurrency, Swift Testing, GRDB 7, SSH through `ConnSSH`, iOS 17/macOS 15 package targets.

---

## Scope and execution order

The feature spans several modules but has one dependency chain. Execute in this order so every commit compiles and keeps all package tests green:

1. Platform values and detector/cache.
2. Metrics and process providers.
3. Log providers.
4. Docker runtime context.
5. Built-in snippet metadata and persistence.
6. App/UI integration and end-to-end verification.

Do not start a later task while an earlier task has failing tests. The user explicitly authorized implementation on `main`; do not create a worktree or switch branches.

### Task 1: Add platform and capability domain values

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnKit/Models/RemotePlatform.swift`
- Create: `Packages/ConnPackages/Tests/ConnKitTests/RemotePlatformTests.swift`

- [ ] **Step 1: Write failing domain tests**

Add Swift Testing coverage for Linux/macOS/Windows/Unknown raw values, Codable round trips, stable reason codes, field-level degraded issues, and the convenience lookup on `RemoteCapabilityReport`.

```swift
@Test("平台画像可编码并保留能力字段")
func profileRoundTrip() throws {
    let profile = RemotePlatformProfile(
        kind: .macOS, release: "15.0", architecture: "arm64", shell: .zsh
    )
    let data = try JSONEncoder().encode(profile)
    #expect(try JSONDecoder().decode(RemotePlatformProfile.self, from: data) == profile)
}

@Test("降级原因保留缺失字段")
func degradedFields() {
    let issue = CapabilityIssue(code: .partialData, fields: ["tcp", "io"])
    let report = RemoteCapabilityReport(states: [.hostMetrics: .degraded(issues: [issue])])
    #expect(report[.hostMetrics] == .degraded(issues: [issue]))
}
```

- [ ] **Step 2: Run the tests and confirm RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter RemotePlatformTests
```

Expected: compile failure because the platform types do not exist.

- [ ] **Step 3: Implement the minimal values**

Implement `RemotePlatformKind`, `RemoteCapability`, `CapabilityReasonCode`, `CapabilityIssue`, `CapabilityState`, `RemotePlatformProfile`, and `RemoteCapabilityReport`. Provide defaults for optional detail/fields and an `observedAt` default so call sites remain concise. Keep all types public, Codable, Sendable, Equatable; use Hashable only where needed.

- [ ] **Step 4: Run focused and module tests**

```bash
swift test --package-path Packages/ConnPackages --filter RemotePlatformTests
swift test --package-path Packages/ConnPackages --filter ConnKitTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnKit/Models/RemotePlatform.swift Packages/ConnPackages/Tests/ConnKitTests/RemotePlatformTests.swift
git commit -m "feat: add remote platform capability model"
```

### Task 2: Detect and cache the remote platform

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnSSH/RemotePlatformDetector.swift`
- Modify: `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`
- Create: `Packages/ConnPackages/Tests/ConnSSHTests/RemotePlatformDetectorTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift`

- [ ] **Step 1: Write failing detector tests**

Use a fixture `SSHSession` to return sentinel output. Cover:

```swift
@Test("Darwin 签名识别为 macOS")
func detectsDarwin() throws {
    let profile = try RemotePlatformDetector.parse("""
    __CONN_UNAME__
    Darwin
    __CONN_RELEASE__
    24.6.0
    __CONN_ARCH__
    arm64
    __CONN_SHELL__
    /bin/zsh
    __CONN_END__
    """)
    #expect(profile.kind == .macOS)
    #expect(profile.shell == .zsh)
}

@Test("成功但未知的签名不回退 Linux")
func unknownStaysUnknown() throws {
    #expect(try RemotePlatformDetector.parse("__CONN_UNAME__\nPlan9\n__CONN_END__").kind == .unknown)
}
```

Also cover Linux, Windows signature parsing, transport errors, one probe for two `platformProfile(for:)` calls, and cache clearing through `invalidate(host:)`/`invalidateAll()`.

- [ ] **Step 2: Confirm RED**

```bash
swift test --package-path Packages/ConnPackages --filter RemotePlatformDetectorTests
```

Expected: compile failure because detector/cache APIs are missing.

- [ ] **Step 3: Implement detector and cache**

Add:

```swift
public protocol RemotePlatformDetecting: Sendable {
    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile
}

public struct RemotePlatformDetector: RemotePlatformDetecting {
    public static let command: String
    public func detect(on session: any SSHSession) async throws -> RemotePlatformProfile
    static func parse(_ output: String) -> RemotePlatformProfile
}
```

The command must be read-only and use sentinels. A nonzero SSH/exec result throws a new `SSHError` or a detector-specific `LocalizedError`; recognized command output can still produce `.unknown`. Add a detector dependency and `[PoolKey: RemotePlatformProfile]` cache to `ConnectionManager`. `platformProfile(for:)` must share the pooled session and cache only successful profiles. Clear the cache in every entry removal path.

- [ ] **Step 4: Verify focused and SSH tests**

```bash
swift test --package-path Packages/ConnPackages --filter RemotePlatformDetectorTests
swift test --package-path Packages/ConnPackages --filter ConnectionManagerTests
swift test --package-path Packages/ConnPackages --filter ConnSSHTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnSSH/RemotePlatformDetector.swift Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift Packages/ConnPackages/Tests/ConnSSHTests
git commit -m "feat: detect and cache remote platforms"
```

### Task 3: Introduce metric providers and add Darwin metrics

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnMonitor/MetricsProvider.swift`
- Create: `Packages/ConnPackages/Sources/ConnMonitor/DarwinCollectionScript.swift`
- Create: `Packages/ConnPackages/Sources/ConnMonitor/DarwinMetricParser.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/CollectionScript.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/MetricParser.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/MetricCollector.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/MonitorScheduler.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/HostMetrics.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/HealthEvaluator.swift`
- Create: `Packages/ConnPackages/Tests/ConnMonitorTests/MetricsProviderTests.swift`
- Create: `Packages/ConnPackages/Tests/ConnMonitorTests/DarwinMetricParserTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMonitorTests/MetricParserTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMonitorTests/MonitorSchedulerTests.swift`

- [ ] **Step 1: Write failing provider-selection tests**

Assert Linux selects a provider whose command still contains `/proc/stat`, macOS selects a command containing `kern.cp_time`/`vm_stat` and no `/proc`, and Windows/Unknown returns `.unsupported(.unsupportedPlatform)` without executing a Linux command.

- [ ] **Step 2: Confirm RED for provider selection**

```bash
swift test --package-path Packages/ConnPackages --filter MetricsProviderTests
```

Expected: compile failure because provider types do not exist.

- [ ] **Step 3: Add protocol, registry, and Linux wrapper**

Implement:

```swift
protocol MetricsProvider: Sendable {
    var platform: RemotePlatformKind { get }
    func command(includeExtended: Bool) -> String
    func parse(_ output: String) -> ParsedMetrics
}

enum MetricsProviderRegistry {
    static func provider(for platform: RemotePlatformKind) -> (any MetricsProvider)?
}
```

`LinuxMetricsProvider` delegates to existing `CollectionScript`/`MetricParser`. Do not change Linux fixture output or parser semantics.

- [ ] **Step 4: Run provider tests GREEN**

```bash
swift test --package-path Packages/ConnPackages --filter MetricsProviderTests
swift test --package-path Packages/ConnPackages --filter MetricParserTests
```

- [ ] **Step 5: Write failing Darwin fixture tests**

Create a complete sentinel fixture with `kern.cp_time`, `kern.cp_times`, `hw.logicalcpu`, `hw.memsize`, `vm_stat`, swap, load, `df`, `netstat -ib`, `ifconfig`, `iostat`, `kern.boottime`, `sw_vers`, and CPU model. Assert normalized `ParsedMetrics` values, including cumulative CPU ticks, memory percentages, IPs, interface byte totals, uptime and partial-data fields.

- [ ] **Step 6: Confirm Darwin parser RED**

```bash
swift test --package-path Packages/ConnPackages --filter DarwinMetricParserTests
```

Expected: compile failure or missing parsed values.

- [ ] **Step 7: Implement Darwin command and parser**

Use one sentinel-delimited exec. Parse CPU ticks from `sysctl -n kern.cp_time` into `CPUJiffies`/`CPUTimes`; parse per-core ticks from `kern.cp_times`; derive memory from `hw.memsize` and `vm_stat` page counts; parse `vm.swapusage`, BSD load tuple, POSIX `df`, `netstat -ib`, `ifconfig`, `iostat`, boot epoch and `sw_vers`. Treat unsupported TCP/IO subfields as nil and emit `.degraded` issues rather than fabricated counters.

- [ ] **Step 8: Thread profile/report through collector and scheduler**

`MetricCollector.collect` receives a `RemotePlatformProfile`, selects a provider, and adds the profile plus a host-metrics capability state to `HostMetrics`. `MonitorScheduler.attempt` obtains the profile through `ConnectionManager` before collecting. Unsupported platforms produce a user-facing capability error without executing Linux commands. Update health evaluation so `.ok` requires all three core health inputs (CPU, memory, disk); partial core values produce `.unknown` while retaining individual values.

- [ ] **Step 9: Fix zero-filled trend samples**

Modify `HostOverviewViewModel` to append only real metric values or represent missing history as optional samples. Add/adjust app tests so unsupported data is not plotted as zero.

- [ ] **Step 10: Verify monitor and app-focused tests**

```bash
swift test --package-path Packages/ConnPackages --filter ConnMonitorTests
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator'
```

Expected: package tests PASS and app target builds. Runtime app tests are deferred to Task 8 and may use only the already-booted user simulator.

- [ ] **Step 11: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnMonitor Packages/ConnPackages/Tests/ConnMonitorTests Conn/Conn/Hosts/HostOverviewViewModel.swift Conn/ConnTests
git commit -m "feat: add Linux and Darwin metric providers"
```

### Task 4: Add platform process providers

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnMonitor/ProcessProvider.swift`
- Create: `Packages/ConnPackages/Sources/ConnMonitor/DarwinProcessProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/ProcessCollector.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/ProcessMonitor.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/ProcessParser.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMonitorTests/ProcessCollectorTests.swift`
- Create: `Packages/ConnPackages/Tests/ConnMonitorTests/DarwinProcessProviderTests.swift`
- Modify: `Conn/Conn/Hosts/ProcessListViewModel.swift`
- Modify: `Conn/Conn/Hosts/ProcessListView.swift`
- Modify: `Conn/ConnTests/ProcessListFailureStateTests.swift`

- [ ] **Step 1: Write failing Darwin process tests**

Use a fixture with fixed-width whitespace columns followed by a full command. Verify PID/PPID/user/CPU/memory/RSS/state/elapsed mapping, Swift-side CPU sorting, bad-line skipping, and `threads == nil`. Assert the Darwin command contains no `--sort`, `nlwp`, or `top -bn1`.

- [ ] **Step 2: Confirm RED**

```bash
swift test --package-path Packages/ConnPackages --filter DarwinProcessProviderTests
```

- [ ] **Step 3: Implement provider registry and Darwin parser**

Wrap existing GNU/BusyBox logic in `LinuxProcessProvider`. Implement `DarwinProcessProvider` with supported BSD `ps -axo` fields and sort parsed results in Swift. `ProcessCollector.collect` accepts the profile. `ProcessMonitor` gets the cached profile before collecting and exposes a `CapabilityState?` so unsupported is not shown as an empty successful list.

- [ ] **Step 4: Verify process tests**

```bash
swift test --package-path Packages/ConnPackages --filter ProcessCollectorTests
swift test --package-path Packages/ConnPackages --filter DarwinProcessProviderTests
swift test --package-path Packages/ConnPackages --filter ConnMonitorTests
```

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnMonitor Packages/ConnPackages/Tests/ConnMonitorTests Conn/Conn/Hosts/ProcessListView.swift Conn/Conn/Hosts/ProcessListViewModel.swift Conn/ConnTests/ProcessListFailureStateTests.swift
git commit -m "feat: add platform process providers"
```

### Task 5: Add Linux and Darwin log providers

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnOps/LogProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/LogSource.swift`
- Modify: `Packages/ConnPackages/Tests/ConnOpsTests/LogTests.swift`
- Modify: `Conn/Conn/Hosts/LogCenterView.swift`
- Modify: `Conn/Conn/Hosts/LogStreamViewModel.swift`

- [ ] **Step 1: Write failing log-provider tests**

Cover Linux journal/file behavior unchanged. For macOS, assert discovery probes `/usr/bin/log` and `/var/log/system.log`, parses Unified Logging separately from files, and builds:

```swift
log stream --style syslog
```

for follow mode. Assert Unknown/Windows returns unsupported without Linux discovery.

- [ ] **Step 2: Confirm RED**

```bash
swift test --package-path Packages/ConnPackages --filter LogTests
```

- [ ] **Step 3: Implement providers and unified log kind**

Add feature-local registry, keep current presets in `LinuxLogProvider`, add `DarwinLogProvider`, and add `.unified(predicate: String?)` to `LogSource.Kind`. Generate safe fixed `log stream`/`log show` commands. Update exhaustive UI switches and `LogCenterViewModel` to select by cached profile.

- [ ] **Step 4: Verify log tests**

```bash
swift test --package-path Packages/ConnPackages --filter ConnOpsTests
```

- [ ] **Step 5: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnOps Packages/ConnPackages/Tests/ConnOpsTests Conn/Conn/Hosts/LogCenterView.swift Conn/Conn/Hosts/LogStreamViewModel.swift
git commit -m "feat: add platform log providers"
```

### Task 6: Propagate Docker runtime context

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnOps/DockerRuntimeContext.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerCommand.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerService.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/LogSource.swift`
- Modify: all `Packages/ConnPackages/Sources/ConnOps/DockerService+*.swift` command call sites
- Modify: `Packages/ConnPackages/Tests/ConnOpsTests/DockerOperationCommandTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnOpsTests/DockerServiceResourceTests.swift`
- Modify: `Conn/Conn/Hosts/DockerContext.swift`
- Modify: `Conn/Conn/Hosts/DockerViewModel.swift`
- Modify: `Conn/Conn/Hosts/DockerView.swift`
- Modify: Docker feature model files under `Conn/Conn/Hosts/`
- Modify: matching `Conn/ConnTests/Docker*Tests.swift`

- [ ] **Step 1: Write failing path-propagation tests**

Assert a context with executable `/usr/local/bin/docker` produces that exact prefix for list, stats, inspect, Compose and container logs. Assert `sudo -n` is applied before the quoted executable. Add probe fixtures for direct path, macOS Docker Desktop not running, permission denied and CLI missing.

- [ ] **Step 2: Confirm RED**

```bash
swift test --package-path Packages/ConnPackages --filter DockerOperationCommandTests
```

- [ ] **Step 3: Implement runtime context and command API**

Use a value such as:

```swift
public struct DockerRuntimeContext: Sendable, Equatable {
    public let executable: String
    public let sudo: Bool
}

public struct DockerProbeResult: Sendable, Equatable {
    public let availability: DockerAvailability
    public let runtime: DockerRuntimeContext?
}
```

Every Docker command builder and service operation receives this runtime. Quote discovered executable paths. The probe uses `command -v docker` plus known non-interactive macOS locations and returns the same path used later. Keep convenience overloads using `.default` only where needed for source compatibility; new app paths must not use them.

- [ ] **Step 4: Thread context through app models and logs**

Replace `DockerContext.sudo` with runtime context, update all resource models, Compose and log source creation. Make unavailable guidance platform-aware: Linux may suggest `systemctl`; macOS suggests starting Docker Desktop; Unknown gives neutral guidance.

- [ ] **Step 5: Verify Docker tests**

```bash
swift test --package-path Packages/ConnPackages --filter ConnOpsTests
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator'
```

- [ ] **Step 6: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnOps Packages/ConnPackages/Tests/ConnOpsTests Conn/Conn/Hosts Conn/ConnTests
git commit -m "feat: propagate Docker runtime context"
```

### Task 7: Make built-in snippets platform-aware and migrate storage

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/Snippet.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Repositories/SnippetRepository.swift`
- Create: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV2.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/Records/SnippetRecord.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/DAO/SnippetStore.swift`
- Modify: `Packages/ConnPackages/Sources/ConnRunner/BuiltinSnippets.swift`
- Modify: `Packages/ConnPackages/Sources/ConnRunner/Resources/builtin-snippets.json`
- Create: `Packages/ConnPackages/Tests/ConnStoreTests/SchemaV2Tests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnStoreTests/SnippetStoreTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnRunnerTests/BuiltinSnippetsTests.swift`
- Modify: `Conn/Conn/ConnApp.swift`
- Modify: `Conn/Conn/Settings/SettingsStore.swift`
- Modify: `Conn/Conn/Commands/SnippetsViewModel.swift`
- Modify: matching `Conn/ConnTests/SnippetsViewModelTests.swift`

- [ ] **Step 1: Write failing snippet model/catalog tests**

Assert legacy `Snippet` defaults to all platforms and has `builtinKey == nil`; JSON entries have stable keys/platforms; Linux and macOS catalogs contain compatible system/CPU/memory/ports/log commands; Docker entries require Docker capability.

- [ ] **Step 2: Confirm RED**

```bash
swift test --package-path Packages/ConnPackages --filter BuiltinSnippetsTests
```

- [ ] **Step 3: Implement model and catalog metadata**

Add `platforms`, `requiredCapabilities`, and optional `builtinKey` to `Snippet` with backward-compatible Codable defaults. Add stable IDs/platform tags to JSON and macOS equivalents. Keep user snippets universal by default.

- [ ] **Step 4: Write failing schema/migration tests**

Build a v1 queue, insert a legacy snippet, run v2, and verify defaults. Add tests for unique stable key, catalog version and suppression/tombstone. Verify deleting a built-in records suppression and a later import does not recreate it; editing a built-in is not overwritten.

- [ ] **Step 5: Confirm migration RED**

```bash
swift test --package-path Packages/ConnPackages --filter SchemaV2Tests
```

- [ ] **Step 6: Implement schema v2 and idempotent import**

Add nullable `platforms_json`, `required_capabilities_json`, `builtin_key`; create catalog-state/suppression storage keyed by stable builtin key; register `SchemaV2` after v1. Replace the one-time bool with a catalog version while preserving the old flag as migration input. Import only missing, unsuppressed stable keys and never overwrite existing records.

- [ ] **Step 7: Filter/annotate snippets by selected host profile**

Expose compatibility evaluation in `ConnRunner` or `ConnKit`; update command run/list UI only where a target host is known. Do not hide user-authored universal snippets.

- [ ] **Step 8: Verify runner/store/app tests**

```bash
swift test --package-path Packages/ConnPackages --filter ConnRunnerTests
swift test --package-path Packages/ConnPackages --filter ConnStoreTests
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator'
```

- [ ] **Step 9: Commit**

```bash
git add Packages/ConnPackages/Sources/ConnKit Packages/ConnPackages/Sources/ConnStore Packages/ConnPackages/Sources/ConnRunner Packages/ConnPackages/Tests Conn/Conn/ConnApp.swift Conn/Conn/Settings/SettingsStore.swift Conn/Conn/Commands Conn/ConnTests/SnippetsViewModelTests.swift
git commit -m "feat: add platform-aware built-in snippets"
```

### Task 8: Final UI states, integration coverage, and verification

**Files:**
- Modify: `Packages/ConnPackages/Tests/ConnSSHCitadelTests/CitadelIntegrationTests.swift`
- Create: `Packages/ConnPackages/Tests/ConnSSHCitadelTests/MacHostIntegrationTests.swift`
- Modify: `Spikes/S1-ssh-matrix/README.md`
- Modify: `Conn/Conn/Localization/AppLocalization.swift` and `Conn/Conn/Localizable.xcstrings` only for new user-facing strings
- Modify: affected host views/tests found by `rg "CapabilityState|MetricSeverity|DockerAvailability|LogSource.Kind"`

- [ ] **Step 1: Add failing UI-state tests**

Verify capability reasons map to stable UI states: unsupported, partial metrics, missing command, permission denied and daemon stopped. Ensure partial metrics never render health as green and process/log unsupported states never render as empty success.

- [ ] **Step 2: Confirm RED and implement minimal mappings**

Run the affected app tests, add only the necessary mappings and localized strings, then rerun until green.

- [ ] **Step 3: Add opt-in real macOS SSH integration tests**

Gate on `CONN_MAC_SSH_HOST` and existing auth environment variables. Test profile detection, two metric samples, process list, log discovery and Docker probe. Use `#expect`/skip semantics that clearly report skipped when no host is configured. Do not use or manage iOS simulators.

If the host or any required authentication environment variable is absent, skip the integration suite with one explicit reason; never convert missing configuration into a passing assertion.

- [ ] **Step 4: Run the full Swift package suite**

```bash
swift test --package-path Packages/ConnPackages
```

Expected: all non-integration tests PASS; macOS integration tests explicitly PASS when environment is configured or SKIP otherwise.

- [ ] **Step 5: Build the application**

```bash
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator'
```

Expected: `BUILD SUCCEEDED`. This compiles against a generic destination and does not create/start/stop a simulator.

- [ ] **Step 6: Simulator acceptance only if a simulator is already booted**

Read the current booted UDID. If exactly one user-started device is available, run targeted UI/unit acceptance using only that UDID. If CoreSimulatorService or that device is unavailable, stop simulator operations and report. Never clone, boot, reboot, shut down or switch devices.

- [ ] **Step 7: Request code review**

Use `superpowers:requesting-code-review` with the design, this plan, base commit and current HEAD. Fix all Critical/Important findings and rerun affected tests.

- [ ] **Step 8: Fresh final verification**

Run again after review fixes:

```bash
git diff --check
swift test --package-path Packages/ConnPackages
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator'
git status --short --branch
```

- [ ] **Step 9: Commit final integration fixes**

```bash
git add Packages/ConnPackages Conn docs
git commit -m "feat: support Linux and macOS remote capabilities"
```

Do not push or create a pull request unless the user asks.
