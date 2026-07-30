# Docker 操作（第二期）设计文档

日期：2026-07-30

## 背景与范围

第一期已经把 Docker 页扩展为容器、镜像、卷、网络四个资源分段，并补齐详情、反向关联和只读占用信息。本期在该读模型上加入必要的写操作：拉取镜像、创建容器、创建/删除卷和网络，以及可配置的 `docker system prune`。

Compose 是第三期的独立特性，不包含在本期。

## 目标

- 手机上完成常见容器部署：选镜像、设置名称、端口、环境变量、挂载、网络和重启策略。
- 允许高级用户以逐 token 的形式补充任意 `docker run` 参数，不暴露整段 Shell 命令输入。
- 将会删除资源的操作以可测试的强确认保护、留脱敏审计记录并在完成后刷新相关数据。
- 拉取镜像时显示真实的流式输出；不把 Docker 版本不稳定的文本进度伪造成百分比。

## 非目标

- 不做 Docker Compose、服务编排或 compose 文件发现。
- 不实现 Docker API socket，全部仍经 SSH 上的 Docker CLI。
- 不做 Docker 参数全集的结构化表单。资源限制、capabilities、healthcheck、entrypoint 等由「其他参数」覆盖。
- 不自动重试任何写操作；凡未得到明确 `ExecResult` 的操作结果均视为未知。

## 架构

沿用现有三层：`ConnOps` 负责命令构造和薄服务封装，App 侧资源模型保留各自的只读状态，新增单独的操作模型承载写入状态。

```
DockerView
├─ DockerViewModel               可用性、刷新编排、共用提示和审计
├─ DockerContainersModel         容器列表、详情；动作委托给 Operations
├─ DockerImagesModel             镜像列表与详情；动作委托给 Operations
├─ DockerVolumesModel            既有卷列表与详情
├─ DockerNetworksModel           既有网络列表与详情
└─ DockerOperationsModel         拉取、创建、删除、prune、进行中状态与确认目标
```

### ConnOps

新增以下值类型和命令函数：

| 类型 / 函数 | 职责 |
|---|---|
| `DockerRunDraft` | 创建容器所需的常用字段、运行命令 token 及其本地校验。 |
| `DockerVolumeDraft` / `DockerNetworkDraft` | 创建卷、网络的名称、驱动和高级 token。 |
| `DockerSystemPruneOptions` | 是否删除全部未引用镜像、是否包含卷。 |
| `ShellArgument` | 将一个参数编码成 POSIX shell 的单引号安全形式。 |
| `DockerCommand.pull/run/createVolume/removeVolume/createNetwork/removeNetwork/systemPrune` | 仅构造命令，不执行 I/O。 |
| `SSHCommandStream` | 输出流与一次最终 `ExecResult` 的组合；只有得到最终结果才知道成功或已知失败。 |
| `DockerService` 对应方法 | 读写 SSH 会话；pull 返回 `SSHCommandStream`，其他写操作返回 `ExecResult`。 |

`SSHCommandStream` 是 `SSHSession` 新增的带超时流式执行契约：它持有输出 `AsyncThrowingStream<Data, Error>` 与只能等待一次的完成结果。Citadel 侧由**同一个**后台读取任务同时转发 chunk、累积 stdout/stderr，并把 Docker 的非零退出转成 `ExecResult`；通道关闭、读取中断或超时则令完成结果抛错。这样拉取既能即时显示输出，也能区分「退出码非零（已知失败）」和「未拿到最终结果（未知）」。既有日志跟随继续使用无终态的 `execStream`，不改变其语义。

用户输入、表单选择与额外 token 都经 `ShellArgument` 编码后才拼入命令。这样 `;`、空格、反引号、`$()` 和单引号都只会作为 Docker 的一个参数，而非第二条 Shell 命令。额外参数每行代表一个 token；需要参数值的选项使用相邻两行，例如 `--add-host` 与 `db:10.0.0.2`。

`DockerRunDraft` 将参数分为两段：`otherOptionTokens` 固定出现在镜像**之前**，只能是 Docker 选项；`commandTokens` 固定出现在镜像**之后**，作为容器启动命令和参数。`otherOptionTokens` 禁止空 token、裸 `--`，以及和结构化字段冲突的 `--name`、`--network`、`--restart`、`--detach`/`-d`、`--publish`/`-p`、`--env`/`-e`、`--volume`/`-v`、`--mount`。用户须在相应结构化区编辑这些字段，避免高级 token 静默覆盖表单值。

写操作超时沿用现有原则：run、卷/网络增删为两分钟；镜像拉取与 prune 为五分钟。超时、通道关闭、流中断或任意未拿到 `ExecResult` 的错误都报告「执行结果未知」，不自动重试。只有本地校验失败才可以确定远端未执行。

### App 状态与刷新

`DockerOperationsModel` 从 `DockerContext` 取得会话、sudo 标志、提示、审计和定向刷新闭包，统一管理：

- 当前操作和共享串行 gate，保证**包含既有容器启停/删除、镜像删除/清理在内的所有 Docker 写操作**同一主机同一时刻只执行一项；
- pull 的逐行日志、结束状态和错误；
- 待确认的删除或 prune 请求；
- 已知成功或已知 Docker 拒绝后，对容器、镜像、卷、网络和磁盘占用作定向刷新。

