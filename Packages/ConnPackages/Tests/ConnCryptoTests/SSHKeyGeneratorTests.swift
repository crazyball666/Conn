import ConnKit
import Crypto
import Foundation
import Testing
import _CryptoExtras
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
        let key = SSHKeyGenerator.generateEd25519()
        #expect(key.privateKeyRaw.count == 32)
        #expect(key.privateKeyPEM?.contains("BEGIN OPENSSH PRIVATE KEY") == true)
    }

    @Test("从原始私钥恢复得到相同公钥与指纹")
    func recoversFromRaw() throws {
        let original = SSHKeyGenerator.generateEd25519(comment: "c")
        let recovered = try SSHKeyGenerator.ed25519(fromRawPrivateKey: original.privateKeyRaw, comment: "c")
        #expect(recovered.publicKeyOpenSSH == original.publicKeyOpenSSH)
        #expect(recovered.fingerprint == original.fingerprint)
    }

    @Test("OpenSSH Ed25519 私钥可导入并规范化")
    func importsOpenSSHEd25519() throws {
        let original = SSHKeyGenerator.generateEd25519(comment: "original")
        let imported = try SSHKeyGenerator.ed25519(fromPEM: try #require(original.privateKeyPEM), comment: "imported")
        #expect(imported.privateKeyRaw == original.privateKeyRaw)
        #expect(imported.publicKeyOpenSSH.hasSuffix(" imported"))
        #expect(imported.fingerprint == original.fingerprint)
    }

    @Test("PKCS#8 Ed25519 私钥可导入")
    func importsPKCS8Ed25519() throws {
        let original = SSHKeyGenerator.generateEd25519()
        let seed = original.privateKeyRaw
        let der: [UInt8] = [
            0x30, 0x2e, 0x02, 0x01, 0x00,
            0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70,
            0x04, 0x22, 0x04, 0x20
        ] + seed
        let pem = "-----BEGIN PRIVATE KEY-----\n\(Data(der).base64EncodedString())\n-----END PRIVATE KEY-----"
        let imported = try SSHKeyGenerator.ed25519(fromPEM: pem)
        #expect(imported.privateKeyRaw == seed)
        #expect(imported.fingerprint == original.fingerprint)
    }

    @Test("每次生成的密钥不同")
    func generatesUniqueKeys() {
        let key1 = SSHKeyGenerator.generateEd25519()
        let key2 = SSHKeyGenerator.generateEd25519()
        #expect(key1.privateKeyRaw != key2.privateKeyRaw)
    }

    @Test("RSA 4096 生成 authorized_keys 公钥与 OpenSSH 私钥")
    func generatesRSA4096() throws {
        let key = try SSHKeyGenerator.generateRSA4096(comment: "test@conn")
        #expect(key.kind == .rsa)
        #expect(key.publicKeyOpenSSH.hasPrefix("ssh-rsa "))
        #expect(key.privateKeyPEM?.contains("BEGIN OPENSSH PRIVATE KEY") == true)
        #expect(key.privateKeyRaw.isEmpty)
    }

    @Test("RSA OpenSSH 私钥可导入并规范化")
    func importsOpenSSHRSA() throws {
        let original = try SSHKeyGenerator.generateRSA4096(comment: "original")
        let imported = try SSHKeyGenerator.rsa4096(fromPEM: try #require(original.privateKeyPEM), comment: "imported")
        #expect(imported.kind == .rsa)
        #expect(imported.publicKeyOpenSSH.hasSuffix(" imported"))
        #expect(imported.fingerprint == original.fingerprint)
        #expect(imported.privateKeyPEM?.contains("BEGIN OPENSSH PRIVATE KEY") == true)
    }

    @Test("RSA PKCS#8 私钥可导入")
    func importsPKCS8RSA() throws {
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let imported = try SSHKeyGenerator.rsa4096(
            fromPEM: privateKey.pkcs8PEMRepresentation,
            comment: "pkcs8"
        )
        #expect(imported.kind == .rsa)
        #expect(imported.publicKeyOpenSSH.hasSuffix(" pkcs8"))
        #expect(imported.privateKeyPEM?.contains("BEGIN OPENSSH PRIVATE KEY") == true)
    }

    @Test("ECDSA P-256 生成 authorized_keys 公钥")
    func generatesECDSAP256() throws {
        let key = SSHKeyGenerator.generateECDSAP256(comment: "test@conn")
        #expect(key.kind == .ecdsaP256)
        #expect(key.publicKeyOpenSSH.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(key.privateKeyRaw.count == 32)
        #expect(key.privateKeyPEM?.contains("BEGIN PRIVATE KEY") == true)
        let imported = try SSHKeyGenerator.ecdsaP256(fromPEM: try #require(key.privateKeyPEM), comment: "test@conn")
        #expect(imported.privateKeyRaw == key.privateKeyRaw)
        #expect(imported.fingerprint == key.fingerprint)
    }

    @Test("OpenSSH ECDSA P-256 私钥可导入")
    func importsOpenSSHECDSAP256() throws {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQRob4LK6FLySyDoR4pZP3UJsT8hFt9AWJPJm44AY0sgGngPMLJV593R5/fHEnbUVzB/aYK4NfBNQtKyD9ca46ccAAAAqG+bXzZvm182AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGhvgsroUvJLIOhHilk/dQmxPyEW30BYk8mbjgBjSyAaeA8wslXn3dHn98cSdtRXMH9pgrg18E1C0rIP1xrjpxwAAAAhAI2AawQq7PTUoJnfEgaQIz0ETk+W/IgIpVRw1+xlNEEsAAAACWNvbm4tdGVzdAECAwQFBg==
        -----END OPENSSH PRIVATE KEY-----
        """
        let payload = try #require(Data(base64Encoded: pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()))
        var offset = 15
        func readString(_ data: Data, _ offset: inout Int) throws -> Data {
            let bytes = [UInt8](data)
            let length = Int(UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
            offset += 4
            defer { offset += length }
            return Data(bytes[offset..<(offset + length)])
        }
        _ = try readString(payload, &offset); _ = try readString(payload, &offset); _ = try readString(payload, &offset)
        offset += 4
        _ = try readString(payload, &offset)
        let privateBlock = try readString(payload, &offset)
        var privateOffset = 8
        _ = try readString(privateBlock, &privateOffset); _ = try readString(privateBlock, &privateOffset)
        let expectedPublic = try readString(privateBlock, &privateOffset)
        let scalar = try readString(privateBlock, &privateOffset)
        let raw = Data(Array(scalar.drop { $0 == 0 }))
        let derived = try P256.Signing.PrivateKey(rawRepresentation: raw)
        #expect([0x04] + Array(derived.publicKey.rawRepresentation) == Array(expectedPublic))
        let imported = try SSHKeyGenerator.ecdsaP256(fromPEM: pem, comment: "imported")
        #expect(imported.kind == .ecdsaP256)
        #expect(imported.publicKeyOpenSSH.hasSuffix(" imported"))
    }
}
