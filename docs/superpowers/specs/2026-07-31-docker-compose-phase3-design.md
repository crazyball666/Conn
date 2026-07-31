# Docker Compose（第三期）设计

日期：2026-07-31

## 范围

Docker 页增加第五个「Compose」分段，在现有 SSH + Docker CLI 架构上管理 Compose
项目与服务。兼容 `docker compose` v2 和 `docker-compose` v1，不接 Docker
Socket，也不在 App 中解释或改写 YAML。

本期提供：

- 自动发现 Compose 项目；
- 手动填写 compose 文件绝对路径，并可选填写项目名；
- 项目 → 服务两级只读状态；
- 项目级 `up -d`、`down`、`restart`；
- 服务级 `restart`；
- 项目或单服务实时 `logs`。

本期不提供 `pull`、`build`、`scale`、`down --volumes`、compose 文件编辑、目录
递归扫描或手动输入任意 Shell 命令。

## 发现与兼容

先执行 v2 探测，失败后再探测 v1，得到强类型 `DockerComposeDialect`。所有后续命令
由该值选择 `docker compose` 或 `docker-compose` 前缀，不在 UI 到处判断版本。

v2 使用 `compose ls --all --format json` 发现项目，并与带 Compose 标签的容器信息
合并。v1 没有等价、稳定的 `ls` 接口，因此完全从带
`com.docker.compose.project` 标签的全部容器归并项目。两种 dialect 都读取
`com.docker.compose.project.config_files` 与
`com.docker.compose.project.working_dir`；若容器标签缺少 working dir，才回退为
首个配置文件的父目录。所有项目命令显式传入 `--project-directory`，从而保持相对
路径、默认 `.env` 与项目名推导的上下文。已经执行过 `down`、没有留下容器的 v1
项目无法自动发现，用户可用手动路径补充。

不做服务器目录递归扫描：搜索范围无法可靠确定，代价高，也会越过用户明确指定的文件
边界。只用 `compose ls`、容器标签和用户输入的路径。

手动添加时要求 compose 文件和可选 project directory 都是绝对路径。App 用对应
dialect 执行 `config --services` 验证文件并取得服务名；project directory 留空时
取 compose 文件父目录。用户明确填写的项目名必须匹配
`[a-z0-9][a-z0-9_-]*`，否则在本地提示并不执行远端命令。项目名留空时，把 project
directory 末级目录名转为小写，将连续非法字符替换为单个 `-`，移除开头非字母数字
字符；结果为空时使用 `compose`。复核页展示最终项目名，避免隐式规范化后用户不知道
实际 `-p` 值。

项目身份以 Compose project name 为键：同名项目在同一 Docker daemon 上本就共享
`-p` 命名空间，列表只展示一项；同一配置文件使用不同项目名则保留为不同项目。自动
发现与手动项目同名时，实时状态和容器摘要取自动发现结果，配置文件与 project
directory 取用户明确填写的手动值。再次手动添加同名项目视为更新配置，不生成重复项。

手动项目和最近一次成功发现的快照保存在 `DockerViewModel` 持有的会话级
`DockerComposeRegistry` 中，Compose 子模型重建时复用同一 registry。普通刷新、
可用性重新探测或子模型重建都不会丢失手动项目；发现失败则继续展示 registry 中的
上一次成功快照并附错误。退出当前主机详情后可以释放；本期不新增数据库表或迁移。

## 领域与命令层

`ConnOps` 新增：

- `DockerComposeDialect`：v2 / v1 命令前缀；
- `DockerComposeProject`：项目名、状态、配置文件、project directory、来源；
- `DockerComposeService`：服务名、镜像、容器数、运行数、状态、端口；
- `DockerComposeParser`：解析 v2 项目 JSON、v1 容器标签和服务容器列表；
- `DockerCommand` Compose 构造器；
- `DockerService` Compose 探测、项目列表、服务列表、验证、写操作与日志流。

动态项目名、路径和服务名全部经 `ShellArgument.quote`，多 compose 文件按原顺序生成
多个 `-f` 参数。项目命令显式带 `--project-directory <目录>` 与 `-p <项目名>`，
避免工作目录变化导致相对路径、默认 `.env` 或 Compose 项目名漂移。

