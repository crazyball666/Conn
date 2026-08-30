# Conn Subscription Monetization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local StoreKit 2 auto-renewable Conn Pro subscription with ¥18 monthly and ¥98 yearly pricing, while keeping the confirmed free and Pro boundaries in the current App.

**Architecture:** Add a platform-neutral `ConnEntitlement` package target for gates and host-limit policy, then keep StoreKit 2 integration and Paywall UI in the App target. Inject one entitlement service through `AppDependencies`; feature views call that service at their existing entry points and never access StoreKit directly.

**Tech Stack:** Swift 5.10, SwiftUI, StoreKit 2, Swift Package Manager, Swift Testing, XCTest/XCUITest, existing `L()` localization helper.

**Spec:** `docs/superpowers/specs/2026-08-31-conn-subscription-monetization-design.md`

---

## Current File Map

- Modify: `Packages/ConnPackages/Package.swift` — add the `ConnEntitlement` library and test target.
- Create: `Packages/ConnPackages/Sources/ConnEntitlement/EntitlementGate.swift` — pure gate names, snapshot, provider protocol, and host-limit policy.
- Create: `Packages/ConnPackages/Tests/ConnEntitlementTests/EntitlementGateTests.swift` — test free/Pro gates and two-host boundary.
- Modify: `Conn/Conn/ConnApp.swift` — inject the entitlement service into `AppDependencies`, construct production/demo providers, and keep demo launch seams deterministic.
- Create: `Conn/Conn/Monetization/StoreKitSubscriptionStore.swift` — StoreKit 2 product loading, verified transaction handling, transaction listener, purchase, restore, and observable state.
- Create: `Conn/Conn/Monetization/PaywallView.swift` — one localized Pro page with monthly/yearly products and feature context.
- Create: `Conn/Conn/Monetization/SubscriptionEnvironment.swift` — production and UI-test/demo dependency factories; no hard-coded Pro bypass in production.
- Create: `Conn/ConnTests/SubscriptionStoreTests.swift` — app-target tests for the injectable StoreKit seam and transaction state transitions.
- Modify: `Conn/Conn/Me/MeView.swift` — add the Pro entry card and subscription management/restore access.
- Modify: `Conn/Conn/Servers/ServersView.swift` — enforce the two-host create boundary while preserving form drafts.
- Modify: `Conn/Conn/Hosts/HostDetailView.swift` — gate only the Files and Docker destinations before their remote loading starts.
- Modify: `Conn/Conn/Commands/SnippetRunView.swift` — gate multi-host silent execution; keep one-host execution unchanged.
- Modify: `Conn/Conn/Localizable.xcstrings` — add all new UI strings in five languages and keep format placeholders consistent.
- Modify: `Conn/ConnTests/RemoteFileIntegrityTests.swift` and `Conn/ConnTests/DockerModelsTests.swift` — supply the new entitlement dependency in their existing `AppDependencies` fixtures.
- Create: `Conn/ConnTests/SubscriptionBoundaryTests.swift` — app-level tests for host creation and route/execution seams.
- Modify/Create: `Conn/ConnUITests/*` — end-to-end tests for free paywall paths, free paths, and Pro test mode.
- Modify: `Conn/Conn.xcodeproj/project.pbxproj` — link the new package product if Xcode does not update the package product dependency automatically.

### Task 1: Define the pure entitlement contract and host quota

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnEntitlement/EntitlementGate.swift`
- Create: `Packages/ConnPackages/Tests/ConnEntitlementTests/EntitlementGateTests.swift`
- Modify: `Packages/ConnPackages/Package.swift`

- [ ] **Step 1: Add the failing tests for the confirmed rules.**

Cover these exact cases in Swift Testing:

```swift
@Test func freeUserCanAddOnlyTwoHosts() {
    let gate = EntitlementGate(snapshot: .free)
    #expect(gate.canAddHost(currentCount: 0))
    #expect(gate.canAddHost(currentCount: 1))
    #expect(!gate.canAddHost(currentCount: 2))
}

