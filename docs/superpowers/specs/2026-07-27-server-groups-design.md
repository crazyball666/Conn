# 服务器分组 + 列表排序修正 设计文档

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

顺带发现两个既有缺陷，本次一并修正：

3. **`snippet_folder` 是全库唯一不守约定的实体表。** `SchemaV1` 开头声明「所有实体表
   带 `uuid` 主键、`created_at`/`updated_at`，并为 v1.1 同步预留 `sync_dirty` 与
   `deleted_at` 墓碑字段」。`snippet_folder` 只有 `name` 主键和 v3 补的 `sort_order`，
   删除走真 DELETE。后果：重命名等于删旧建新（`sort_order` 丢失），不能存在同名历史，
   且 v1.1 iCloud 同步接入时它会是唯一同步不了的实体——没有墓碑，A 设备删的组会被
   B 设备当作新建同步回来（`HostStore.softDelete` 的注释已写明这个坑）。
4. **`errorMessage` 全局无人渲染。** `ServersViewModel`、`SnippetsViewModel`、
   `FileBrowserViewModel` 都在往一个没有任何 View 读取的字段里写错误字符串
   （全仓 grep 零命中），所有失败对用户静默。

## 目标

- 服务器列表回到默认顺序（`sort_order ASC, name ASC`），健康状态彻底退出排序。
- 服务器支持多分组 / 不分组；有分组时列表上方显示可点击筛选的分组条，没有分组则不显示。
- 命令分组的数据库设计对齐到与主机分组同构的 uuid 方案。
- 补上错误提示 UI，让已有的 `errorMessage` 真正可见。

## 非目标

- 不接入其他页面的错误提示（`FileBrowserViewModel` 等），留给后续统一逆入。
- 不做分组或主机的拖拽排序。
- 不引入「未分组」筛选项（无分组主机只在「全部」中出现）。
- 不保留任何向后兼容 shim：项目处于开发阶段，旧字段直接删除。

## 关键决策

| 决策 | 结论 | 理由 |
|---|---|---|
| 分组存储键 | uuid | 重命名只改一行 `name`，成员关系不动；同名分组不撞车 |
| 管理入口 | 工具栏 `+` 菜单新建，筛选条 chip 长按重命名/删除 | 不额外增加分组页；主机表单只做多选 |
| 筛选条 chip | `全部` + 各分组，单选 | 与命令 Tab 行为一致；不提供「未分组」 |
| 标签筛选行 | 分组行直接替换 | `tags` 无编辑入口，该行实机不可达；`Host.tags` 字段保留，`isProduction` 高危命令确认逻辑不受影响 |
| 命令分组 | 本次一并对齐到 uuid | 开发阶段改造成本最低；晚改要面对真实用户数据 |
| 术语 | DB 表名与代码统一用 `group` | 表要重建，顺手把 DB 的 `folder`、UI 的「分组」、代码的 `folders` 三套叫法收敛成一套 |
| `HostGroup` / `SnippetGroup` | 保持两个独立类型 | 不同实体、不同表，可能分头长出字段（如主机分组加颜色）；真正该复用的是 UI |
| 错误提示形式 | 顶部浮层 toast，自动消失 | 不占布局 |

## 数据层

iOS 17 基线对应 SQLite 3.43，`ALTER TABLE DROP COLUMN`（3.35+）可用。
两个迁移各自是一个原子单元，遵循现有 `SchemaV1/V2/V3` 一文件一版本的约定。

### SchemaV4 `v4_host_group_membership`

```
host_group_membership
  host_uuid  TEXT NOT NULL → host(uuid)        ON DELETE CASCADE
  group_uuid TEXT NOT NULL → host_group(uuid)  ON DELETE CASCADE
  PRIMARY KEY (host_uuid, group_uuid)
index idx_host_group_membership_group ON host_group_membership(group_uuid)
```

步骤：建表建索引 → `INSERT OR IGNORE INTO host_group_membership
SELECT uuid, group_uuid FROM host WHERE group_uuid IS NOT NULL` 回填 →
`DROP INDEX idx_host_group` → `ALTER TABLE host DROP COLUMN group_uuid`。

`host_group` 表本身一个字段都不改。

### SchemaV5 `v5_snippet_group_uuid`

```
snippet_group
  uuid PK, name, sort_order,
  created_at, updated_at, sync_dirty, deleted_at   -- 与 host_group 完全同构

snippet_group_membership
  snippet_uuid TEXT NOT NULL → snippet(uuid)       ON DELETE CASCADE
  group_uuid   TEXT NOT NULL → snippet_group(uuid) ON DELETE CASCADE
  PRIMARY KEY (snippet_uuid, group_uuid)
index idx_snippet_group_membership_group ON snippet_group_membership(group_uuid)
```

