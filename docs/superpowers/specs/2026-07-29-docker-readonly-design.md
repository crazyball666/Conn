# Docker 只读补全（第一期）设计文档

日期：2026-07-29

## 背景

Docker 分段现在只有「容器」「镜像」两项。容器有详情页，**镜像没有**；卷与网络
完全缺失。而运维时真正要回答的问题——「这个卷还有人用吗」「磁盘被什么吃了」
「这个容器接在哪张网上」——一个都答不了。

用户的完整诉求是「Docker 做深」：compose、卷、网络管理，加上拉镜像、起容器等
写操作。**那是六个特性，不是一个**，各有各的域模型与风险面，塞进一份 spec 会
变成没人能审的东西。已拆成三期，本文档只覆盖第一期。

| 期 | 内容 | 为什么这样排 |
|---|---|---|
| **一（本文档）** | 镜像详情、卷、网络，全部只读 | 成本最低、立刻可用；把分段外壳与读模型立起来，后两期都要踩在上面 |
| 二 | 拉镜像、起容器、卷/网络的增删、prune | 风险集中在此，全是破坏性或半破坏性操作；起容器的表单要选网络和卷，依赖第一期的读模型 |
| 三 | Compose | 自有域模型（项目 → 服务）与自有的发现问题（从 config path 反查磁盘上的 compose 文件） |

## 目标

- 卷、网络、镜像详情从无到有，与容器同级。
- 回答「被谁在用」——每类资源的详情页列出引用它的容器，可点进去。
- 回答「什么能删」——列表上给无人使用的资源打徽标。
- 回答「磁盘被什么吃了」——卷与镜像显示占用。

## 非目标

- **本期不新增任何写操作。** 现有的删镜像与 `image prune` 保持原样，不扩展。
- 不做 Compose、不做拉镜像、不做起容器、不做卷/网络的创建与删除。
- 不引入 Docker API socket。全部经 `docker` CLI 走 exec，与方案 §4.4 一致。
- 不改 `sudo -n` 回退机制，它已贯通。

## 关键决策

| 决策 | 结论 | 理由 |
|---|---|---|
| 导航 | **四项分段控件**（容器/镜像/卷/网络） | 用户选定。代价是与外层「概览/进程/文件/Docker/日志」构成两层分段控件，且第三期加 Compose 后变五项会更挤——已知并接受 |
| 反向关联 | **做**，详情页列引用容器 + 列表打「未使用」徽标 | 这是「这个卷能不能删」的唯一依据，也正是第二期 prune 前要看的信息 |
| 磁盘占用 | 做，但**单独异步、绝不阻塞列表** | `docker system df -v` 在大主机上要数秒，且输出格式跨版本不稳 |
| 镜像层历史 | 做（`docker history`） | 只在打开镜像详情时多跑一条，开销小，却是「镜像为什么这么胖」的唯一答案 |
| 交叉跳转 | 做 | 排查时不用退出去手动找 |
| 列表搜索 | 四个列表都接 `ConnSearchField` | 镜像上到几十个时是必需品；纯本地过滤，不多跑命令 |
| 状态模型 | **拆成外壳 + 四个资源模型** | 见下节 |

## 架构

沿用既有分层，不发明新东西。

### 域层（ConnOps）

新增值类型，与现有 `ContainerInfo` 同构（`Sendable`、`Identifiable`、纯数据）：

| 类型 | 来源命令 | 关键字段 |
|---|---|---|
| `VolumeInfo` | `docker volume ls --format '{{json .}}'` | name、driver、scope、mountpoint |
| `VolumeDetail` | `docker volume inspect <名>` | mountpoint、createdAt、labels、options |
| `NetworkInfo` | `docker network ls --format '{{json .}}'` | id、name、driver、scope |
| `NetworkDetail` | `docker network inspect <名>` | subnet、gateway、internal、ipv6、**attachedContainers** |
| `ImageDetail` | `docker image inspect <引用>` | digest、architecture、os、size、entrypoint、cmd、env、labels |
| `ImageLayer` | `docker history <引用> --format '{{json .}}'` | createdBy、size、createdSince |
| `DockerDiskUsage` | `docker system df -v` | 按名字索引的镜像与卷占用 |

> **字段名以实际输出为准。** 上表按 Docker 24/25 的 `--format '{{json .}}'` 写就，
> 实现时要拿真实主机的输出做夹具逐字对齐，不照抄本文档。

### 命令与解析

- `DockerCommand` 加对应的拼串函数，风格与现有一致（`prefix(sudo)` 开头）。
- `DockerParser` 加对应的解析函数。**这两处是纯函数，是本期测试的主战场**——
  喂真实 `docker` 输出的固定夹具，不碰 SSH。
- `DockerService` 加对应的取数函数，签名与 `listImages(on:sudo:)` 同构。

### UI 与状态

`DockerViewModel` 现在 197 行，管着可用性探测 + 容器 + 镜像 + 动作 + 弹窗。
再塞进卷、网络、磁盘占用会奔着 500 行去，且四类资源的加载状态互相纠缠。

拆成**外壳 + 四个资源模型**：

