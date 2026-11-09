import ConnAnalytics

/// Pulse Analytics 客户端凭据。
///
/// 这些是**客户端共享凭据**，不是服务端私钥：SDK 必须把写入密钥和加密密钥随请求
/// 发送，任何安装包都能被逆向提取。异或混淆只避免明文出现在源码、字符串扫描结果和
/// 日志里，不提供安全保证。服务端必须把它们当作可滥用凭据：限流、可轮换，不能用于
/// 其他用途。
///
/// 生产值来自生产主机的 `pulse-server/deploy/.env`：
/// `PULSE_APP_ID`、`PULSE_WRITE_KEY`、`PULSE_ENCRYPTION_KEY`。
/// 注意：本机 `deploy/.env` 是本地开发凭据，与生产独立生成，不能用于生产端点。
///
/// 生成常量：`XORObfuscation.encode(value, key: obfuscationKey)`。
enum PulseAnalyticsCredentials {
    static let endpoint = "https://pulse.crazyball.cc/v1/events/batch"

    // 2026-11-09 从生产主机 `/workspace/pulse-server/deploy/.env` 读取并编码。
    // 轮换时同步更新服务端 PULSE_WRITE_KEY / PULSE_ENCRYPTION_KEY，再替换以下常量；
    // 留空时埋点整体禁用（fail closed）。
    private static let appIDEncoded = "Ki82KT8FOyoq"
    private static let writeKeyEncoded = "bTs5b2xvOTxsO21qam88P2g+bjhpOTlpOWlqOTw/azk+bDxpPj5vamNjYmJjbW9pbGM+bD5vOGJjOGpqOWI4aQ=="
    private static let encryptionKeyEncoded = "bmxqaD9iaW5qYj87aGk4OW1saj9raj5saz9uPGpiY2luam9rYztjbmlubGs7bm1iajs+OG85Ymppamg8PGlpYg=="
    private static let obfuscationKey: UInt8 = 0x5A

    static var appID: String? { decode(appIDEncoded) }
    static var writeKey: String? { decode(writeKeyEncoded) }

    /// SDK 要求 64 位十六进制字符串（32 字节密钥）。
    static var encryptionKeyHex: String? {
        guard let value = decode(encryptionKeyEncoded), value.count == 64 else { return nil }
        return value
    }

    private static func decode(_ value: String) -> String? {
        guard let decoded = XORObfuscation.decode(value, key: obfuscationKey),
              !decoded.isEmpty
        else {
            return nil
        }
        return decoded
    }
}
