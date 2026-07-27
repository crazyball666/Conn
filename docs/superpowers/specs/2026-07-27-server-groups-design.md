# 服务器分组 + 列表排序修正 + 删除语义统一 设计文档

日期：2026-07-27

## 背景与问题

服务器页（首页）当前有两个问题：

1. **排序被健康状态劫持。** `ServersViewModel.severityFirst` 按
   `crit → offline → warn → unknown → ok` 排序卡片。首次进页面时全部主机是
   `unknown`，随着采集回来逐台变成 `ok` 并往下沉——用户看到的是「还在连的排在
   已连上的前面」，且列表在采集期间持续跳动。
2. **没有分组概念。** `host_group` 表和 `host.group_uuid` 单分组外键在 `SchemaV1`
   就建好了，但从未接入 UI。列表上方那行 chip 筛选的是 `tags`，而 `tags` 只有
   Demo 数据会写（主机表单里没有编辑入口），实机上那行永远不渲染。

整理表结构时发现的既有缺陷，本次一并处理：

3. **`snippet_folder` 与 `host_group` 两套分组模型不对称。** 主机是单分组外键
   （从未接入 UI），命令是多分组成员表；命名一个叫 `group` 一个叫 `folder`；
   `snippet_folder` 只有 `name` 主键，没有 uuid、时间戳与同步字段。
4. **三张死表。** `probe_target`、`app_setting` 全仓无任何读写；
   `metric_sample` 是纯写入表，没有任何读取方。
5. **`errorMessage` 全局无人渲染。** `ServersViewModel`、`SnippetsViewModel`、
   `FileBrowserViewModel` 都在往一个没有任何 View 读取的字段里写错误字符串
   （全仓 grep 零命中），所有失败对用户静默。
6. **软删除墓碑是纯负担。** 每个查询都必须记得写 `WHERE deleted_at IS NULL`，
   漏一次就是数据泄漏 bug；而墓碑的唯一收益（同步时传播删除）对应的引擎
   尚未存在，且 §4.11 声称的「墓碑 30 天后物理清除」从未实现——墓碑目前
   只增不减。

## 目标

- 服务器列表回到默认顺序（`sort_order ASC, name ASC`），健康状态彻底退出排序。
- 服务器支持多分组 / 不分组；有分组时列表上方显示可点击筛选的分组条，没有分组则不显示。
- 主机与命令的分组模型完全对称，命名统一为 `group`。
- 删除语义全库统一为真 DELETE，取消软删除墓碑。
- 删除三张死表（`probe_target` / `app_setting` / `metric_sample`），指标改为纯内存态。
- 补上错误提示 UI，让已有的 `errorMessage` 真正可见。

## 非目标

- 不接入其他页面的错误提示（`FileBrowserViewModel` 等），留给后续统一逆入。
- 不做分组或主机的拖拽排序。
- 不引入「未分组」筛选项（无分组主机只在「全部」中出现）。
- 不保留任何向后兼容代码或数据：项目未发布，旧数据直接清空。

## 关键决策

