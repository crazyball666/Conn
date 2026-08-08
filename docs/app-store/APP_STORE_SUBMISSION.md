# ConnTerm App Store 上架资料草案

这份资料按当前 MVP 的实际实现整理，适用于 App Store Connect 的首次创建、TestFlight 内测和 App Review 提交。方括号中的内容需要在后台或最终发布前确认；不要把真实服务器地址、用户名、密码或私钥提交到仓库。

## 1. 商店基础信息

| 项目 | 建议值 | 状态 |
| --- | --- | --- |
| App 名称 | `ConnTerm` | 需在 App Store Connect 检查重名和商标 |
| 副标题（中文） | `SSH 服务器运维工作台` | 可直接使用 |
| Subtitle（English） | `SSH Server Operations` | 可直接使用 |
| 主类别 | Developer Tools | 后台选择 |
| 次类别 | Utilities | 后台选择 |
| 年龄分级 | `[按 2026 版问卷生成]` | 必须在 App Information 完成新版问卷，不能手填推断 |
| 支持 URL | `[部署后的 HTTPS 域名]/support/` | 必须替换为公开地址；页面内要配置有效邮箱及依法需要提供的电话、地址 |
| 隐私政策 URL | `[部署后的 HTTPS 域名]/privacy/` | 必须替换为公开可访问的绝对 URL；网站源文件见 `docs/website/privacy/` |
| 营销 URL | `[可选]` | 可选 |
| 价格 | `[免费 / 付费下载]` | 首发建议免费；付费下载可直接配置价格，只有应用内购买或订阅才需要 StoreKit |
| Copyright | `2026 [个人或公司法定名称]` | 必填，Apple 会自动添加版权符号 |
| Content Rights | `[按实际权利情况声明]` | 后台填写；用户只能连接其拥有或获授权的主机 |
| DSA 交易者状态 | `[交易者 / 非交易者]` | 无论是否在欧盟销售都必须声明；交易者需验证公开联系信息 |

### 中文宣传文案

**推广文本（最多 170 个中文字符，建议首发使用）**

随身 SSH 服务器运维工作台：看状态、查日志、管 Docker、跑脚本，关键时刻不用打开电脑。

**关键词（不含 App 名称，逗号分隔）**

SSH,服务器,终端,运维,Docker,日志,文件管理,进程,脚本,开发者

**完整描述**

ConnTerm 是面向开发者和运维人员的本地 SSH 服务器管理工具。连接你自己的主机后，可以在手机上完成日常巡检和应急处置。

主要功能：

- SSH 密码或密钥认证，支持主机分组管理；
- 终端、常用命令和 Shell 脚本，配备移动端快捷键栏；
- 远程文件浏览、搜索和编辑；
- CPU、内存、磁盘、网络和 I/O 状态查看，以及进程列表；
- Docker 容器、镜像、卷、网络和 Compose 项目管理；
- 容器和系统日志查看，支持启动、停止、重启等操作；
- 密钥生成、导入、导出、公钥复制和主机绑定；
- 深色模式、主题色、中文/英文界面和错误重试反馈。

ConnTerm 不要求注册账号，也不提供自建云服务。主机配置、脚本、操作记录和密钥元数据保存在设备本地；私钥保存在系统 Keychain。应用不会把这些数据上传到 ConnTerm 的服务器。监控采集只在应用使用期间进行，不提供 7×24 后台告警推送。

使用 ConnTerm 需要你拥有可访问的 SSH 主机，并自行承担远程命令和 Docker 操作的风险。危险操作会要求确认；请在执行前核对主机和命令。

### English listing copy

**Promotional text**

Your local SSH operations desk: inspect servers, review logs, manage Docker, and run scripts from your iPhone.

**Keywords**

SSH,server,terminal,DevOps,Docker,logs,SFTP,processes,scripts,developer

**Description**

ConnTerm is a local SSH Server Operations tool for developers and system administrators. Connect to your own hosts and handle everyday checks and urgent fixes from your phone.

Key features:

