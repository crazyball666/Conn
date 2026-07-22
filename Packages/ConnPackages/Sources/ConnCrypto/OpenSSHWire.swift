import Foundation

/// SSH wire 格式编解码原语（RFC 4251 §5）。
///
/// OpenSSH 的公钥 blob 由一串 `string`（4 字节大端长度前缀 + 字节）拼成。
/// 例如 ed25519 公钥 = string("ssh-ed25519") + string(32 字节公钥)。
enum OpenSSHWire {
    /// 编码一个 `string`：4 字节大端长度 + 内容。
    static func encodeString(_ bytes: [UInt8]) -> [UInt8] {
        let length = UInt32(bytes.count)
        return lengthPrefix(length) + bytes
    }

    static func encodeString(_ string: String) -> [UInt8] {
        encodeString([UInt8](string.utf8))
    }

    /// 编码 `mpint`（多精度整数，RSA 的 e/n 用）：若最高位为 1 需补一个前导 0。
    static func encodeMPInt(_ bytes: [UInt8]) -> [UInt8] {
        var trimmed = bytes
        while trimmed.first == 0 {
            trimmed.removeFirst()
        } // 去前导 0
        if let first = trimmed.first, first & 0x80 != 0 {
            trimmed.insert(0, at: 0) // 最高位为 1，补 0 以表正数
        }
        return encodeString(trimmed)
    }

    private static func lengthPrefix(_ length: UInt32) -> [UInt8] {
        [
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ]
    }

    /// 从字节流按 `string` 解码，返回内容与消费的字节数。
    static func decodeString(_ bytes: [UInt8], at offset: Int) -> (content: [UInt8], next: Int)? {
        guard offset + 4 <= bytes.count else { return nil }
        let length = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        let start = offset + 4
        let end = start + Int(length)
        guard end <= bytes.count else { return nil }
        return (Array(bytes[start ..< end]), end)
    }
}
