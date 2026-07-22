import ConnKit
import Crypto
import Foundation
import Testing
@testable import ConnCrypto

@Suite("OpenSSHWire — wire 格式编解码")
struct OpenSSHWireTests {
    @Test("string 编码带 4 字节大端长度前缀")
    func stringLengthPrefix() {
        let encoded = OpenSSHWire.encodeString("abc")
        #expect(encoded == [0, 0, 0, 3, 0x61, 0x62, 0x63])
    }

    @Test("string 编解码往返")
    func stringRoundTrip() {
        let encoded = OpenSSHWire.encodeString("ssh-ed25519")
        let decoded = OpenSSHWire.decodeString(encoded, at: 0)
        #expect(decoded?.content == [UInt8]("ssh-ed25519".utf8))
        #expect(decoded?.next == encoded.count)
    }

    @Test("mpint 最高位为 1 时补前导 0")
    func mpintHighBit() {
        let encoded = OpenSSHWire.encodeMPInt([0x80, 0x01])
        // 0x80 最高位为 1，需补 0 → 长度 3
        #expect(encoded == [0, 0, 0, 3, 0x00, 0x80, 0x01])
    }

    @Test("mpint 去前导 0")
    func mpintStripsLeadingZeros() {
        let encoded = OpenSSHWire.encodeMPInt([0x00, 0x00, 0x42])
        #expect(encoded == [0, 0, 0, 1, 0x42])
    }
}

@Suite("SSHKeyGenerator — Ed25519 生成")
struct SSHKeyGeneratorTests {
    @Test("生成的公钥是 ssh-ed25519 authorized_keys 格式")
    func publicKeyFormat() {
        let key = SSHKeyGenerator.generateEd25519(comment: "test@conn")
        #expect(key.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        #expect(key.publicKeyOpenSSH.hasSuffix(" test@conn"))
        #expect(key.kind == .ed25519)
    }

    /// 解出公钥行里 base64 部分的 wire blob。
    private func blob(from key: GeneratedKey) throws -> [UInt8] {
        let base64 = key.publicKeyOpenSSH.split(separator: " ")[1]
        let data = try #require(Data(base64Encoded: String(base64)))
        return [UInt8](data)
    }

    @Test("公钥 blob 结构：string(ssh-ed25519) + string(32 字节公钥)")
    func publicKeyBlobStructure() throws {
        let blob = try blob(from: SSHKeyGenerator.generateEd25519())
        let first = try #require(OpenSSHWire.decodeString(blob, at: 0))
        #expect(first.content == [UInt8]("ssh-ed25519".utf8))
        let second = try #require(OpenSSHWire.decodeString(blob, at: first.next))
        #expect(second.content.count == 32) // ed25519 公钥 32 字节
    }

    @Test("公钥字节等于私钥派生的公钥")
    func publicKeyMatchesPrivate() throws {
        let key = SSHKeyGenerator.generateEd25519()
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key.privateKeyRaw)
        let expected = [UInt8](privateKey.publicKey.rawRepresentation)

        let blob = try blob(from: key)
        let first = try #require(OpenSSHWire.decodeString(blob, at: 0))
        let second = try #require(OpenSSHWire.decodeString(blob, at: first.next))
        #expect(second.content == expected)
    }

    @Test("指纹是 SHA256:base64 无 padding，与 blob 的 SHA256 一致")
    func fingerprintFormat() {
        let key = SSHKeyGenerator.generateEd25519()
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(!key.fingerprint.contains("="))
        // base64 部分应能解回 32 字节
        let base64 = String(key.fingerprint.dropFirst("SHA256:".count))
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        #expect(Data(base64Encoded: padded)?.count == 32)
    }

    @Test("私钥原始表示为 32 字节")
    func privateKeyRawIs32Bytes() {
        #expect(SSHKeyGenerator.generateEd25519().privateKeyRaw.count == 32)
    }

    @Test("从原始私钥恢复得到相同公钥与指纹")
    func recoversFromRaw() throws {
        let original = SSHKeyGenerator.generateEd25519(comment: "c")
        let recovered = try SSHKeyGenerator.ed25519(fromRawPrivateKey: original.privateKeyRaw, comment: "c")
        #expect(recovered.publicKeyOpenSSH == original.publicKeyOpenSSH)
        #expect(recovered.fingerprint == original.fingerprint)
    }

    @Test("每次生成的密钥不同")
    func generatesUniqueKeys() {
        let key1 = SSHKeyGenerator.generateEd25519()
        let key2 = SSHKeyGenerator.generateEd25519()
        #expect(key1.privateKeyRaw != key2.privateKeyRaw)
    }
}