- SSH password or key authentication with host groups;
- A terminal with saved commands, shell scripts, and mobile-friendly shortcuts;
- Remote file browsing, search, and editing;
- CPU, memory, disk, network, I/O, and process views;
- Docker containers, images, volumes, networks, and Compose projects;
- Container and system log viewing with start, stop, and restart actions;
- SSH key generation, import, export, public-key copy, and host binding;
- Dark mode, theme colors, Chinese/English localization, and retryable errors.

ConnTerm does not require an account and does not operate a ConnTerm cloud service. Host configuration, scripts, operation history, and key metadata stay on the device; private keys are stored in the system Keychain. ConnTerm does not upload this data to a ConnTerm server. Monitoring runs while the app is in use and does not provide 24/7 background alerts.

You need an SSH host that you own or are authorized to access. Review every command and confirm the target before performing destructive operations.

## 2. App Privacy 问卷草案

以当前实现为准，建议在 App Store Connect 选择：

| 问题 | 建议答案 | 依据 |
| --- | --- | --- |
| 是否收集数据 | 否 | 没有 ConnTerm 服务端、账号系统、分析 SDK 或广告 SDK |
| 是否用于跟踪 | 否 | 未接入广告、跨 App 跟踪或行为分析 |
| 联系信息、用户内容、标识符、诊断、位置、财务信息 | 均不收集 | 数据只用于本机功能，不上传 |
| 本地网络 | 需要权限 | 通过 SSH 连接用户添加的主机 |

填写后必须在 App Privacy 页面点击 **Publish**。只保存但未发布，仍不满足提审要求。

工程内已加入：

- `PrivacyInfo.xcprivacy`：声明无跟踪、无收集数据，并声明 UserDefaults 的系统 API 使用理由；
- `NSLocalNetworkUsageDescription`：解释本地网络用于连接 SSH 主机、文件、进程和 Docker 管理。

如果未来加入 Crash 报告、分析、云同步、订阅或第三方登录，必须重新填写隐私问卷和隐私政策，不能继续沿用“无收集、无上传”的答案。

## 3. 出口合规（Export Compliance）填写草案

ConnTerm 使用 SSH 以及系统/开源密码学库保护连接和密钥，因此 App Store Connect 的出口合规问卷不能留空。建议按以下方向准备，但最终以 App Store Connect 当前问卷和你的发行主体所在地要求为准：

1. 如问“是否使用加密”，应选择“是”；
2. 说明使用的是 SSH 等标准协议和公开可用的密码学算法，目的是保护远程连接与本地凭据；
3. 如后台提供“标准加密/豁免”选项，按 Apple 的说明判断是否适用；不要在没有确认前自行声称豁免；
4. 若问卷确认无需提交文档，再在工程中设置 `ITSAppUsesNonExemptEncryption = NO`；若需要文档，先上传并使用 Apple 审核后提供的配置值；
5. 保留开源依赖清单（GRDB、swift-crypto、swift-nio/Citadel）和许可证，供合规或审核需要时使用。

这不是法律意见；出口合规最终以 Apple 后台问卷和发行主体的合规确认结果为准。

## 4. App Review 备注模板

将以下内容粘贴到 Review Notes，再把方括号替换为真实的测试信息。真实凭据只放在 App Store Connect 的审核备注中，不放进 Git。

```text
ConnTerm is a local SSH client for servers owned or administered by the user. It does not require an account and has no ConnTerm backend.

Test setup:
1. Open ConnTerm and tap Add Server.
2. Add the review SSH host below using the supplied test credentials.
3. Open the host to review Overview, Processes, Files, Docker, and Logs.
4. Open Terminal to run a harmless command such as `uname -a` or `echo ConnTerm review`.
5. In Docker, review the lists and use read-only details. Do not run destructive actions unless explicitly requested.
6. Open Settings > Key Manager to review key generation/import UI. No real private key is included in the build.

Review host:
- Address: [review host]
- Port: [port]
- Username: [username]
- Authentication: [review password or review key instructions]
- Availability: This account remains active throughout App Review.

The app stores host configuration and credentials locally. Private keys are kept in the system Keychain. No user data is uploaded to a ConnTerm server. Monitoring is active while the app is in use; this product does not provide background push monitoring.

If the host is temporarily unavailable, please contact [review contact email].
```

