import Foundation

/// TOFU（Trust On First Use）主机指纹记录。
///
/// 首次连接时入库；后续连接指纹不符则全屏红色警告并**默认阻断**，
/// 需用户输入主机名确认才可覆盖（技术实现方案 §4.1）。这个摩擦是刻意的，
/// 用于防降级攻击。
public struct KnownHost: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    /// 匹配模式，形如 `example.com:22`。
    public var hostPattern: String
    /// 主机密钥算法，如 `ssh-ed25519`。
    public var keyType: String
    /// SHA256 指纹（base64，不含 `SHA256:` 前缀）。
    public var fingerprint: String
    public let firstSeen: Int64

    public init(
        id: String = UUID().uuidString,
        hostPattern: String,
        keyType: String,
        fingerprint: String,
        firstSeen: Int64 = Timestamp.now()
    ) {
        self.id = id
        self.hostPattern = hostPattern
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.firstSeen = firstSeen
    }

    /// 供 UI 展示的完整指纹，形如 `SHA256:abc...`。
    public var displayFingerprint: String { "SHA256:\(fingerprint)" }
}