| 决策 | 结论 | 理由 |
|---|---|---|
| 列表排序 | 移除状态排序，用默认 `sort_order ASC, name ASC` | 用户诉求；且状态排序导致采集期间列表持续跳动 |
| 分组存储键 | uuid | 重命名只改一行 `name`，成员关系不动；同名分组不撞车 |
| 成员关系 | 独立 join 表，**不声明外键** | `jump_chain` 已是无外键的 id 数组先例 |
| 管理入口 | 工具栏 `+` 菜单新建，筛选条 chip 长按重命名/删除 | 不额外增加分组页；主机表单只做多选 |
| 筛选条 chip | `全部` + 各分组，单选 | 与命令 Tab 行为一致；不提供「未分组」 |
| 标签筛选行 | 分组行直接替换 | `tags` 无编辑入口，该行实机不可达；`Host.tags` 字段保留，`isProduction` 高危命令确认逻辑不受影响 |
| 命令分组 | 本次一并对齐到 uuid | 开发阶段改造成本最低；晚改要面对真实用户数据 |
| 术语 | DB 表名与代码统一用 `group` | 表要重建，顺手把 DB 的 `folder`、UI 的「分组」、代码的 `folders` 三套叫法收敛成一套 |
| `HostGroup` / `SnippetGroup` | 保持两个独立类型 | 不同实体、不同表，可能分头长出字段（如主机分组加颜色）；真正该复用的是 UI 与 ViewModel 逻辑 |
| **删除语义** | **全库真 DELETE，取消所有墓碑** | 见下节 |
| 迁移链 | 折叠回 `SchemaV1`，删除 V2/V3 | 项目未发布；否则会出现「V2 建表 → V3 加列 → V5 全部 drop」的考古层 |
| 错误提示形式 | 顶部浮层 toast，自动消失 | 不占布局 |

### 关于删除模型：有意偏离既有文档

**决定：`host`、`host_group`、`ssh_key`、`snippet`、`snippet_group` 全部改为真
DELETE，去掉 `deleted_at` 列。全库不再有任何软删除。**

收益：

- `WHERE deleted_at IS NULL` 从全库消失。这是最容易漏写、漏了就变成数据泄漏
  bug 的一类代码。
- 5 个领域模型去掉 `deletedAt` 字段，`idx_host_deleted` 索引不再需要。
- 不需要墓碑 GC（§4.11 声称的 30 天清理本来也从未实现）。

**代价（已知并接受）：v1.1 iCloud 同步将无法传播删除。** 具体失效场景：

离线时删除主机 X → 本地行消失且不留痕迹 → 恢复网络后同步引擎先推
（`sync_dirty = 1` 的行里没有 X，无可推）再拉（CloudKit 上 X 仍在），
引擎看到「远端有、本地无」，只能解读为「其他设备新增」→ **X 在删除它的那台
设备上被重新插回**。根因是硬删后「已删除」与「尚未下载」在数据上无法区分。

**这与既有文档冲突，代码合入后以下两处文档不再描述现实**，需在 v1.1 立项时
重新决策（全量对账，或届时再引入删除记录）：

- 技术实现方案 §3：「所有表……为同步预留 `sync_dirty`、`deleted_at`（墓碑）」
- 技术实现方案 §4.11：「墓碑 30 天后物理清除」

`sync_dirty` **保留**——它标记「此行需要推送」，与删除传播无关，不受本次决定影响。

**连带必须修改的一处**：`BuiltinSnippets.importIfNeeded` 现在靠
`SnippetRepository.totalCount()`（含墓碑计数）判断「内置命令导入过了」，
使得用户删光默认命令后不会被重新灌回。硬删后墓碑不存在，该判定失效。
改为在 `SettingsStore`（UserDefaults）中记 `builtinSnippetsImported` 布尔，
`SnippetRepository.totalCount()` 随之删除——它唯一的用途就是数墓碑。

## 数据层

### 迁移链折叠

把最终 schema 直接写回 `SchemaV1.register`，**删除 `SchemaV2.swift` 与 `SchemaV3.swift`**，
`AppDatabase.migrator` 只注册 `SchemaV1`。不新增迁移版本。

DEBUG 构建已开 `eraseDatabaseOnSchemaChange = true`，会检测到 schema 变化并自动重建库。
**代价明示：模拟器与真机上现有的主机、密钥、命令数据全部清空。**
Release 构建不开该开关，若有装过旧版本的设备需手动删除 App 重装。项目未发布，可接受。

`AppDatabase.migrator` 注释「已发布的迁移不得修改」保留——它约束的是发布之后。

### 最终 9 张表

**`host`** —— 相对现状：删除 `group_uuid` 列、`deleted_at` 列、
`idx_host_group` 与 `idx_host_deleted` 两个索引。其余字段不变。