审核主机应满足：

- 仅包含脱敏、可恢复的测试数据；
- 提供 Docker 环境时使用不会影响生产的容器/Compose 项目；
- 账号权限足够展示功能，但不要使用 root 生产账号；
- 主机和账号在整个审核期间不得过期或停机，审核完成后再撤销。

## 5. TestFlight / 提交前检查

### 必测流程

- [ ] 新安装后首次打开，默认深色模式和紫色主题正常；
- [ ] 新增主机：密码认证、密钥认证、错误密码、拒绝连接、主机指纹变化；
- [ ] 网络断开、恢复网络、各页面重试按钮和错误提示一致；
- [ ] 主机详情：监控数据加载、CPU 指标显示/隐藏、内存和 Swap、磁盘读写、网络/I/O；
- [ ] 终端：键盘弹出/收起、快捷键、粘贴、长输出自动跟随、命令/脚本执行；
- [ ] 文件：搜索、进入目录、编辑、保存失败和重试；
- [ ] Docker：容器/镜像/卷/网络/Compose 列表、详情、日志、创建表单和危险操作确认；
- [ ] 密钥：生成、导入、改名、复制公钥、导出、删除，以及 Keychain 与本地元数据不一致时的恢复；
- [ ] 中英文切换、深色模式、动态字体、VoiceOver 基本导航；
- [ ] iPhone 支持尺寸的竖屏布局；首发构建不声明 iPad 支持；
- [ ] 从旧版本升级安装后，主机、脚本、密钥引用和历史记录仍可读取；
- [ ] 删除应用后确认本地数据库清除；Keychain 行为按最终产品策略复核，不要在商店文案中承诺跨设备同步。

### 归档前工程检查

- [ ] 将 `CURRENT_PROJECT_VERSION` 增加到未使用的 build number；
- [ ] 使用 Distribution 证书和 App Store provisioning profile 归档；
- [ ] Release 构建不注入 `CONN_DEMO`、`CONN_SMOKE_*` 等调试环境变量；
- [ ] `xcodebuild archive`、`-validate-for-store` 和 TestFlight 上传成功；
- [ ] 检查包内 `PrivacyInfo.xcprivacy`、本地网络权限说明、App icon 和版本号；
- [ ] 确认第三方依赖许可证和隐私清单随包存在；
- [ ] 确认提交截图来自 `docs/app-store/screenshots/marketing/app-store-6.9/`，尺寸为 `1320 × 2868` 且不含 Alpha；
- [ ] 保存归档 dSYM，便于处理崩溃报告。

## 6. 还需要用户/后台补充的内容

1. 在 `docs/website/support/index.html` 替换支持邮箱、电话、地址和法定主体，并把官网部署到公开 HTTPS 域名；
2. 将公开的 `/support/`、`/privacy/` 地址填入 App Store Connect；
3. 后台确认价格、销售地区、Copyright、Content Rights、2026 版年龄分级和 DSA 交易者状态；
4. 上传 `marketing/app-store-6.9/` 中的中英文截图；首发为仅 iPhone，不需要 iPad 截图；
5. 准备一台在整个审核期间持续可用的隔离 SSH 主机和审核账号；
6. 完成并发布 App Privacy 回答；
7. 完成出口合规问卷，再按问卷结果设置 Info.plist 或上传加密材料；
8. 确认最终版本号和未被使用的 build number，完成 Archive、Validate App 和构建选择；
9. 如果选择中国大陆销售，先完成适用的备案/许可信息；否则首发销售地区不包含中国大陆；
10. 如果未来加入应用内购买或订阅，先实现并验证 StoreKit 产品、恢复购买和退款后状态处理，再提交相应商品审核。
