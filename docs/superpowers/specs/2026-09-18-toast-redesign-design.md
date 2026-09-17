# Conn Toast 重设计

日期：2026-09-18

## 目标

将全局 Toast 从当前的近似全宽胶囊调整为紧凑、扁平、有层次的状态卡片：宽度自适应且受最大宽度限制，正文使用 14pt 并支持换行，使用连续曲率圆角；仅成功、警告、错误状态显示图标，信息状态保持无图标。

## 设计决策

- 保留顶部单条浮层、自动消失、点击关闭、上滑关闭、后到消息替换前一条的既有交互。
- 根据当前主题反转背景：浅色主题使用接近黑色的半透明底，深色主题使用接近白色的半透明底；叠加非常轻微的上下渐变，不使用重阴影。
- 文案颜色与背景同步反转，保证反差背景上的可读性；状态色只保留给图标。
- 状态图标统一使用圆形 SF Symbols：成功 `checkmark.circle.fill`、警告 `exclamationmark.circle.fill`、错误 `xmark.circle.fill`；信息态不显示图标。
- 容器最大宽度为 320pt，受页面左右 16pt 安全边距约束；短消息按内容收缩，长消息在最大宽度内自然换行。
- 使用 14pt 正文级字体、12pt 水平内边距和 8pt 垂直内边距，圆角使用 16pt continuous 曲率。
- 短文案按内容宽度自适应并保持水平居中，长文案最多 320pt 后自然换行。
- 非 Reduce Motion 环境下从上方进入并淡入，关闭时向上离场并淡出；开启 Reduce Motion 时仅淡入淡出。
- `ConnToastStyle.info` 保留作为兼容现有调用方的无图标语义；其 `systemImageName` 改为可选值。
- 继续尊重 Dynamic Type、VoiceOver、Reduce Motion 和现有 accessibility identifier。

## 非目标

- 不引入 Toast 队列、撤销/重试按钮或新的服务端能力。
- 不修改调用方、数据库、终端交互或本地化资源。

## 验证

- `ConnToastTests` 验证三种状态图标、info 无图标、自动消失时序和新消息事件语义。
- `ConnUITests` 通过 DEBUG-only 的验收入口验证长文案实际渲染为紧凑多行卡片，且 App 保持前台运行。
- `ConnUITests` 额外验证短文案按内容收缩并保持水平居中。
- `swift test --package-path Packages/ConnPackages --filter ConnToastTests`
- `xcodebuild test ... -only-testing:ConnUITests/ConnUITests/testToastUsesCompactMultilineStatusCard`
- 在已启动的 iPhone 17 Pro 模拟器上构建并启动 App，检查 Toast 的宽度、圆角、14pt 文本和长文案换行；设备 UDID 以验收时 `simctl` 输出为准。