**`host_group`** —— 删除 `deleted_at` 列，其余不变
（uuid PK / name / sort_order / created_at / updated_at / sync_dirty）。

**`host_group_membership`**（新增）
```
host_uuid  TEXT NOT NULL
group_uuid TEXT NOT NULL
PRIMARY KEY (host_uuid, group_uuid)
index idx_host_group_membership_group ON (group_uuid)
```
不声明外键。

**`ssh_key`** —— 删除 `deleted_at` 列，其余不变。

**`snippet`** —— 删除 `folder` 遗留列与 `deleted_at` 列，其余不变。

**`snippet_group`**（新增，替换 `snippet_folder`）—— 与 `host_group` 完全同构：
uuid PK / name / sort_order / created_at / updated_at / sync_dirty。

**`snippet_group_membership`**（新增，替换 `snippet_folder_membership`）
```
snippet_uuid TEXT NOT NULL
group_uuid   TEXT NOT NULL
PRIMARY KEY (snippet_uuid, group_uuid)
index idx_snippet_group_membership_group ON (group_uuid)
```
不声明外键。两张成员表结构完全一致，只有外层实体列名不同。

**`known_host`** / **`run_history`** —— 不变（本就是真删除）。

**删除的表**：`snippet_folder`、`snippet_folder_membership`、
`metric_sample`、`probe_target`、`app_setting`。

**`AppDatabase.baseConfiguration`** —— `foreignKeysEnabled = true` 保留
（`host.key_uuid → ssh_key` 仍是外键），注释中对 `host.group_uuid` 的引用删掉。

### 删表的连带改动

**`probe_target` / `app_setting`** —— 全仓无 DAO、无 SQL 引用，直接移除，无连带改动。

**`metric_sample`** —— `MonitorScheduler` 每次采集写一行，
而 `MetricRepository.latest()` / `recentSamples()` 全仓无调用方；详情页趋势图走的是
`HostOverviewViewModel` 的内存数组（上限 40 点，离开页面即清空）。指标改为纯内存态，
连带删除：

- `ConnKit/Models/MetricSample.swift`、`ConnKit/Repositories/MetricRepository.swift`
- `ConnStore/DAO/MetricStore.swift`、`ConnStore/Records/MetricRecord.swift`
- `Tests/ConnStoreTests/MetricStoreTests.swift`
- `HostMetrics.sample` 属性与 init 参数（其注释即写「落库样本」）
- `MetricCollector` 中构造 `MetricSample` 的那段
- `MonitorScheduler` 的 `store` 属性、init 参数，以及写入用的 detached Task
- `AppDependencies.metricStore`、`live()` 中的 `MetricStore` 构造与
  `pruneSamples(olderThan:)` 调用、`demo()` 中的同类装配
- `HostOverviewViewModel` 构造 `MonitorScheduler` 时的 `store:` 实参

测试中没有任何 `MetricSample` 构造点，也没有 `MonitorScheduler(...)` 构造点，波及面干净。

**代价明示**：PRD §离线「无网时可查看最后一次监控快照」是 v1.0 需求，
`latest(hostUUID:)` 正是为它准备的（但从未接入）。删表后该需求失去地基，明确放弃。
历史曲线本就是 PRD 对比矩阵标注的 `v1.5💰` 项，不受影响。

## 领域模型与仓库

### ConnKit

- `Host`：删除 `groupUUID` 与 `deletedAt`，新增 `groupIDs: [String]`。
- `HostDraft`：同步增删；`toHost()` 透传。
- `HostGroup` / `SSHKey`：删除 `deletedAt`。
- `Snippet`：`folders: [String]` → `groupIDs: [String]`，删除 `deletedAt`。
  **删除** `folder` 兼容计算属性，以及为兼容它而写的整套自定义 `Codable`
  （`CodingKeys` / `init(from:)` / `encode(to:)`，约 40 行），回到编译器合成的 Codable。
  `Snippet.normalizedFolders` 一并删除：id 不是用户输入，不需要 trim；
  去重下沉到 store 的 `save`（成员表双列主键本身也保证了这一点）。