`DockerViewModel` 在每次可用性探测后，用同一 `DockerContext` 先构造 Operations，再将它注入容器与镜像模型；现有模型删除各自的写入入口，改为调用 Operations。刷新以 `DockerRefreshScope` 回调由外壳完成，Operations 不持有资源模型，因此没有反向依赖。重建子模型前 Operations 尚无活动任务；一旦开始操作，外壳不会重建上下文。

操作失败时不清空当前列表或表单；远端 stderr 优先展示，并保留用户的草稿方便修正重试。已知退出结果（含非零）记入 `RunHistoryEntry.exitCode`；未知结果使用 `nil`，执行历史将其显示为「结果未知」而非成功。Docker 写操作审计只保存脱敏摘要（操作类型、资源名/镜像引用与字段数量），绝不保存原始命令、环境变量值、额外 token、拉取日志或远端输出。

## 交互设计

### 拉取镜像

镜像分段工具栏新增「拉取镜像」。表单仅要求镜像引用；提交后进入全屏进度页，滚动展示 Docker 实际流式输出。任务由 `DockerOperationsModel` 持有而非视图 `.task`，分段切换或视图重建不会取消本地观察。运行期间禁用手势关闭与返回导航：关闭 SwiftUI 页面不能可靠停止远端的 `docker pull`，因此不能制造「已取消」的假象。若 App 被系统终止或流丢失，下一次进入只显示「上次拉取结果未知」，用户可手动刷新镜像列表确认实际状态。成功或已知失败后再允许关闭；成功后刷新镜像、容器关联判定和磁盘占用。

### 创建容器

容器分段新增「创建容器」，使用 `Form` 的分区布局：

- 基本：镜像（必填）、名称、后台运行；
- 网络：从现有网络中选择，留空则使用 Docker 默认网络；
- 端口：可增删的主机端口、容器端口、协议；
- 环境变量：可增删的键和值；
- 挂载：具名卷或主机绑定路径、容器目标路径、只读开关；
- 重启策略：no、always、unless-stopped、on-failure；
- 高级：按顺序增删镜像前的「其他 Docker 选项」及镜像后的「启动命令 token」。

提交前只校验可确定的输入错误：镜像必填、名称与端口格式、环境变量键、绝对挂载目标、空/冲突 token 与重复端口。提交会先展示不可编辑的有效配置复核页；对 `--privileged`、host 网络、Docker socket 或宿主根目录绑定等高影响配置给出醒目提示。Docker CLI/daemon 是最终裁决，错误原样返回给用户。

### 卷、网络与清理

卷和网络分段各增加「创建」：默认 local/bridge 驱动，提供名称和额外 token。网络额外提供内部网络、可附加两个常用开关。卷、网络的删除仅对当前被标为未使用的资源显示；`bridge`、`host`、`none` 永不提供删除入口。

`docker system prune` 从镜像分段的菜单进入。确认面板明确列出影响：默认清理停止容器、未使用网络、悬空镜像和构建缓存；「所有未引用镜像」与「包含未使用卷」均为默认关闭的额外开关。

所有删除操作（既有的容器/镜像删除和 image prune 也包含在内）与 system prune 均要求强确认：删除资源必须逐字输入资源名；清理必须逐字输入 `PRUNE`。修改任何 prune 范围开关都会清空已输入确认词，执行按钮仅在精确匹配时启用。创建容器、创建卷/网络和拉取镜像不额外确认，但仍记录脱敏审计。

## 错误处理

- Docker 不可用时不展示写操作入口，沿用既有的安装、权限和 daemon 引导页。
- 有引用的卷/网络即使因列表过期仍触发删除，Docker daemon 也会拒绝；App 将已知拒绝显示给用户并刷新列表。
- Stream 连接失败或 pull 返回错误时保留已经收到的日志。拿到非零退出码时显示已知失败；未拿到最终结果时显示未知，禁止重试入口，只允许用户手动刷新对应资源以确认实际状态。
- 已知结果的写操作只刷新依赖资源，避免无关分段闪烁；未知结果不自动刷新并避免任何成功/失败断言。磁盘占用继续允许老版本 Docker 安全降级为「—」。

## 测试与验收

1. `ConnOpsTests`：参数单引号转义、run/卷/网络/prune 命令精确拼装、草稿校验、冲突 token、可选开关与超时。
2. `ConnSSH` 测试：`SSHCommandStream` 的分块输出、非零最终退出、流中断、超时和未知结果。Mock 必须能建模 stdout/stderr、exit code、每块延迟与中途错误。
3. App 单测：所有 Docker 写操作共享 gate、pull 的已知成功/失败和未知结果、审计脱敏、已知结果的刷新目标、错误时保留草稿，以及强确认的精确输入和 prune 范围改动后重置。
4. 演示数据：补 pull/创建/删除/prune 的确定性 Mock 响应。
5. UI 冒烟：创建容器表单及有效配置复核、拉取日志页、卷和网络的新增/删除确认、prune 范围选择与确认词。
6. 全部新增文案进入 App catalog，覆盖简体、繁体、英语、日语、韩语；新增 catalog 完整性测试，检查五种语言均有翻译且 format 占位符与源串一致；不新增 SwiftLint 警告。

## 后续

第三期再引入 Compose：兼容 `docker compose` v2 与 `docker-compose` v1，发现项目后提供 ps、up、down、restart、logs。它会成为第五个 Docker 分段，并有单独的项目/服务读模型。
