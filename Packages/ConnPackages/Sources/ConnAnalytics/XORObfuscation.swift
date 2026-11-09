import Foundation

/// 客户端常量异或混淆。
///
/// 这不是加密，也不能阻止逆向：密钥、算法和密文都在 App 内。它只避免密钥以
/// 明文形式出现在源码、字符串扫描结果和日志里。连接器和加密密钥本身必须按
/// “公开客户端凭据”对待，服务端要限流、可轮换，不能把它当作真正的秘密。
public enum XORObfuscation {
    public static func encode(_ value: String, key: UInt8) -> String {
        let bytes = value.utf8.map { $0 ^ key }
        return Data(bytes).base64EncodedString()
    }

    public static func decode(_ encoded: String, key: UInt8) -> String? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let bytes = data.map { $0 ^ key }
        return String(bytes: bytes, encoding: .utf8)
    }
}