@Test func freeAndProFeatureBoundariesMatchProductDecision() {
    let free = EntitlementGate(snapshot: .free)
    let pro = EntitlementGate(snapshot: .pro)
    #expect(free.allowed(.terminal))
    #expect(free.allowed(.processControl))
    #expect(free.allowed(.logCenter))
    #expect(free.allowed(.singleHostExecution))
    #expect(!free.allowed(.fileManagement))
    #expect(!free.allowed(.dockerManagement))
    #expect(!free.allowed(.batchExecution))
    #expect(pro.allowed(.fileManagement))
    #expect(pro.allowed(.dockerManagement))
    #expect(pro.allowed(.batchExecution))
}
```

- [ ] **Step 2: Run the package test target and verify the new tests fail because the target/types do not exist.**

Run: `swift test --package-path Packages/ConnPackages --filter ConnEntitlementTests`

Expected: FAIL because `ConnEntitlement` has not been added yet.

- [ ] **Step 3: Add the minimal package target and pure implementation.**

Define a small `Gate` enum (`terminal`, `processControl`, `logCenter`, `singleHostExecution`, `fileManagement`, `dockerManagement`, `batchExecution`), an `EntitlementSnapshot` (`free`/`pro`), and an `EntitlementGate` value type. Keep the free host limit as a single constant (`2`) and make all decisions deterministic and Foundation-free where practical.

- [ ] **Step 4: Run the package tests and verify they pass.**

Run: `swift test --package-path Packages/ConnPackages --filter ConnEntitlementTests`

Expected: PASS.

- [ ] **Step 5: Commit the pure entitlement contract.**

Run: `git add Packages/ConnPackages/Package.swift Packages/ConnPackages/Sources/ConnEntitlement Packages/ConnPackages/Tests/ConnEntitlementTests && git commit -m "feat: add Conn subscription entitlement gates"`

## Task 2: Add StoreKit 2 subscription state and dependency injection

**Files:**
- Create: `Conn/Conn/Monetization/StoreKitSubscriptionStore.swift`
- Create: `Conn/Conn/Monetization/SubscriptionEnvironment.swift`
- Modify: `Conn/Conn/ConnApp.swift`
- Modify: `Conn/Conn.xcodeproj/project.pbxproj` if required by package linkage

- [ ] **Step 1: Add tests against an injectable subscription provider.**

Add app-level tests for: initial free state, verified monthly transaction becoming Pro, verified yearly transaction becoming Pro, unverified transaction being ignored, restore invoking a refresh, and a failed purchase returning a localized-safe error state without granting Pro.

- [ ] **Step 2: Run the focused app tests and verify the provider tests fail.**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,id=<CURRENT_UDID>' -only-testing:ConnTests/SubscriptionStoreTests -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`

Expected: FAIL until the subscription store and fake provider exist.

- [ ] **Step 3: Implement product and transaction handling.**

Use `Product.products(for:)` for `com.crazyball.conn.pro.monthly` and `com.crazyball.conn.pro.yearly`. Verify `VerificationResult` before granting Pro. Refresh from `Transaction.currentEntitlements`, listen to `Transaction.updates`, and finish verified transactions. Keep the current state in an `@MainActor` observable store and expose `purchase(product:)`, `restore()`, `refresh()`, `isPro`, and the loaded products.

Do not add a server, receipt endpoint, analytics event, or indefinite Keychain entitlement cache. On an unknown/loading state, fail closed for Pro operations.

- [ ] **Step 4: Inject the store once through `AppDependencies`.**

Add an entitlement field to `AppDependencies`. Production uses the StoreKit-backed store. DEBUG demo/UI-test launches use a deterministic fake selected by an explicit launch environment such as `CONN_SUBSCRIPTION_STATE=free|pro|loading|error`; the production build must not honor that bypass.

- [ ] **Step 5: Run focused tests and the app build.**

Run the focused test command from Step 2, then:

`xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,id=<CURRENT_UDID>' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`

Expected: PASS and a successful app build.

- [ ] **Step 6: Commit the StoreKit seam and injection.**

Run: `git add Conn/Conn/Monetization Conn/Conn/ConnApp.swift Conn/Conn.xcodeproj/project.pbxproj && git commit -m "feat: add StoreKit subscription state"`

## Task 3: Build the localized Paywall and Pro entry point

**Files:**
- Create: `Conn/Conn/Monetization/PaywallView.swift`
- Modify: `Conn/Conn/Me/MeView.swift`
- Modify: `Conn/Conn/Localizable.xcstrings`

- [ ] **Step 1: Add view-model/UI tests for product ordering and price presentation.**

Verify yearly is the default selection, monthly and yearly use StoreKit product display prices, loading and purchase errors are rendered without crashes, restore is available, and the feature-context title can be supplied by the triggering feature.

- [ ] **Step 2: Implement the Paywall view.**

Use the existing ConnUI surface/button conventions. The view accepts the entitlement store and an optional context (`thirdHost`, `fileManagement`, `dockerManagement`, `batchExecution`). It must not contain raw StoreKit product IDs or make its own entitlement decisions.

- [ ] **Step 3: Add the `我的` Pro card.**

Show current Pro status or a compact “升级 Conn Pro” card. Tapping opens the same Paywall. Add restore and subscription-management actions through the store; do not create a second purchase path.

- [ ] **Step 4: Add five-language localization.**

Every new visible string must call `L()`. Add `zh-Hans`, `zh-Hant`, `en`, `ja`, and `ko` values for titles, benefit labels, purchase states, restore states, errors, and context messages. Keep `%@`, `%d`, and price placeholders identical across languages.

- [ ] **Step 5: Run localization coverage tests and UI build.**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,id=<CURRENT_UDID>' -only-testing:ConnTests/LocalizationCoverageTests -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`

Expected: PASS with no missing language or placeholder failures.

- [ ] **Step 6: Commit the Paywall UI.**

