import Foundation

/// 埋点事件词表。事件名是服务端查询和看板的稳定契约，改名等同于破坏历史数据，
/// 新增事件必须追加而不是复用语义词。
public enum AnalyticsEvent: String, CaseIterable, Sendable {
    // 生命周期 / 导航
    case appLaunched = "app_launched"
    case screenViewed = "screen_viewed"

    // 主机
    case hostAdded = "host_added"
    case hostLimitHit = "host_limit_hit"

    // 连接 / 终端
    case connectionFinished = "connection_finished"
    case terminalOpened = "terminal_opened"
    case terminalProviderUnavailable = "terminal_provider_unavailable"

    // 文件
    case fileBrowserOpened = "file_browser_opened"
    case filePreviewOpened = "file_preview_opened"
    case fileTransferFinished = "file_transfer_finished"

    // 运维
    case dockerPageOpened = "docker_page_opened"
    case dockerActionFinished = "docker_action_finished"
    case logStreamFinished = "log_stream_finished"
    case processListOpened = "process_list_opened"

    // 脚本 / 自动化
    case snippetRunFinished = "snippet_run_finished"
    case batchRunFinished = "batch_run_finished"

    // 商业化
    case paywallShown = "paywall_shown"
    case featureGated = "feature_gated"
    case purchaseFinished = "purchase_finished"
    case restoreFinished = "restore_finished"

    // 质量 / 维护
    case errorOccurred = "error_occurred"
    case dbMigrationFinished = "db_migration_finished"
    case providerProbeFinished = "provider_probe_finished"
    case performanceSample = "performance_sample"

    // 第二版补充
    case hostEdited = "host_edited"
    case hostDeleted = "host_deleted"
    case hostKeyMismatchHandled = "host_key_mismatch_handled"
    case connectionReconnected = "connection_reconnected"
    case terminalClosed = "terminal_closed"
    case terminalKeyAction = "terminal_key_action"
    case terminalComposerUsed = "terminal_composer_used"
    case terminalSessionResumed = "terminal_session_resumed"
    case fileSaved = "file_saved"
    case fileOperationFinished = "file_operation_finished"
    case monitorRefreshFinished = "monitor_refresh_finished"
    case processKilled = "process_killed"
    case snippetCreated = "snippet_created"
    case settingChanged = "setting_changed"
    case appLockResult = "app_lock_result"
    case keyCreated = "key_created"
    case privateNetworkConnectFinished = "private_network_connect_finished"
    case jumpChainFinished = "jump_chain_finished"
    case proxyConnectFinished = "proxy_connect_finished"
    case hostDiagnosticsFinished = "host_diagnostics_finished"
    case gitWorkspaceOpened = "git_workspace_opened"
    case gitDiffViewed = "git_diff_viewed"
}

/// 属性键白名单。只允许稳定的枚举/分桶键，禁止把主机名、地址、路径、命令或
/// 错误原文塞进属性值。
public enum AnalyticsProperty: String, CaseIterable, Sendable {
    // 通用维度
    case appBuild = "app_build"
    case osVersion = "os_version"
    case deviceClass = "device_class"
    case locale
    case appearance
    case tier
    case distribution

    // 导航 / 入口
    case screen
    case source

    // 启动
    case launchType = "launch_type"
    case launchMsBucket = "launch_ms_bucket"
    case firstLaunch = "first_launch"

    // 主机 / 连接
    case hostRef = "host_ref"
    case authType = "auth_type"
    case route
    case pnProvider = "pn_provider"
    case grouped
    case provider
    case success
    case errorCategory = "error_category"
    case latencyMsBucket = "latency_ms_bucket"
    case resumed
    case reason
    case decision
    case hopCountBucket = "hop_count_bucket"
    case failedStep = "failed_step"

    // 文件
    case entryCountBucket = "entry_count_bucket"
    case fileType = "file_type"
    case previewMode = "preview_mode"
    case sizeBucket = "size_bucket"
    case direction
    case operation

    // 运维
    case tab
    case resourceCountBucket = "resource_count_bucket"
    case action
    case target
    case durationBucket = "duration_bucket"
    case processCountBucket = "process_count_bucket"
    case hostOs = "host_os"

    // 脚本
    case exitClass = "exit_class"
    case dangerConfirmed = "danger_confirmed"
    case hostCountBucket = "host_count_bucket"
    case successCount = "success_count"
    case failureCount = "failure_count"
    case cancelled

    // 商业化
    case context
    case feature
    case plan
    case result

    // 质量 / 设置
    case area
    case category
    case recoverable
    case schemaVersion = "schema_version"
    case metric
    case valueMsBucket = "value_ms_bucket"
    case changedFields = "changed_fields"
    case setting
    case value
    case biometric
    case keyType = "key_type"
    case inputMode = "input_mode"
}
