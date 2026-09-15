# 主机高级连接设置重做

目标：保留直连、嵌入式 Tailscale / Headscale、HTTP CONNECT / SOCKS5 与多级跳板能力，移除混杂展开和隐式选项。无备用地址，不修改数据库 schema 或传输协议。

设计依据：[Apple 分层列表](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)、[Termius 主机链与代理分组](https://www.termius.com/blog/prepare-to-work-from-home)。采用信息架构，不复制特定版本的外观；视觉遵循 Conn 原生分组表单规范。

1. 主机页高级设置仅有网络连接、跳板机两个带摘要的导航入口。
2. 网络连接分为直连、私有网络、代理；仅显示所选方式的字段。返回保留草稿，主机保存时提交；切换方式保留未提交的配置和凭据输入。
3. 私有网络显式选择可复用配置；新增、编辑操作名称与行为一致。配置编辑器使用持久标签，只有 Headscale 显示控制端点；共享配置独立保存，页面明确说明。
4. 跳板机不提供开关或自动选首项。空链显示“选择跳板机”，非空链显示“添加下一跳”；显式选择、删除、排序。
5. 先运行新版入口 UI 测试确认旧实现失败，再实现与补齐草稿状态单元测试、五语本地化，在当前授权 iPhone 上验证 UI、草稿往返和既有 Headscale 连接。

验收不重建数据库、不写入真实测试凭据、不清理现有节点、不提交或 push。
