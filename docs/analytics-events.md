# Conn 匿名产品分析埋点

本文件描述 Conn 通过自建 Pulse 服务上报的匿名产品分析事件。采集策略由产品决定：
默认开启、不提供用户级开关；因此事件设计必须遵守最小化原则。

## 隐私边界

允许上报：

- 应用版本、构建号、系统版本、设备类型（iPhone/iPad）、界面语言、外观模式、订阅层级、分发渠道
- 匿名安装标识（SDK 自动生成）
- 匿名主机引用（本地主机 UUID，不含主机名或地址）
- 枚举、布尔值、计数/耗时/大小分桶

禁止上报：

- 主机名、IP、端口、用户名、密码、密钥、证书、代理或跳板机地址
- 文件路径、文件名、命令内容、终端输出、日志正文、错误原文
- 订阅交易 ID、App Store 账户信息
- 任何自由文本（属性值超过 64 字符或包含控制字符会被 `AnalyticsService` 丢弃）

## 公共属性

| 键 | 取值 |
|---|---|
| `app_build` | CFBundleVersion |
| `os_version` | UIDevice.systemVersion |
| `device_class` | iPhone / iPad |
| `locale` | App 内语言（system / zh-Hans / zh-Hant / en / ja / ko） |
| `appearance` | system / light / dark |
| `tier` | free / pro |
| `distribution` | debug / appstore |

## 已接入事件

| 事件 | 触发 | 主要属性 |
|---|---|---|
| `app_launched` | 每次进程启动 | `first_launch`、`launch_type` |
| `screen_viewed` | 切换主 Tab | `screen` |
| `host_added` | 主机保存成功 | `auth_type`、`route`、`pn_provider`、`grouped`、`host_ref` |
| `host_limit_hit` | 免费版达到主机上限 | `source` |
| `connection_finished` | 终端连接成功/失败 | `success`、`provider`、`host_ref`、`error_category` |
| `connection_reconnected` | 终端重连结束 | `result`、`provider`、`host_ref` |
| `terminal_opened` | 终端页出现 | `provider`、`source`、`host_ref` |
| `file_browser_opened` | 文件列表加载结束 | `source`、`success`、`entry_count_bucket`、`latency_ms_bucket`、`error_category` |
| `file_preview_opened` | 打开 Markdown/HTML 预览 | `file_type`、`preview_mode`、`size_bucket`、`result` |
| `file_saved` | 编辑器保存结束 | `file_type`、`size_bucket`、`result`、`error_category` |
| `file_transfer_finished` | 上传/下载结束 | `direction`、`size_bucket`、`result`、`error_category` |
| `docker_page_opened` | Docker 容器页加载结束 | `tab`、`success`、`resource_count_bucket`、`latency_ms_bucket`、`error_category` |
| `docker_action_finished` | Docker 写操作结束 | `action`、`target`、`result`、`duration_bucket`、`error_category` |
| `log_stream_finished` | 日志跟随结束 | `source`、`result`、`duration_bucket`、`error_category` |
| `process_list_opened` | 进程页首轮加载结束 | `success`、`process_count_bucket`、`latency_ms_bucket` |
| `snippet_run_finished` | 单机脚本执行结束 | `source`、`result`、`duration_bucket`、`danger_confirmed`、`error_category` |
| `batch_run_finished` | 批量执行结束 | `host_count_bucket`、`success_count`、`failure_count`、`result`、`duration_bucket` |
| `paywall_shown` | Paywall 出现 | `context`、`source` |
| `feature_gated` | 免费用户触发 Pro 功能 | `feature`、`source` |
| `purchase_finished` | 购买流程结束 | `plan`、`result`、`error_category` |
| `restore_finished` | 恢复购买结束 | `result`、`error_category` |
| `error_occurred` | 关键失败路径 | `area`、`category`、`recoverable`、`source` |
| `db_migration_finished` | 数据库构造/迁移结束 | `result`、`duration_bucket`、`error_category` |

## 待接入（第二版）

- `terminal_provider_unavailable`、`provider_probe_finished`：需要在 `NewTerminalFlowModel` 的 provider 探测完成点回调。
- `monitor_refresh_finished`、`private_network_connect_finished`、`jump_chain_finished`、`proxy_connect_finished`：需要在对应连接管线增加结果回调。
- `host_edited`、`host_deleted`、`host_key_mismatch_handled`、`terminal_closed`、`terminal_key_action`、`terminal_composer_used`、`file_operation_finished`、`setting_changed`、`app_lock_result`、`key_created`。
- `performance_sample`：启动、连接、文件列表、Docker 列表的耗时采样（建议 10% 采样）。

## 新增事件约定

1. 先加入 `AnalyticsEvent` / `AnalyticsProperty`，事件名使用 snake_case 且不可改名。
2. 属性值只能是枚举、布尔、计数或分桶；禁止自由文本。
3. 在事件触发点调用 `Analytics.shared.track(...)`；不要直接调用 Pulse SDK。
4. 为新增事件补 `ConnAnalyticsTests` 或对应业务测试；至少验证属性白名单和失败路径。
5. 同步更新本文档和隐私政策（如新增数据类别）。