步骤：
1. 建 `snippet_group` 与 `snippet_group_membership`。
2. 读出 `snippet_folder` 全部行，**在 Swift 侧逐行生成 uuid**（SQLite 造不出 UUID），
   连同原 `sort_order` 与 `Timestamp.now()` 插入 `snippet_group`。
   保留 name→uuid 映射供下一步用。
3. 按 name 把 `snippet_folder_membership` 的行搬进 `snippet_group_membership`。
4. `DROP TABLE snippet_folder_membership`、`DROP TABLE snippet_folder`。
5. `ALTER TABLE snippet DROP COLUMN folder`（`SchemaV1:83` 的遗留单分组列，v3 起已无人读写）。

空分组（无任何命令的分组）必须一并搬迁——它们是用户显式创建的，丢了等于静默删数据。

### 软删除与级联

本项目的删除是写墓碑（`deleted_at`）而非真 DELETE，因此 `ON DELETE CASCADE`
**不会触发**。两个 group store 的 `softDelete` 都必须在同一事务里显式执行
`DELETE FROM <x>_group_membership WHERE group_uuid = ?`，否则条目会永远挂在一个
已从 `allGroups()` 中消失的分组上。

主机/命令自身软删不需要处理成员行：`allHosts()` / `allSnippets()` 本就过滤墓碑，
残留成员行不可达。但**统计某分组内条目数必须 join 实体表并过滤 `deleted_at IS NULL`**，
不能直接 `COUNT(*)` 成员表——否则会把已删除的条目算进去。

## 领域模型与仓库

### ConnKit

- `Host`：删除 `groupUUID`，新增 `groupIDs: [String]`。
- `HostDraft`：同上；`toHost()` 透传。
- `Snippet`：`folders: [String]` → `groupIDs: [String]`。
  **删除** `folder` 兼容计算属性，以及为兼容它而写的整套自定义 `Codable`
  （`CodingKeys` / `init(from:)` / `encode(to:)`，约 40 行），回到编译器合成的 Codable。
  `Snippet.normalizedFolders` 一并删除：id 不是用户输入，不需要 trim；
  去重下沉到 store 的 `save` 里（成员表双列主键本身也保证了这一点）。
- 新增 `SnippetGroup`，字段与 `HostGroup` 完全一致（id / name / sortOrder /
  createdAt / updatedAt / syncDirty / deletedAt）。
- `HostRepository`：`allHosts()` / `host(id:)` join 出 `groupIDs`；
  `save(_:)` 在同一事务里重写该主机的成员行（先删后插）。
- `HostGroupRepository`：`allGroups()` / `save(_:)`（新建与重命名共用）/
  `softDelete(id:)`（附带清成员行）。签名不变，实现补清理逻辑。
- **分组管理从 `SnippetRepository` 中拆出**，新增 `SnippetGroupRepository`，
  签名与 `HostGroupRepository` 完全一致（`allGroups()` / `save(_:)` / `softDelete(id:)`）。
  `SnippetRepository` 上的 `allFolders()` / `saveFolder(_:)` / `deleteFolder(_:)` 三个
  方法删除——分组是独立实体，不该挂在片段仓库上，主机侧从一开始就是分开的。

### ConnStore

- `HostRecord`：删 `groupUUID` 字段与 `group_uuid` CodingKey。
- `SnippetRecord`：删 `folder` 字段；`toDomain(groupIDs:)`。
- `HostStore` / `SnippetStore`：新增私有 `groupIDs(for:in:)` 查询，
  照现有 `SnippetStore.folders(for:in:)` 的写法。
- 新增 `SnippetGroupStore`（`snippet_group` 表 DAO），与 `HostGroupStore` 同构。

### 依赖容器

`AppDependencies.groupRepository` 改名 `hostGroupRepository`（现在有两个 group 仓库，
原名有歧义），新增 `snippetGroupRepository`。`live()` 与 `demo()` 两条装配路径同步更新。

### ConnRunner

`BuiltinSnippets`：JSON 资源的 `folders` 键改 `groups`（顶层与每条命令各一处）。
`importIfNeeded(into:groups:)` 同时接收片段仓库与分组仓库：先建分组、拿到 id，
再把命令的 `groupIDs` 指过去。

