# Docker 操作（第二期）设计文档

日期：2026-07-30

## 背景与范围

第一期已经把 Docker 页扩展为容器、镜像、卷、网络四个资源分段，并补齐详情、反向关联和只读占用信息。本期在该读模型上加入必要的写操作：拉取镜像、创建容器、创建/删除卷和网络，以及可配置的 `docker system prune`。

Compose 是第三期的独立特性，不包含在本期。

## 目标

- 手机上完成常见容器部署：选镜像、设置名称、端口、环境变量、挂载、网络和重启策略。
- 允许高级用户以逐 token 的形式补充任意 `docker run` 参数，不暴露整段 Shell 命令输入。
- 将会删除资源的操作显式确认、留审计记录并在完成后刷新相关数据。
- 拉取镜像时显示真实的流式输出；不把 Docker 版本不稳定的文本进度伪造成百分比。

## 非目标

- 不做 Docker Compose、服务编排或 compose 文件发现。
- 不实现 Docker API socket，全部仍经 SSH 上的 Docker CLI。
- 不做 Docker 参数全集的结构化表单。资源限制、capabilities、healthcheck、entrypoint 等由「其他参数」覆盖。
- 不自动重试任何写操作；超时后的远端执行结果无法可靠判断。

## 架构

沿用现有三层：`ConnOps` 负责命令构造和薄服务封装，App 侧资源模型保留各自的只读状态，新增单独的操作模型承载写入状态。

```
DockerView
├─ DockerViewModel               可用性、刷新编排、共用提示和审计
├─ DockerContainersModel         既有容器列表与启停/删除
├─ DockerImagesModel             既有镜像列表与详情
├─ DockerVolumesModel            既有卷列表与详情
├─ DockerNetworksModel           既有网络列表与详情
└─ DockerOperationsModel         拉取、创建、删除、prune、进行中状态与确认目标
```

### ConnOps

新增以下值类型和命令函数：

| 类型 / 函数 | 职责 |
|---|---|
| `DockerRunDraft` | 创建容器所需的常用字段及其本地校验。 |
| `DockerVolumeDraft` / `DockerNetworkDraft` | 创建卷、网络的名称、驱动和高级 token。 |
| `DockerSystemPruneOptions` | 是否删除全部未引用镜像、是否包含卷。 |
| `ShellArgument` | 将一个参数编码成 POSIX shell 的单引号安全形式。 |
| `DockerCommand.pull/run/createVolume/removeVolume/createNetwork/removeNetwork/systemPrune` | 仅构造命令，不执行 I/O。 |
| `DockerService` 对应方法 | 读写 SSH 会话；pull 返回 `execStream`，其他写操作返回 `ExecResult`。 |

用户输入、表单选择与额外 token 都经 `ShellArgument` 编码后才拼入命令。这样 `;`、空格、反引号、`$()` 和单引号都只会作为 Docker 的一个参数，而非第二条 Shell 命令。额外参数每行代表一个 token；需要参数值的选项使用相邻两行，例如 `--add-host` 与 `db:10.0.0.2`。

写操作超时沿用现有原则：run、卷/网络增删为两分钟，prune 为五分钟。超时仅报告「结果未知」，不自动重试。

### App 状态与刷新

`DockerOperationsModel` 从 `DockerContext` 取得会话、sudo 标志、提示与审计闭包，统一管理：

- 当前操作和忙碌状态，避免相同主机同时发出两项破坏性操作；
- pull 的逐行日志、结束状态和错误；
- 待确认的删除或 prune 请求；
- 成功后对容器、镜像、卷、网络和磁盘占用的定向刷新。

`DockerViewModel` 提供刷新编排。操作失败时不清空当前列表或表单；远端 stderr 优先展示，并保留用户的草稿方便修正重试。每项执行均照既有 `RunHistoryEntry` 模式记录命令摘要、退出码和输出前 500 字符。

## 交互设计

### 拉取镜像

镜像分段工具栏新增「拉取镜像」。表单仅要求镜像引用；提交后进入全屏进度页，滚动展示 Docker 实际流式输出。运行期间禁用手势关闭：关闭 SwiftUI 页面不能可靠停止远端的 `docker pull`，因此不能制造「已取消」的假象。成功后刷新镜像、容器关联判定和磁盘占用。

### 创建容器

容器分段新增「创建容器」，使用 `Form` 的分区布局：

- 基本：镜像（必填）、名称、后台运行；
- 网络：从现有网络中选择，留空则使用 Docker 默认网络；
- 端口：可增删的主机端口、容器端口、协议；
- 环境变量：可增删的键和值；
- 挂载：具名卷或主机绑定路径、容器目标路径、只读开关；
- 重启策略：no、always、unless-stopped、on-failure；
- 高级：按顺序增删「其他 Docker 参数」token。

提交前只校验可确定的输入错误：镜像必填、名称与端口格式、环境变量键、绝对挂载目标、空 token 与重复端口。Docker CLI/daemon 是最终裁决，错误原样返回给用户。

### 卷、网络与清理

卷和网络分段各增加「创建」：默认 local/bridge 驱动，提供名称和额外 token。网络额外提供内部网络、可附加两个常用开关。卷、网络的删除仅对当前被标为未使用的资源显示；`bridge`、`host`、`none` 永不提供删除入口。

`docker system prune` 从镜像分段的菜单进入。确认面板明确列出影响：默认清理停止容器、未使用网络、悬空镜像和构建缓存；「所有未引用镜像」与「包含未使用卷」均为默认关闭的额外开关。执行按钮为 destructive，并在确认文本中复述已勾选的范围。

删除卷、删除网络与 prune 均要求强确认。创建容器、创建卷/网络和拉取镜像不额外确认，但仍记录审计。

## 错误处理

- Docker 不可用时不展示写操作入口，沿用既有的安装、权限和 daemon 引导页。
- 有引用的卷/网络即使因列表过期仍触发删除，Docker daemon 也会拒绝；App 将该错误显示给用户并刷新列表。
- Stream 连接失败或 pull 返回错误时保留已经收到的日志，提供明确失败状态；完成前不能按「取消」伪装远端已经停止。
- 每一项写操作完成后只刷新依赖资源，避免无关分段闪烁；磁盘占用继续允许老版本 Docker 安全降级为「—」。

## 测试与验收

1. `ConnOpsTests`：参数单引号转义、run/卷/网络/prune 命令精确拼装、草稿校验、可选开关与超时。
2. App 单测：操作模型对 Mock SSH 的 pull 成功/失败、审计、刷新目标、确认门槛、错误时保留草稿。
3. 演示数据：补 pull/创建/删除/prune 的确定性 Mock 响应。
4. UI 冒烟：创建容器表单、拉取日志页、卷和网络的新增/删除确认、prune 范围选择。
5. 全部新增文案进入 App catalog，覆盖简体、繁体、英语、日语、韩语；不新增 SwiftLint 警告。

## 后续

第三期再引入 Compose：兼容 `docker compose` v2 与 `docker-compose` v1，发现项目后提供 ps、up、down、restart、logs。它会成为第五个 Docker 分段，并有单独的项目/服务读模型。
