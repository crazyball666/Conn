# Conn — 项目文档与交接说明

Conn 是一款**纯客户端** iOS 服务器连接管理与运维 App（SwiftUI，iOS 17+）：以 SSH 为核心，覆盖「连接 → 观测 → 处置」，无服务端、零上传、买断制。本目录是完整的产品与技术交接包。

## 文档地图（阅读顺序）

| # | 文档 | 内容 | 状态 |
|---|---|---|---|
| 1 | [docs/产品需求文档.md](docs/产品需求文档.md)（[HTML](docs/产品需求文档.html)） | PRD v1.3：市场调研、竞品逐项核实矩阵、10 模块功能设计（P0/P1/P2）、商业化、路线图 | ✅ 已评审定稿 |
| 2 | [docs/技术实现方案.md](docs/技术实现方案.md)（[HTML](docs/技术实现方案.html)） | v1.2：架构分层、SPM 结构、选型清单（含 **Citadel 风险框 R1–R6**）、GRDB 数据模型、模块实现细则、Spike 清单、测试策略、里程碑 | ✅ 待 Spike 回写 |
| 3 | [docs/设计规范.md](docs/设计规范.md)（[HTML](docs/设计规范.html)） | v1.3：**§0 裁决规则**、设计令牌（色彩/字体/布局）、组件规格、动效、可访问性、SwiftUI 落地约定 | ✅ |
| 4 | [docs/prototypes/index.html](docs/prototypes/index.html) | **21 屏全量**高保真原型 + 逐屏交互标注 + IA 流程图（含 iPad 三栏、Widget 三尺寸；**令牌与度量的真值来源**） | ✅ 全部出齐 |
| 5 | [docs/superpowers/plans/](docs/superpowers/plans/) | **实现计划**：v1.0 总路线图（P1–P11 分期）+ 各 Phase 的逐步骤实现计划 | 🔨 Phase 1a 已完成 |

## 当前进度（2026-07-19）

- **Phase 1a 工程地基已完成**：iOS 17.0 基线、`Conn.xcworkspace` + `Packages/ConnPackages` 单包多 target、ConnKit 领域模型、ConnStore GRDB schema v1。24 个单测在 macOS host 上 0.064s 跑完；App 已在 iOS 17.2 模拟器实机验证建库读写。
- **下一步**：Phase 1b（ConnUI 设计系统 + 5 Tab 导航壳 + 仪表盘）与 Spike S1（SSH 引擎选型）并行。
- 计划文件见 [docs/superpowers/plans/](docs/superpowers/plans/)。

**三条已定的立项决策**（与文档原文冲突处以此为准）：① 部署基线 iOS 17.0（已建工程原为 26.0）；② 单个本地 SPM 包 + 多 target（而非多个独立 package）；③ Swift 5 语言模式（SwiftTerm 在 Swift 6 严格模式下实测 523 个编译错误）。

## 给实现 Agent 的启动指令

1. **先读 PRD 的"硬约束"与技术方案文首的约束框**——不做服务端/告警/订阅/遥测，这些是产品红线，任何实现不得违反。
2. **技术方案 §2 的 Citadel 风险框（R1–R6）必读**：SSH 引擎的供应链与算法支持有三项严重限制，S1 已从「验证 Citadel」升级为「Citadel vs libssh2 选型决策」。
3. 开发节奏按技术方案 §9 周级里程碑；每模块完成需过对应「验收标准」checklist。
4. UI 实现以 `docs/prototypes/index.html` 为视觉验收基准，令牌/组件命名按设计规范 §9。
5. UI 落地参考 **ShipSwift**（MIT，github.com/signerlabs/ShipSwift）：按需复制组件进 `ConnUI/Vendor/`，禁用其认证/追踪模块；**注意 ShipSwift 面向 iOS 18+，复制组件必须适配 iOS 17 基线**。
6. 设计工作流技能（均已装在 `~/.claude/skills/`）：**ui-ux-pro-max**（设计系统与交付前检查）+ **Emil Kowalski 技能组**（apple-design / review-animations 等 6 个，动效工艺）——使用时机与冲突裁决顺序统一见设计规范 §10.2。
5. 工程约定（代码规范、分支、文案、隐私自查）见技术方案 §10。

## 文档维护

- md 为源文件；HTML 由 [Tooling/build_doc_html.py](Tooling/build_doc_html.py) 生成：`python3 build_doc_html.py <文件.md> <标题>`（依赖 `pip install markdown`，建议 venv）。
- 改动产品决策 → 先改 PRD 并升版本号，再同步技术方案；两者冲突以 PRD 为准。

## 关键已定决策（防止重新讨论）

纯客户端无服务端（不做告警推送）· 买断制（免费 + 国区 ¥98/美区 $19.99，绝不订阅）· Docker/日志中心为 P0 随 MVP 首发 · AI 走 BYOK · 不做竞品迁移向导 · 首发中文 + 英文 · 名称 Conn（上架前核实商标/重名）。决策依据与调研数据见 PRD 第 2 章与附录 12.1。