Run: `git add Conn/Conn/Monetization Conn/Conn/Me/MeView.swift Conn/Conn/Localizable.xcstrings && git commit -m "feat: add localized Conn Pro paywall"`

## Task 4: Gate the four confirmed Pro entry paths

**Files:**
- Modify: `Conn/Conn/Servers/ServersView.swift`
- Modify: `Conn/Conn/Hosts/HostDetailView.swift`
- Modify: `Conn/Conn/Commands/SnippetRunView.swift`
- Create/Modify: `Conn/ConnTests/SubscriptionBoundaryTests.swift`

- [ ] **Step 1: Add failing boundary tests.**

Test that a free user with two hosts cannot create a third, a free user can still delete/edit existing hosts, file and Docker route attempts return a Paywall request before loading, multi-host silent execution returns a Paywall request, and single-host execution proceeds.

- [ ] **Step 2: Implement the host quota gate.**

Before presenting `HostFormView` for a new host, or before saving a newly created draft, call `canAddHost(currentCount:)`. On denial, present Paywall and preserve the draft. Editing an existing host must skip the quota gate.

- [ ] **Step 3: Implement Files and Docker route gates.**

In `HostDetailView`, gate `.files` and `.docker` at the same action boundary that currently sets `route`. Do not initialize or start the relevant remote loading task before the gate passes. Leave `.processes` and `.logs` untouched.

- [ ] **Step 4: Implement the batch execution gate.**

In `SnippetRunView`, keep the host picker and single-host path unchanged. When the silent execution action would run against more than one selected host, present the Paywall and return without creating an execution request or opening an SSH session.

- [ ] **Step 5: Run focused tests.**

Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,id=<CURRENT_UDID>' -only-testing:ConnTests/SubscriptionBoundaryTests -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`

Expected: PASS.

- [ ] **Step 6: Commit the feature gates.**

Run: `git add Conn/Conn/Servers/ServersView.swift Conn/Conn/Hosts/HostDetailView.swift Conn/Conn/Commands/SnippetRunView.swift Conn/ConnTests/SubscriptionBoundaryTests.swift && git commit -m "feat: gate Conn Pro operations"`

## Task 5: Add end-to-end UI coverage and verify on the current simulator

**Files:**
- Create: `Conn/ConnUITests/SubscriptionPaywallUITests.swift`
- Modify: existing UI test helpers only if needed for demo launch configuration

- [ ] **Step 1: Add UI tests for the free state.**

Launch with the demo data and `CONN_SUBSCRIPTION_STATE=free`. Verify the `我的` Pro card opens Paywall, the third-host flow opens Paywall, Files and Docker open Paywall, batch execution opens Paywall, and process/log pages remain usable.

- [ ] **Step 2: Add UI tests for the Pro state.**

Launch with `CONN_SUBSCRIPTION_STATE=pro`. Verify the Paywall shows active Pro state and the four Pro entry paths do not show the Paywall. Use demo/fixture data only; do not perform a real App Store purchase in the UI test suite.

- [ ] **Step 3: Run the complete required simulator test command.**

First resolve the one already-running simulator UDID with `xcrun simctl list devices | ...` outside the sandbox. Then run:

`xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,id=<CURRENT_UDID>' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`

Expected: all unit and UI tests pass on that exact existing device, with no simulator clone, restart, shutdown, or device switch.

- [ ] **Step 4: Commit the verification coverage.**

Run: `git add Conn/ConnUITests/SubscriptionPaywallUITests.swift Conn/ConnUITests && git commit -m "test: cover subscription paywall flows"`

## Task 6: Store configuration and release checklist

**Files:**
- Create: `Conn/Conn/Configuration/SubscriptionProducts.md` or an equivalent release-only configuration note if the project already has a preferred location.
- Verify: App Store Connect subscription group and product IDs outside the repository.

- [ ] **Step 1: Configure the two auto-renewable products.**

Create one Pro subscription group with monthly `com.crazyball.conn.pro.monthly` at ¥18 and yearly `com.crazyball.conn.pro.yearly` at ¥98 for the intended storefronts. Keep the product IDs identical to the source constants.

- [ ] **Step 2: Verify metadata and legal links.**

Confirm display names, localized descriptions, privacy policy, terms of use, renewal disclosure, restore purchase path, and subscription management path before submission.

- [ ] **Step 3: Perform a release build sanity check.**

Run the complete simulator test command from Task 5, then inspect `git status --short`, confirm no test-only Pro bypass is enabled in Release, and record the exact device, command, and result in the handoff.

- [ ] **Step 4: Commit the release checklist if a repository note was created.**

Run: `git add Conn/Conn/Configuration/SubscriptionProducts.md && git commit -m "docs: add subscription release checklist"`

## Verification Summary

Before claiming completion, run the package entitlement tests, focused app tests, localization coverage, a simulator build, and the full Xcode unit/UI test suite against the current already-running simulator with parallel testing disabled. Report the exact commands, UDID, and results. A compile-only result or macOS-only package test is insufficient for this feature because it changes visible purchase, navigation, and paywall behavior.
