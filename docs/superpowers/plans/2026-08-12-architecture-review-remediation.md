# Architecture Review Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the session-consistency, stream-lifecycle, host-binding, POSIX Docker-boundary, and batch-safety gaps found by the architecture review.

**Architecture:** Platform-sensitive operations consume one atomic `RemotePlatformContext`; long-lived log commands own a dedicated SSH session; snippet plans carry a connection identity validated before audit or transport. Docker remains explicitly POSIX for Linux/macOS while registry keys expose the execution family, and batch execution uses a six-task sliding window plus typed danger confirmation.

**Tech Stack:** Swift 5.10, Swift Concurrency, Swift Testing, Swift Package Manager, SwiftUI, Citadel SSH.

---

### Task 1: Enforce atomic platform context

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/MonitorScheduler.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/ProcessMonitor.swift`
- Modify: `Conn/Conn/Hosts/LogCenterView.swift`
- Modify: `Conn/Conn/Hosts/DockerViewModel.swift`
- Modify: `Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift`

- [ ] Remove the split `platformProfile(for:)` API and confirm affected targets fail to compile.
- [ ] Replace every platform-sensitive split lookup with one `platformContext(for:)` lookup.
- [ ] Update connection-manager tests to assert the context rather than a detached profile.
- [ ] Run ConnSSH/ConnMonitor focused tests and a generic App build.

### Task 2: Make log-stream cancellation close the remote command

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`
- Modify: `Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift`
- Modify: `Conn/Conn/Hosts/LogStreamViewModel.swift`
- Create or modify: `Conn/ConnTests/LogStreamViewModelTests.swift`

- [ ] Write failing tests for an unpooled caller-owned session and log stop/late-cancel cleanup.
- [ ] Add `dedicatedSession(for:)`, sharing the exact authentication and jump-chain connection path without inserting into the pool.
- [ ] Make the log ViewModel close its owned session on stop, cancellation, error, and EOF.
- [ ] Run focused package/App tests.

### Task 3: Bind snippet plans to the SSH connection identity

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`
- Modify: `Packages/ConnPackages/Sources/ConnRunner/SnippetExecutionPlanner.swift`
- Modify: `Packages/ConnPackages/Sources/ConnRunner/SnippetRunner.swift`
- Modify: `Conn/Conn/Commands/SnippetExecutionRequestBuilder.swift`
- Modify: `Packages/ConnPackages/Tests/ConnRunnerTests/SnippetExecutionPlannerTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnRunnerTests/SnippetRunnerBatchTests.swift`
- Modify: `Conn/ConnTests/SnippetExecutionRequestBuilderTests.swift`

- [ ] Write failing wrong-host and changed-connection tests proving no audit and no SSH command occurs.
- [ ] Add a reusable, non-secret `SSHConnectionIdentity` matching the pool-key fields.
- [ ] Carry identity through preparation and execution plan.
- [ ] Validate identity in the request builder and runner before routing/audit.
- [ ] Run ConnRunner and App focused tests.

### Task 4: Make Docker's POSIX scope explicit and remove blind fallbacks

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerEnvironmentProvider.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerRuntimeContext.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerService.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerService+Runtime.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/LogSource.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/MetricCollector.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/ProcessCollector.swift`
- Modify tests in `Packages/ConnPackages/Tests/ConnOpsTests` and `ConnMonitorTests`

- [ ] Write failing tests for platform+family registry selection and removal of implicit runtime/profile defaults.
- [ ] Add explicit `.posix` family metadata to Docker providers/runtime and key the registry by platform+family.
- [ ] Require discovered Docker runtime in log-source construction.
- [ ] Remove all public `DockerService(... sudo:)` overloads that can execute PATH-based Docker without a discovered runtime, and migrate their tests to runtime-based calls.
- [ ] Add an API-boundary check proving external/production callers cannot invoke Docker operations without a runtime.
- [ ] Remove default Linux profile and legacy process collector overload.
- [ ] Run ConnOps/ConnMonitor test suites.

### Task 5: Enforce batch safety

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnRunner/SnippetRunner.swift`
- Modify: `Packages/ConnPackages/Tests/ConnRunnerTests/SnippetRunnerBatchTests.swift`
- Modify: `Conn/Conn/Commands/SnippetRunView.swift`
- Create: `Conn/Conn/Commands/SnippetDangerConfirmationPolicy.swift`
- Create: `Conn/ConnTests/SnippetDangerConfirmationPolicyTests.swift`

- [ ] Write a failing peak-concurrency test expecting at most six active executions.
- [ ] Implement a six-task sliding window while preserving sorted isolated results.
- [ ] Write failing policy tests requiring exact `RUN` only for dangerous multi-host execution.
- [ ] Add typed batch confirmation and retain the existing single-host dialog.
- [ ] Run focused tests and generic App build.

### Task 6: Full verification

- [ ] Run `swift test --package-path Packages/ConnPackages`.
- [ ] Run `xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator'`.
- [ ] If and only if a user-booted simulator exists, run affected ConnTests against that UDID.
- [ ] Run `git diff --check` and inspect the final diff for persistence changes.