分组名仍在导入时按当时语言 `L()` 定死一次，事后切语言不会重译——与现状行为一致。
差别在于成员匹配从「按本地化字符串」变成「按 id」，更稳。

## ViewModel

### ServersViewModel

删除 `severityFirst`、`selectedTag`、`allTags`。

`cards` 变成 `hosts.filter(matches).map(card)`，顺序即 `HostStore.allHosts()` 给的
`sort_order ASC, name ASC`。健康状态彻底退出排序。

新增：
- `groups: [HostGroup]`，`load()` 中一并从 `groupRepository` 读取。
- `selectedGroupID: String?`，默认 nil（= 全部）。
- `addGroup(_ name: String)` / `renameGroup(id:to:)` / `deleteGroup(id:)`。
- `clearError()`，供 toast 绑定回写。

筛选：`selectedGroupID.map { host.groupIDs.contains($0) } ?? true`，与搜索取交集。
搜索仍匹配 `name` / `address`。

规则：
- 新组 `sortOrder = (groups.map(\.sortOrder).max() ?? -1) + 1`。
- 名称 trim 后为空 → 保存按钮 disabled（UI 层拦截）。
- 重名（trim 后不分大小写比较，重命名时排除自身）→ 拒绝保存，写 `errorMessage`。
- 删除的分组正好是 `selectedGroupID` 时，复位为 nil。

### SnippetsViewModel

对称改造：`groups: [SnippetGroup]`，`SnippetListFilter.group` 的载荷从 name 换成 id，
`commandCount(in:)` 改按 id 统计，`addGroup` / `renameGroup` / `deleteGroup` 与
服务器侧同规则（含重名校验），新增 `clearError()`。

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

`commandFilters` 替换为 `GroupFilterBar`（额外保留 `常用` chip，它不是分组）。
分组页的重命名/删除改走 id。挂上 `.connToast(...)`。

### HostFormView

新增「分组」Section：多选打勾行，footer「可多选，也可以不选；不选时归为未分组」。
一个分组都没有时 footer 改为提示去列表页 `+` 菜单新建。对齐 `SnippetFormView` 的实现。

## 错误处理

| 场景 | 行为 |
|---|---|
| 分组名 trim 后为空 | 保存按钮 disabled，不产生错误 |
| 分组重名 | 拒绝保存，toast「已存在同名分组」 |
| 仓库读写抛错 | 写入 `errorMessage`，toast 显示 `error.friendlyDiagnosis` |
| 删除分组 | 仅解除归属，主机/命令本身不受影响（确认弹窗中明示） |

## 测试

**ConnStoreTests**
- 成员表读写往返；`save` 重写成员而非追加。
- 分组软删后成员行被清空，且组内主机/命令仍存在。
- 主机/命令软删后不再出现在 `allHosts()` / `allSnippets()`，其残留成员行不影响读取。
- SchemaV4：从 `group_uuid` 回填正确，列已删除。
- SchemaV5：按 name join 搬迁正确，空分组不丢失，旧表已删除。

**ConnTests**
- 新增 `ServersViewModelTests`（照 `SnippetsViewModelTests` 的 Stub 仓库写法）：
  排序不受健康状态影响、分组筛选、搜索与分组取交集、删除选中分组后回到「全部」、
  重名被拒。
- `SnippetsViewModelTests` 跟进 id 化，并补一条：`commandCount(in:)` 按 id 统计，
  不把已删除的命令算进去。

**ConnUITests（包内）**
- `ConnToast` 自动消失时序与 reduce-motion 分支。

**跟进修改**
`AppDatabaseTests`、`SchemaV1Tests`、`HostStoreTests`、`HostTests`、
`HostGroupStoreTests`、`SnippetStoreTests`、`SnippetTests` 随字段变更同步更新。

## i18n

新增文案走 `L()`，补进 `Conn/Conn/Localizable.xcstrings` 的 5 种语言
（zh-Hans 源 / en / ja / ko / zh-Hant）。ConnUI 新组件的文案进
`Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`。

注意：改完 xcstrings 需 clean build，增量构建会继续使用旧的字符串目录。

新增字符串（zh-Hans）：`新增分组`、`分组名称`、`重命名分组`、`删除分组`、
`删除分组不会删除其中的服务器。`、`已存在同名分组`、`新增服务器`、
`可多选，也可以不选；不选时归为未分组。`、`还没有分组，先用右上角「+」新建。`

## 待办（不在本次范围）

- 其他页面（`FileBrowserViewModel` 等）接入 `ConnToast`。
- 分组与主机的拖拽排序。
