# Conn Phase 6 实现计划：SFTP 文件管理

> 内联执行，交付「可编译 + host 单测 + 接入 UI」纵向切片，单独提交。

**目标**：手机上浏览远端目录、上传/下载、在线编辑配置文件（方案 §4.5 / PRD §5.3）。

**架构**：SFTP 抽象放 ConnSSH（与 exec/shell 同层的传输能力）：`RemoteFileSystem` 协议 +
`FileEntry` 模型 + `RemoteFile` 句柄（offset 读写，支持断点续传）。Citadel 适配在
ConnSSHCitadel（包 `SFTPClient`）；Mock 适配在 ConnSSH（内存文件树，供演示/测试）。
浏览器/传输/编辑器在 App 层。

## 全局约束

- 沿用既有分层：ConnSSH 不依赖 Citadel；协议在 ConnSSH，引擎实现在 ConnSSHCitadel。
- 避免 `!`；文件 ≤500 行；行宽 ≤140；颜色走令牌；SwiftLint 0。

## 取舍（明确记录）

1. **在线编辑用 monospace `TextEditor`**，不引 Runestone（语法高亮是 PRD P1）。
2. **编辑体积上限 1MB**：更大文件走只读预览（大文件 tail 查看是 PRD P1，顺延）。
   保存 = 以「打开既有文件 + 截断写入」保持同一 inode → 权限/属主不变（满足验收）；
   temp+原子 mv 的更强变体顺延。
3. **断点续传**：下载用 `.connpart` 临时名 + offset 续写，完成原子 rename；
   会话内 pause/resume + 重启后若 `.connpart` 存在则从其大小续传。**完整传输队列
   跨重启持久化 + 后台 30s 收尾**顺延（1GB 杀 App 续传验收部分满足）。
4. **Files App File Provider 扩展**：v1.1（独立 extension target），本期不做。

## 文件

- ConnSSH：`FileSystem.swift`（`RemoteFileSystem`/`RemoteFile`/`FileEntry`/`FileKind`/
  权限串 + 路径工具）；`SSHTransport.swift` 加 `sftp()` 到 `SSHSession`；
  `Mock/MockRemoteFileSystem.swift`（内存树）；`MockSSHTransport.swift` 实现 `sftp()`。
- ConnSSHCitadel：`CitadelFileSystem.swift`（包 SFTPClient）；`CitadelSession.sftp()`。
- 测试：`ConnSSHTests/FileSystemTests.swift`（权限串/路径/kind 判定 + MockRemoteFileSystem CRUD）。
- App：`Files/FileBrowserViewModel.swift`、`Files/FileBrowserView.swift`、
  `Files/FileEditorView.swift`、`Files/FileTransferViewModel.swift`；
  `HostDetailView` 文件段接入；`Demo/DemoData` 文件树。

## 验收（方案 §4.5 / PRD §5.3）

- [ ] 浏览目录：导航/上级/隐藏文件开关；显示大小/权限/时间/类型。
- [ ] 下载（chunked + 进度）+ 上传（系统文件选择器 + 进度）。
- [ ] 编辑 `/etc/nginx/nginx.conf` 保存后权限/属主不变。
- [ ] 新建文件夹 / 重命名 / 删除（强确认）/ chmod。
- [ ] 断点续传：下载中断后重启可从 `.connpart` 续传（会话内 + 重启）。
- [ ] host 单测覆盖权限串/路径工具/Mock 文件系统 CRUD。