服务状态不依赖版本不一致的 `compose ps --format`。统一读取带项目标签的
`docker ps -a --format '{{json .}}'`，按 `com.docker.compose.service` 标签聚合；
再与 `config --services` 合并，因此没有容器的服务也能显示为已停止。

## App 状态与写操作

新增 `DockerComposeModel`，形状与现有四个资源模型一致，负责 dialect、项目列表、
项目服务详情、错误和刷新。会话级 `DockerComposeRegistry` 负责手动项目与最近一次
成功快照，生命周期由 `DockerViewModel` 持有；Compose 子模型在可用性传播时可安全
重建而不丢状态。

项目和服务状态统一为 `running`、`partial`、`stopped`、`unknown`：

- 至少有一个容器，且全部已存在容器都在 running 时为 running；
- 至少一个容器处于 running / restarting / paused，而另有非运行容器，或存在
  restarting / paused 容器时为 partial；
- 已知服务没有容器或没有活动容器时为 stopped；
- 没有足够信息判定时为 unknown。

v2 `compose ls` 的状态仅用于列表首次展示；加载服务后以上述容器聚合结果为准，v1
也使用同一规则。

Compose 写操作进入现有 `DockerOperationsModel` 的共享单槽 gate，不能与容器、镜像、
卷、网络写操作并行。新增脱敏审计类型：

- Compose 启动项目；
- Compose 停止项目；
- Compose 重启项目；
- Compose 重启服务。

审计只保存操作类型，不保存项目路径、服务名、完整命令或日志。得到明确退出码后刷新
Compose 和受影响的容器/镜像/网络/卷；连接中断或超时仍按「结果未知」处理，不自动
重试或声称成功。

`down` 会移除项目容器和网络，必须逐字输入项目名确认。命令固定不带 `--volumes`。
`up -d`、项目/服务 `restart` 不额外确认。

## 界面

Docker 内层分段变为：容器、镜像、卷、网络、Compose。Compose 列表沿用统一资源头：
左侧项目数量，右侧更多菜单；「手动添加项目」放在该菜单，不放导航栏加号。

项目卡片显示名称、运行状态、服务/容器摘要和配置文件。点击进入项目详情：

- 项目摘要：状态、工作目录、配置文件；
- 项目操作：启动、停止、重启、查看全部日志；
- 服务列表：名称、镜像、运行数/容器数、状态与端口；
- 服务操作：重启、查看该服务日志。

日志复用现有 `LogStreamView` 的暂停滚动、关键词过滤、5000 行环缓冲和错误样式，只
扩展 `LogSource` 以生成 Compose 日志命令。

## 错误处理

- Docker 可用但 Compose v1/v2 都不可用时，只在 Compose 分段显示安装提示，不影响
  其他四个 Docker 分段。
- 自动发现失败保留上一次列表并显示错误与重试入口。
- 手动路径验证失败时不加入列表，保留输入方便修正。
- 项目操作得到非零退出码时展示已知失败并刷新；未拿到最终退出结果时展示结果未知且
  不刷新。
- 单个项目的服务加载失败只影响该详情页，不清空全局项目列表。

## 测试与验收

1. `ConnOpsTests`：dialect 探测顺序、v2 项目解析、v1 标签归并、服务聚合、无容器
   服务、路径/项目名/服务名转义，以及所有命令的精确输出。
2. App 模型测试：自动与手动项目合并、刷新保留手动项目、Compose 不可用、详情错误
   保留旧数据、共享 gate、`down` 精确确认和脱敏审计。
3. UI 源码契约与编译：第五分段、统一列表头、无导航栏加号、项目/服务路由和日志源。
4. 只在用户已启动的 iPhone 17 Pro
   `DDACC334-4130-4FA3-AC0A-A28B62F71FC1` 上编译、安装与 UI 冒烟，不创建或克隆
   其他模拟器。

## 取舍

选择「v2 原生发现 + v1 标签回退 + 手动路径」：

- 只依赖 `compose ls`：实现最短，但 v1 和已停止项目不可用；
- 扫描服务器目录：能发现更多文件，但范围不确定、慢且越权；
- 当前方案：自动发现覆盖常见场景，手动路径补齐不可发现项目，并保持命令边界可审计。