- 新增 `SnippetGroup`，字段与 `HostGroup` 完全一致。
- 各仓库协议的 `softDelete(id:)` 统一改名 `delete(id:)`，实现改为真 DELETE，
  所有 `deleted_at IS NULL` 过滤条件移除。
- `HostRepository`：`allHosts()` / `host(id:)` join 出 `groupIDs`；
  `save(_:)` 在同一事务里重写该主机的成员行（先删后插）。
- `HostGroupRepository`：`allGroups()` / `save(_:)` / `delete(id:)`。
- **分组管理从 `SnippetRepository` 中拆出**，新增 `SnippetGroupRepository`，
  签名与 `HostGroupRepository` 完全一致。`SnippetRepository` 上的 `allFolders()` /
  `saveFolder(_:)` / `deleteFolder(_:)` / `totalCount()` 四个方法删除。

**成员行清理**：成员表没有外键，所以级联不会自动发生。
删除分组时必须在同一事务里 `DELETE FROM <x>_group_membership WHERE group_uuid = ?`；
删除主机/命令时同理清 `host_uuid` / `snippet_uuid` 一侧。这是本设计里唯一需要
靠纪律维持的不变式，测试必须覆盖两个方向。

> 备注：改为真删除后外键 CASCADE 重新可用，加回外键即可让这两处清理自动化。
> 本次按既定决策不加外键，留作后续可选优化。

### ConnStore

- `HostRecord`：删 `groupUUID`、`deletedAt` 字段与对应 CodingKey。
- `SnippetRecord`：删 `folder`、`deletedAt` 字段。
- `HostStore` / `SnippetStore`：新增私有 `groupIDs(for:in:)` 查询，
  照现有 `SnippetStore.folders(for:in:)` 的写法（join 分组表以继承 `sort_order` 顺序）。
- 新增 `SnippetGroupStore`（`snippet_group` 表 DAO），与 `HostGroupStore` 同构。
- 所有 store 的查询去掉 `deleted_at IS NULL` 过滤。

### 依赖容器

`AppDependencies.groupRepository` 改名 `hostGroupRepository`（现在有两个 group 仓库，
原名有歧义），新增 `snippetGroupRepository`，删除 `metricStore`。
`live()` 与 `demo()` 两条装配路径同步更新。

### ConnRunner

`BuiltinSnippets`：JSON 资源的 `folders` 键改 `groups`（顶层与每条命令各一处）。
`importIfNeeded(into:groups:)` 同时接收片段仓库与分组仓库：先建分组、拿到 id，
再把命令的 `groupIDs` 指过去。**不再自行判空**——「是否已导入」由调用方
（`ConnApp`）查 `SettingsStore` 的 `builtinSnippetsImported` 标记决定，导入成功后置位。

分组名仍在导入时按当时语言 `L()` 定死一次，事后切语言不会重译——与现状行为一致。
差别在于成员匹配从「按本地化字符串」变成「按 id」，更稳。

### Demo 模式

`DemoData.seedHosts` 目前只种 `tags`，而 tags 唯一的用武之地就是被本次替换掉的筛选条。
必须补种分组（如「生产」「测试」「家用」）并把演示主机分配进去，否则新功能在
`CONN_DEMO` 截图与冒烟模式下完全不可见。`AppDependencies.demo()` 需要装配
`SnippetGroupStore` 并把它传给内置命令导入。

## ViewModel

### 共用：`GroupListEditor`

两个页面的分组增删改逻辑逐字相同（约 40 行），抽成 app 层的共用值类型，
持有一个 group 仓库并对外提供 `add(name:)` / `rename(id:to:)` / `delete(id:)`，
内部统一处理：

