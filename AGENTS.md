# Conn 项目协作约束

## 模拟器验收

- UI 验收只复用用户已经启动的那一台模拟器。
- 禁止 clone、启动、重启或关闭其他模拟器；不得为了验收创建新的模拟器实例。
- 用户已长期授权 Codex 直接操作本机 CoreSimulator。所有 `xcrun simctl`、面向模拟器的 `xcodebuild` 以及安装、启动、截图、日志采集和 UI 自动化命令，默认直接申请沙箱外执行权限，不得先在沙箱内执行后把权限隔离误判为 CoreSimulatorService 不可用。
- 沙箱内出现 `Operation not permitted`、`Connection invalid` 或 `Connection refused` 只表示当前执行环境无法访问 CoreSimulator，不构成设备或服务不可用；必须先在沙箱外对当前已启动设备复核。
- 运行 `xcodebuild test` 时只指定当前已启动设备的 UDID，并固定传入 `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`，禁止 Xcode 创建测试 Clone。仅当沙箱外访问仍确认 CoreSimulatorService 或该设备不可用时，才停止模拟器操作并报告，不得自行切换设备。
- 验收结束不接管或改变用户模拟器的生命周期。

## 开发完成标准

- 所有功能开发和缺陷修复必须同步新增或更新自动化单元测试，覆盖本次变更的核心正常路径与真实回归风险；没有对应测试不得宣称完成。
- 涉及页面、弹窗、导航、手势、键盘、终端交互或其他用户可见行为时，除单元测试外还必须新增或更新 XCUITest，真实操作 UI 验证端到端结果与 App 进程稳定性。
- 每次实现完成后，必须在用户当前已启动的模拟器上使用精确 UDID 执行相关单元测试和 UI 测试；仅编译成功、仅运行 macOS `swift test` 或仅人工阅读代码都不能替代模拟器验收。
- 测试失败、未执行或因环境受阻时必须明确说明，不得把功能标记为已完成；交付说明必须列出实际执行的测试命令、设备和结果。
