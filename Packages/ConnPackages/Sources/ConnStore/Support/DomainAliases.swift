import ConnKit

/// 领域模型 `Host` 的无歧义别名。
///
/// macOS 的 Foundation 导出了已废弃的 `NSHost`（Swift 名 `Host`），与本项目
/// 的领域模型同名。iOS 上 `NSHost` 标记为 `API_UNAVAILABLE` 故无冲突，但本包
/// 声明了 macOS 平台以支持 Domain/Infra 层在 host 端跑 `swift test`，
/// 因此凡同时 `import Foundation` 与 `import ConnKit` 的文件都需显式消歧。
///
/// 用法：ConnStore 内部一律用 `DomainHost` 代替 `Host`。
typealias DomainHost = ConnKit.Host