- 名称 trim 后为空 → 拒绝（UI 层同时把保存按钮 disable）。
- 重名（trim 后不分大小写比较，重命名时排除自身）→ 拒绝并返回错误文案。
- 新组 `sortOrder = (groups.map(\.sortOrder).max() ?? -1) + 1`。

第三个实体需要分组时直接复用。

### ServersViewModel

删除 `severityFirst`、`selectedTag`、`allTags`。

`cards` 变成 `hosts.filter(matches).map(card)`，顺序即 `HostStore.allHosts()` 给的
`sort_order ASC, name ASC`。健康状态彻底退出排序。

新增：
- `groups: [HostGroup]`，`load()` 中一并从 `hostGroupRepository` 读取。
- `selectedGroupID: String?`，默认 nil（= 全部）。
- 经 `GroupListEditor` 暴露的 `addGroup` / `renameGroup` / `deleteGroup`。
- `clearError()`，供 toast 绑定回写。

筛选：`selectedGroupID` 若解析不到 `groups` 中的现存分组，一律按「全部」处理
（防御分组从其他路径消失）；否则 `host.groupIDs.contains(id)`，与搜索取交集。
搜索仍匹配 `name` / `address`。

删除的分组正好是 `selectedGroupID` 时，复位为 nil。

### SnippetsViewModel

对称改造：`groups: [SnippetGroup]`，`SnippetListFilter.group` 的载荷从 name 换成 id，
`commandCount(in:)` 改按 id 统计，分组增删改同样走 `GroupListEditor`，新增 `clearError()`。

## UI

### 新组件（ConnUI）

**`GroupFilterBar`** —— 两个页面共用的分组筛选条。
`全部` + 各分组 chip，单选；再点一次当前选中项回到「全部」。
分组 chip 带 `.contextMenu` → 重命名 / 删除（回调交给宿主页面）。
用轻量的 `(id, name)` 模型驱动，不依赖 `HostGroup` / `SnippetGroup` 任何一方。
支持在「全部」之前插入若干**非分组的前置 chip**（命令页的「常用」就走这条），
前置 chip 不带 contextMenu。
`ServersView` 与 `SnippetsView` 中两份几乎相同的 `filterChip` 就此收敛为一份，
样式沿用现有 chip（`connFootnote` / `connAccentFill` / `Capsule` 描边 / `ConnPressStyle`）。

重命名与删除的 alert 由各自页面持有——与页面状态耦合过紧，抽出去反而更难读。

**`ConnToast`** —— `.connToast(message:)` 视图修饰器。
浮层胶囊，`overlay(alignment: .top)` 挂在**页面内容视图**上（即 `NavigationStack`
内部），因此天然落在导航栏下方、不与大标题重叠；顶部再留 `ConnSpacing.sm` 间距。
从上方滑入，3.5s 后自动消失，点击或上滑可提前关闭。
`reduceMotion` 开启时改用淡入淡出、不做位移。
连续报错时后到的消息替换当前消息并重置计时器，不做叠加队列。
本次接到 `ServersView` 与 `SnippetsView`。

### ServersView

- `tagFilter` 整块替换为 `GroupFilterBar`，渲染条件由 `!allTags.isEmpty` 改为
  `!viewModel.groups.isEmpty`——没有任何分组时整行不渲染。
- 工具栏 `+` 从 Button 改为 Menu：`新增服务器` / `新增分组`。
- 新建与重命名走 `.alert` + `TextField`，删除走 `.confirmationDialog`，
  文案「删除分组不会删除其中的服务器」。三者照搬 `SnippetsView` 已有实现。
- `cards` 上的 `.animation` 保留（增删主机仍需平滑），但注释中
  「故障置顶导致卡片重排」需改写——该前提已不成立。
- 挂上 `.connToast(...)`。

### SnippetsView

`commandFilters` 替换为 `GroupFilterBar`（额外保留 `常用` 前置 chip，它不是分组）。
分组页的重命名/删除改走 id。挂上 `.connToast(...)`。