```
DockerViewModel          可用性探测、sudo 标志、当前分段、共用的错误与弹窗
├─ DockerContainersModel 容器列表 + 动作（从现有代码搬过来，行为不变）
├─ DockerImagesModel     镜像列表 + 详情 + 层历史
├─ DockerVolumesModel    卷列表 + 详情
└─ DockerNetworksModel   网络列表 + 详情
```

每个六七十行、一个职责。四个资源模型形状高度相似（加载、搜索过滤、选中详情），
但**不做泛型抽象**——`@Observable` 与泛型组合起来很别扭，四份具体代码比一层
勉强的抽象好读。若将来第五类资源进来时三者已完全同构，再抽不迟。

新增视图：`ImageDetailView`、`VolumeListView` / `VolumeDetailView`、
`NetworkListView` / `NetworkDetailView`。列表与详情的骨架照 `ContainerDetailView`
的现有写法。

## 反向关联与「未使用」判定

三类资源来源不同，成本也不同：

三类资源来源不同，成本也不同，**判定语义更是各不相同**：

| 资源 | 「被谁在用」 | 「未使用」徽标怎么算 |
|---|---|---|
| 网络 | `docker network inspect` 直接给 `Containers` 映射，**零额外成本** | `network ls --filter dangling=true`，但**排除 `bridge` / `host` / `none`** |
| 卷 | `docker ps -a --filter volume=<名> --format '{{json .}}'` | `volume ls --filter dangling=true` |
| 镜像 | `docker ps -a --filter ancestor=<引用> --format '{{json .}}'` | **不能用 dangling**，见下 |

卷与网络可以直接信 Docker 的 `dangling`：对这两类，它的定义就是「没有任何容器
引用」，与我们要表达的意思一致。不自己拿容器列表比对，是因为那等于在客户端
重实现一遍服务端的判定规则，必然漂移，而用户据此决定删不删。

**镜像是例外，必须区分两个词**：

- **悬空（dangling）** = 没有 tag（`<none>:<none>`）。`ImageInfo.isDangling` 已经在算了。
- **未被使用** = 没有任何容器引用它。**一个打了 tag 的镜像完全可能没人用**。

`images --filter dangling=true` 给的是前者。拿它当「未使用」会漏掉一大批真正没
人用的镜像，更糟的是反过来会让用户以为「没标徽标 = 还在用」而不敢删。所以镜像
的「未被使用」由**容器列表反查**得出：容器段本来就要拉 `docker ps -a`，把那份
结果传给镜像模型比对 `image` 字段与镜像 ID / 引用即可，**不额外跑命令**。

> 这条比对是纯函数，要单测：容器用 `repo:tag` 引用、用完整 ID 引用、用短 ID 引用
> 三种写法都得认出来，否则会把在用的镜像标成未使用。

网络那条排除也是同理：`bridge` / `host` / `none` 是 Docker 预置的，永远删不掉，
给它们打「未使用」徽标只会制造噪声。

徽标是列表刷新时多跑一条 `ls --filter`（镜像那条免费），很轻；引用列表只在打开
详情页时才跑。

## 一个真实风险：`docker system df -v`

卷的大小 `docker volume ls` 根本不给（`Size` 字段恒为 `N/A`），只能靠
`docker system df -v`。而**这条命令的输出格式在 Docker 版本间不一致**，
`--format '{{json .}}'` 在较老版本上不可靠。

处理方式：

1. 磁盘占用**单独异步加载**，与列表并行，绝不阻塞列表渲染。
2. 解析失败或超时，占用一律显示「—」，列表照常可用，**不弹错误**——
   它是锦上添花的信息，不该让整个页面看起来坏了。
3. 实现时拿目标主机的实际 Docker 版本验证解析策略，夹具取自真实输出。

## 测试

**解析器**（ConnOpsTests，纯函数、不碰 SSH）
- 每个新解析函数一组夹具：正常输出、空输出、字段缺失、非 JSON 噪声行。
- 现有 `DockerParserTests` 已建立这套路子，照做。

**判定逻辑**
- 「未使用」判定、引用容器的归属、磁盘占用按名索引——都是纯函数，单测覆盖。
- 按本仓库惯例做**变异验证**：改判据要能让对应用例变红，否则测试是空转的。

**UI**
- `CONN_SMOKE_DETAIL=1 CONN_SMOKE_SEGMENT=docker` 截图验收四个分段与详情页。
- 需要给 `Conn/Demo/DemoOps.swift` 补卷、网络、`system df -v`、`history` 的演示
  数据。**这是实打实的工作量，不是顺手**——没有演示数据，截图验收和无服务器
  演示模式都做不了。

## i18n

新增面向用户的文案走 `L("…")`，五语齐全（zh-Hans 源串 + en / ja / ko / zh-Hant）。
新文案落在 App 侧 catalog（视图在 `Conn/Conn/Hosts` 下），与现有 Docker 文案同处。

## 待办（不在本期）

- 第二期：拉镜像（流式进度，复用 `execStream`）、起容器（表单）、卷/网络的创建
  与删除、`docker system prune`。
- 第三期：Compose（`docker compose ls` 发现项目 → ps / up / down / restart / logs；
  需处理 `docker compose` v2 与 `docker-compose` v1 的兼容）。