### HostFormView

新增「分组」Section：多选打勾行，footer「可多选，也可以不选；不选时归为未分组」。
一个分组都没有时 footer 改为提示去列表页 `+` 菜单新建。对齐 `SnippetFormView` 的实现。
保存时丢弃解析不到现存分组的悬空 id。

## 错误处理

| 场景 | 行为 |
|---|---|
| 分组名 trim 后为空 | 保存按钮 disabled，不产生错误 |
| 分组重名 | 拒绝保存，toast「已存在同名分组」 |
| 仓库读写抛错 | 写入 `errorMessage`，toast 显示 `error.friendlyDiagnosis` |
| 删除分组 | 仅解除归属，主机/命令本身不受影响（确认弹窗中明示） |
| 删除主机/命令 | 真删除，不可恢复。确认弹窗文案需去掉「可随时重新添加」的暗示 |

## 测试

**ConnStoreTests**
- 成员表读写往返；`save` 重写成员而非追加。
- **删除分组时成员行被清空**，且组内主机/命令仍存在。
- **删除主机/命令时其成员行被清空**（另一个方向）。
- 删除后 `allHosts()` / `allSnippets()` 立即不含该条，且表中确实无残留行
  （与旧的墓碑行为区分）。
- `SchemaV1Tests.createsAllTables` 的表清单更新为最终 9 张。
- `SchemaV1Tests.migratesLegacySnippetFolders` 删除——它专测 V3 的搬迁路径，
  折叠后该路径不存在。

**ConnTests**
- 新增 `ServersViewModelTests`（照 `SnippetsViewModelTests` 的 Stub 仓库写法）：
  排序不受健康状态影响、分组筛选、搜索与分组取交集、删除选中分组后回到「全部」、
  `selectedGroupID` 悬空时按「全部」处理、重名被拒。
- `SnippetsViewModelTests` 跟进 id 化，并补一条：`commandCount(in:)` 按 id 统计。
- `GroupListEditor` 的规则（空名、重名、排序权重递增）单独测一遍，两个页面共用。
- 内置命令导入判定改走 `SettingsStore` 标记后，补一条：删光默认命令后重启不会被重新灌回。

**ConnUITests（包内）**
- `ConnToast` 自动消失时序与 reduce-motion 分支。

**删除的测试**
`MetricStoreTests` 整个删除（被测类型不再存在）。

**跟进修改**
`AppDatabaseTests`、`HostStoreTests`、`HostTests`、`HostGroupStoreTests`、
`SnippetStoreTests`、`SnippetTests`、`SettingsStoreTests` 随字段与语义变更同步更新。

## i18n

新增文案走 `L()`，补进 `Conn/Conn/Localizable.xcstrings` 的 5 种语言
（zh-Hans 源 / en / ja / ko / zh-Hant）。ConnUI 新组件的文案进
`Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`。

注意：改完 xcstrings 需 clean build，增量构建会继续使用旧的字符串目录。

新增字符串（zh-Hans）：`新增分组`、`分组名称`、`重命名分组`、`删除分组`、
`删除分组不会删除其中的服务器。`、`已存在同名分组`、`新增服务器`、
`可多选，也可以不选；不选时归为未分组。`、`还没有分组，先用右上角「+」新建。`

删除主机的确认文案需重写：现文案「将从列表中移除，可随时重新添加（不影响服务器本身）」
在真删除语义下具有误导性。

## 待办（不在本次范围）

- **v1.1 立项时重新决策删除传播**：本次取消墓碑后，iCloud 同步无法传播删除，
  届时需要全量对账或重新引入删除记录。技术实现方案 §3 与 §4.11 需同步修订。
- 其他页面（`FileBrowserViewModel` 等）接入 `ConnToast`。
- 分组与主机的拖拽排序。
- 成员表加回外键 CASCADE，把两处手动清理自动化。
