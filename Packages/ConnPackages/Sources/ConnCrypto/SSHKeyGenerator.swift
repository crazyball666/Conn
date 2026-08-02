import ConnKit
import Crypto
import Foundation
import _CryptoExtras

/// 一把新生成或已加载的密钥对。
public struct GeneratedKey: Sendable {
    public let kind: SSHKey.Kind
    /// OpenSSH `authorized_keys` 格式公钥（`ssh-ed25519 AAAA... comment`）。
    public let publicKeyOpenSSH: String
    /// SHA256 指纹（`SHA256:base64...`，无 padding），与 `ssh-keygen -lf` 一致。
    public let fingerprint: String
    /// 私钥的原始表示（ed25519 为 32 字节）。存 Keychain，连接时构造签名密钥。
    public let privateKeyRaw: Data
    /// RSA 等没有固定 rawRepresentation 的密钥使用未加密 PEM。
    public let privateKeyPEM: String?

    public init(
        kind: SSHKey.Kind,
        publicKeyOpenSSH: String,
        fingerprint: String,
        privateKeyRaw: Data,
        privateKeyPEM: String? = nil
    ) {
        self.kind = kind
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprint = fingerprint
        self.privateKeyRaw = privateKeyRaw
        self.privateKeyPEM = privateKeyPEM
    }

    public var keychainMaterial: String {
        privateKeyPEM ?? privateKeyRaw.base64EncodedString()
    }
}

/// 密钥生成器（技术方案 §4.7）。
///
/// 软件密钥生成器。私钥材料只返回给上层写入 Keychain。
public enum SSHKeyGenerator {
    /// 生成一把 Ed25519 密钥。
    ///
    /// - Parameter comment: 公钥尾部注释，通常 `conn@设备名` 或用户命名。
    public static func generateEd25519(comment: String = "conn") -> GeneratedKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyBytes = [UInt8](privateKey.publicKey.rawRepresentation)

        let blob = ed25519PublicKeyBlob(publicKeyBytes)
        let base64 = Data(blob).base64EncodedString()
        let publicKeyLine = "ssh-ed25519 \(base64) \(comment)"

        return GeneratedKey(
            kind: .ed25519,
            publicKeyOpenSSH: publicKeyLine,
            fingerprint: Self.fingerprint(ofBlob: blob),
            privateKeyRaw: privateKey.rawRepresentation,
            privateKeyPEM: OpenSSHPrivateKeyCodec.encodeEd25519(
                privateKey: privateKey.rawRepresentation,
                publicKey: privateKey.publicKey.rawRepresentation,
                comment: comment
            )
        )
    }

    /// 生成 RSA 4096 密钥，使用未加密 OpenSSH PEM 保存。
    public static func generateRSA4096(comment: String = "conn") throws -> GeneratedKey {
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits4096)
        let primitives = try privateKey.publicKey.getKeyPrimitives()
        let blob = OpenSSHWire.encodeString("ssh-rsa")
            + OpenSSHWire.encodeMPInt([UInt8](primitives.publicExponent))
            + OpenSSHWire.encodeMPInt([UInt8](primitives.modulus))
        let publicKey = "ssh-rsa \(Data(blob).base64EncodedString()) \(comment)"
        return GeneratedKey(
            kind: .rsa,
            publicKeyOpenSSH: publicKey,
            fingerprint: Self.fingerprint(ofBlob: blob),
            privateKeyRaw: Data(),
            privateKeyPEM: try OpenSSHPrivateKeyCodec.encodeRSA(
                pkcs1DER: privateKey.derRepresentation,
                comment: comment
            )
        )
    }

    public static func rsa4096(fromPEM pem: String, comment: String = "conn") throws -> GeneratedKey {
        let privateKey = try OpenSSHPrivateKeyCodec.rsaPrivateKey(fromPEM: pem)
        let primitives = try privateKey.publicKey.getKeyPrimitives()
        let blob = OpenSSHWire.encodeString("ssh-rsa")
            + OpenSSHWire.encodeMPInt([UInt8](primitives.publicExponent))
            + OpenSSHWire.encodeMPInt([UInt8](primitives.modulus))
        return GeneratedKey(
            kind: .rsa,
            publicKeyOpenSSH: "ssh-rsa \(Data(blob).base64EncodedString()) \(comment)",
            fingerprint: Self.fingerprint(ofBlob: blob),
            privateKeyRaw: Data(),
            privateKeyPEM: try OpenSSHPrivateKeyCodec.encodeRSA(
                pkcs1DER: privateKey.derRepresentation,
                comment: comment
            )
        )
    }

    /// 生成 ECDSA P-256 密钥。
    public static func generateECDSAP256(comment: String = "conn") -> GeneratedKey {
        let privateKey = P256.Signing.PrivateKey()
        let blob = OpenSSHWire.encodeString("ecdsa-sha2-nistp256")
            + OpenSSHWire.encodeString("nistp256")
            + OpenSSHWire.encodeString(ecdsaPublicKeyBytes(privateKey))
        let publicKey = "ecdsa-sha2-nistp256 \(Data(blob).base64EncodedString()) \(comment)"
        return GeneratedKey(
            kind: .ecdsaP256,
            publicKeyOpenSSH: publicKey,
            fingerprint: Self.fingerprint(ofBlob: blob),
            privateKeyRaw: privateKey.rawRepresentation,
            privateKeyPEM: privateKey.pemRepresentation
        )
    }

    public static func ecdsaP256(fromRawPrivateKey raw: Data, comment: String = "conn") throws -> GeneratedKey {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: raw)
        let blob = OpenSSHWire.encodeString("ecdsa-sha2-nistp256")
            + OpenSSHWire.encodeString("nistp256")
            + OpenSSHWire.encodeString(ecdsaPublicKeyBytes(privateKey))
        return GeneratedKey(
            kind: .ecdsaP256,
            publicKeyOpenSSH: "ecdsa-sha2-nistp256 \(Data(blob).base64EncodedString()) \(comment)",
            fingerprint: Self.fingerprint(ofBlob: blob),
            privateKeyRaw: privateKey.rawRepresentation,
            privateKeyPEM: privateKey.pemRepresentation
        )
    }

    /// 从未加密 PKCS#8 PEM ECDSA 私钥导入。
    public static func ecdsaP256(fromPEM pem: String, comment: String = "conn") throws -> GeneratedKey {
        let privateKey = try OpenSSHPrivateKeyCodec.ecdsaP256PrivateKey(fromPEM: pem)
        return try ecdsaP256(fromRawPrivateKey: privateKey.rawRepresentation, comment: comment)
    }

    /// 从未加密 OpenSSH 或 PKCS#8 PEM 导入 Ed25519 私钥。
    public static func ed25519(fromPEM pem: String, comment: String = "conn") throws -> GeneratedKey {
        let raw = try OpenSSHPrivateKeyCodec.ed25519PrivateKey(fromPEM: pem)
        return try ed25519(fromRawPrivateKey: raw, comment: comment)
    }

    /// 从存储的原始私钥恢复公钥信息（如展示、重新部署）。
    public static func ed25519(fromRawPrivateKey raw: Data, comment: String = "conn") throws -> GeneratedKey {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        let publicKeyBytes = [UInt8](privateKey.publicKey.rawRepresentation)
        let blob = ed25519PublicKeyBlob(publicKeyBytes)
        let base64 = Data(blob).base64EncodedString()
        return GeneratedKey(
            kind: .ed25519,
            publicKeyOpenSSH: "ssh-ed25519 \(base64) \(comment)",
            fingerprint: Self.fingerprint(ofBlob: blob),
            privateKeyRaw: raw,
            privateKeyPEM: OpenSSHPrivateKeyCodec.encodeEd25519(
                privateKey: raw,
                publicKey: privateKey.publicKey.rawRepresentation,
                comment: comment
            )
        )
    }


    /// ed25519 公钥 wire blob：string("ssh-ed25519") + string(32 字节公钥)。
    static func ed25519PublicKeyBlob(_ publicKeyBytes: [UInt8]) -> [UInt8] {
        OpenSSHWire.encodeString("ssh-ed25519") + OpenSSHWire.encodeString(publicKeyBytes)
    }

    private static func ecdsaPublicKeyBytes(_ privateKey: P256.Signing.PrivateKey) -> [UInt8] {
        [0x04] + [UInt8](privateKey.publicKey.rawRepresentation)
    }

    /// 计算公钥 blob 的 SHA256 指纹（`SHA256:base64`，去 padding）。
    static func fingerprint(ofBlob blob: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(blob))
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }
}

/// 无第三方依赖的 Ed25519 OpenSSH 私钥编解码。
///
/// 只接受 `ciphername=none`、`kdfname=none` 的未加密 OpenSSH 私钥；带密码短语的
/// 私钥不会被尝试解密，也不会落入 Keychain。PKCS#8 只读取 RFC 8410 的 Ed25519
/// `PrivateKeyInfo` 结构中的 32 字节种子。
private enum OpenSSHPrivateKeyCodec {
    private static let magic = Array("openssh-key-v1\0".utf8)

    static func encodeEd25519(privateKey: Data, publicKey: Data, comment: String) -> String {
        var privateBlock = Data()
        var rng = SystemRandomNumberGenerator()
        let check = UInt32.random(in: UInt32.min...UInt32.max, using: &rng)
        privateBlock.append(contentsOf: encodeUInt32(check))
        privateBlock.append(contentsOf: encodeUInt32(check))
        privateBlock.append(contentsOf: OpenSSHWire.encodeString("ssh-ed25519"))
        privateBlock.append(contentsOf: OpenSSHWire.encodeString([UInt8](publicKey)))
        privateBlock.append(contentsOf: OpenSSHWire.encodeString([UInt8](privateKey) + [UInt8](publicKey)))
        privateBlock.append(contentsOf: OpenSSHWire.encodeString(comment))
        let paddingCount = (8 - (privateBlock.count % 8)) % 8
        if paddingCount > 0 {
            privateBlock.append(contentsOf: (1...paddingCount).map(UInt8.init))
        }

        var payload = Data(magic)
        payload.append(contentsOf: OpenSSHWire.encodeString("none"))
        payload.append(contentsOf: OpenSSHWire.encodeString("none"))
        payload.append(contentsOf: OpenSSHWire.encodeString([]))
        payload.append(contentsOf: encodeUInt32(1))
        let publicBlob = Data(SSHKeyGenerator.ed25519PublicKeyBlob([UInt8](publicKey)))
        payload.append(contentsOf: OpenSSHWire.encodeString([UInt8](publicBlob)))
        payload.append(contentsOf: OpenSSHWire.encodeString([UInt8](privateBlock)))

        let base64 = payload.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { start in
            let begin = base64.index(base64.startIndex, offsetBy: start)
            let end = base64.index(begin, offsetBy: min(70, base64.distance(from: begin, to: base64.endIndex)))
            return String(base64[begin..<end])
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(lines.joined(separator: "\n"))\n-----END OPENSSH PRIVATE KEY-----"
    }

    static func ed25519PrivateKey(fromPEM pem: String) throws -> Data {
        let (label, der) = try pemDER(pem)
        if label == "OPENSSH PRIVATE KEY" {
            return try parseOpenSSHEd25519(der)
        }
        guard label == "PRIVATE KEY" else { throw CredentialError.encoding }
        return try parsePKCS8Ed25519(der)
    }

    /// 把 RSA 的 PKCS#1/PKCS#8 或 OpenSSH 私钥统一转为 PKCS#1 DER。
    /// 统一入口让上层既能导入传统 `id_rsa`，也能导入新 OpenSSH 格式。
    static func rsaPKCS1DER(fromPEM pem: String) throws -> Data {
        let (label, der) = try pemDER(pem)
        switch label {
        case "OPENSSH PRIVATE KEY":
            let components = try parseOpenSSHRSA(der)
            return try encodePKCS1RSA(
                n: components.n,
                e: components.e,
                d: components.d,
                p: components.p,
                q: components.q,
                qi: components.qi
            )
        case "RSA PRIVATE KEY":
            return der
        case "PRIVATE KEY":
            return try parsePKCS8RSA(der)
        default:
            throw CredentialError.encoding
        }
    }

    static func rsaPrivateKey(fromPEM pem: String) throws -> _RSA.Signing.PrivateKey {
        let (label, der) = try pemDER(pem)
        if label == "OPENSSH PRIVATE KEY" {
            let components = try parseOpenSSHRSA(der)
            return try _RSA.Signing.PrivateKey(
                n: normalized(components.n),
                e: normalized(components.e),
                d: normalized(components.d),
                p: normalized(components.p),
                q: normalized(components.q)
            )
        }
        return try _RSA.Signing.PrivateKey(derRepresentation: rsaPKCS1DER(fromPEM: pem))
    }

    static func ecdsaP256PrivateKey(fromPEM pem: String) throws -> P256.Signing.PrivateKey {
        let (label, der) = try pemDER(pem)
        if label == "OPENSSH PRIVATE KEY" {
            return try parseOpenSSHECDSAP256(der)
        }
        guard label == "EC PRIVATE KEY" || label == "PRIVATE KEY" else {
            throw CredentialError.encoding
        }
        return try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    /// 生成 Citadel 可直接消费的未加密 OpenSSH RSA 私钥。
    static func encodeRSA(pkcs1DER: Data, comment: String) throws -> String {
        let components = try parsePKCS1RSA(pkcs1DER)
        let publicBlob = OpenSSHWire.encodeString("ssh-rsa")
            + OpenSSHWire.encodeMPInt(components.e)
            + OpenSSHWire.encodeMPInt(components.n)

        var privateBlock = Data()
        var rng = SystemRandomNumberGenerator()
        let check = UInt32.random(in: UInt32.min...UInt32.max, using: &rng)
        privateBlock.append(contentsOf: encodeUInt32(check))
        privateBlock.append(contentsOf: encodeUInt32(check))
        privateBlock.append(contentsOf: OpenSSHWire.encodeString("ssh-rsa"))
        privateBlock.append(contentsOf: OpenSSHWire.encodeMPInt(components.n))
        privateBlock.append(contentsOf: OpenSSHWire.encodeMPInt(components.e))
        privateBlock.append(contentsOf: OpenSSHWire.encodeMPInt(components.d))
        privateBlock.append(contentsOf: OpenSSHWire.encodeMPInt(components.qi))
        privateBlock.append(contentsOf: OpenSSHWire.encodeMPInt(components.p))
        privateBlock.append(contentsOf: OpenSSHWire.encodeMPInt(components.q))
        privateBlock.append(contentsOf: OpenSSHWire.encodeString(comment))
        let paddingCount = (8 - (privateBlock.count % 8)) % 8
        if paddingCount > 0 {
            privateBlock.append(contentsOf: (1...paddingCount).map(UInt8.init))
        }

        var payload = Data(magic)
        payload.append(contentsOf: OpenSSHWire.encodeString("none"))
        payload.append(contentsOf: OpenSSHWire.encodeString("none"))
        payload.append(contentsOf: OpenSSHWire.encodeString([]))
        payload.append(contentsOf: encodeUInt32(1))
        payload.append(contentsOf: OpenSSHWire.encodeString(publicBlob))
        payload.append(contentsOf: OpenSSHWire.encodeString([UInt8](privateBlock)))
        return pem(label: "OPENSSH PRIVATE KEY", data: payload)
    }

    private static func pemDER(_ pem: String) throws -> (String, Data) {
        let lines = pem.components(separatedBy: .newlines)
        guard let begin = lines.first(where: { $0.hasPrefix("-----BEGIN ") }),
              let end = lines.first(where: { $0.hasPrefix("-----END ") }) else {
            throw CredentialError.encoding
        }
        let label = begin.replacingOccurrences(of: "-----BEGIN ", with: "").replacingOccurrences(of: "-----", with: "")
        let base64 = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: base64) else { throw CredentialError.encoding }
        let expectedEnd = "-----END \(label)-----"
        guard end == expectedEnd else { throw CredentialError.encoding }
        return (label, data)
    }

    private static func parseOpenSSHEd25519(_ data: Data) throws -> Data {
        var reader = WireReader(bytes: [UInt8](data))
        guard reader.readBytes(count: magic.count) == magic else { throw CredentialError.encoding }
        let cipher = String(bytes: try reader.readString(), encoding: .utf8)
        let kdf = String(bytes: try reader.readString(), encoding: .utf8)
        guard cipher != nil, kdf != nil else { throw CredentialError.encoding }
        guard cipher == "none", kdf == "none" else {
            throw CredentialError.encryptedPrivateKey
        }
        _ = try reader.readString() // empty KDF options
        guard try reader.readUInt32() == 1 else { throw CredentialError.encoding }
        _ = try reader.readString() // public key blob
        let privateBlock = try reader.readString()

        var privateReader = WireReader(bytes: privateBlock)
        let check0 = try privateReader.readUInt32()
        let check1 = try privateReader.readUInt32()
        let keyType = try privateReader.readString()
        guard check0 == check1,
              String(bytes: keyType, encoding: .utf8) == "ssh-ed25519" else {
            throw CredentialError.encoding
        }
        let publicKey = try privateReader.readString()
        let privateKey = try privateReader.readString()
        _ = try privateReader.readString() // comment
        guard publicKey.count == 32, privateKey.count == 64,
              Array(privateKey.suffix(32)) == publicKey else {
            throw CredentialError.encoding
        }
        let raw = Data(privateKey.prefix(32))
        let derived = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        guard Data(derived.publicKey.rawRepresentation) == Data(publicKey) else {
            throw CredentialError.encoding
        }
        return raw
    }

    private static func parseOpenSSHRSA(_ data: Data) throws -> RSAComponents {
        var reader = WireReader(bytes: [UInt8](data))
        guard reader.readBytes(count: magic.count) == magic else { throw CredentialError.encoding }
        let cipher = String(bytes: try reader.readString(), encoding: .utf8)
        let kdf = String(bytes: try reader.readString(), encoding: .utf8)
        guard cipher != nil, kdf != nil else { throw CredentialError.encoding }
        guard cipher == "none", kdf == "none" else {
            throw CredentialError.encryptedPrivateKey
        }
        _ = try reader.readString()
        guard try reader.readUInt32() == 1 else { throw CredentialError.encoding }
        var publicReader = WireReader(bytes: try reader.readString())
        guard String(bytes: try publicReader.readString(), encoding: .utf8) == "ssh-rsa" else {
            throw CredentialError.encoding
        }
        _ = try publicReader.readString()
        _ = try publicReader.readString()

        var privateReader = WireReader(bytes: try reader.readString())
        let check0 = try privateReader.readUInt32()
        let check1 = try privateReader.readUInt32()
        guard check0 == check1,
              String(bytes: try privateReader.readString(), encoding: .utf8) == "ssh-rsa" else {
            throw CredentialError.encoding
        }
        let n = try privateReader.readString()
        let e = try privateReader.readString()
        let d = try privateReader.readString()
        let qi = try privateReader.readString()
        let p = try privateReader.readString()
        let q = try privateReader.readString()
        _ = try privateReader.readString() // comment
        return RSAComponents(n: n, e: e, d: d, p: p, q: q, qi: qi)
    }

    private static func parseOpenSSHECDSAP256(_ data: Data) throws -> P256.Signing.PrivateKey {
        var reader = WireReader(bytes: [UInt8](data))
        guard reader.readBytes(count: magic.count) == magic else { throw CredentialError.encoding }
        let cipher = String(bytes: try reader.readString(), encoding: .utf8)
        let kdf = String(bytes: try reader.readString(), encoding: .utf8)
        guard cipher != nil, kdf != nil else { throw CredentialError.encoding }
        guard cipher == "none", kdf == "none" else { throw CredentialError.encryptedPrivateKey }
        _ = try reader.readString()
        guard try reader.readUInt32() == 1 else { throw CredentialError.encoding }

        var publicReader = WireReader(bytes: try reader.readString())
        guard String(bytes: try publicReader.readString(), encoding: .utf8) == "ecdsa-sha2-nistp256",
              String(bytes: try publicReader.readString(), encoding: .utf8) == "nistp256" else {
            throw CredentialError.encoding
        }
        let publicKey = try publicReader.readString()
        guard publicKey.count == 65, publicKey.first == 0x04 else { throw CredentialError.encoding }
        let privateBlock = try reader.readString()
        var privateReader = WireReader(bytes: privateBlock)
        let check0 = try privateReader.readUInt32()
        let check1 = try privateReader.readUInt32()
        guard check0 == check1,
              String(bytes: try privateReader.readString(), encoding: .utf8) == "ecdsa-sha2-nistp256",
              String(bytes: try privateReader.readString(), encoding: .utf8) == "nistp256" else {
            throw CredentialError.encoding
        }
        let privatePublicKey = try privateReader.readString()
        let scalar = try privateReader.readString()
        _ = try privateReader.readString() // comment
        guard privatePublicKey == publicKey else { throw CredentialError.encoding }
        let raw = Array(scalar.drop { $0 == 0 })
        guard raw.count == 32 else { throw CredentialError.encoding }
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(raw))
        guard [0x04] + [UInt8](privateKey.publicKey.rawRepresentation) == publicKey else {
            throw CredentialError.encoding
        }
        return privateKey
    }

    private static func parsePKCS8RSA(_ data: Data) throws -> Data {
        var outer = DERReader(bytes: [UInt8](data))
        let body = try outer.read(tag: 0x30)
        guard outer.isAtEnd else { throw CredentialError.encoding }
        var sequence = DERReader(bytes: body)
        _ = try sequence.read(tag: 0x02) // version
        var algorithm = DERReader(bytes: try sequence.read(tag: 0x30))
        guard try algorithm.read(tag: 0x06) == [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01] else {
            throw CredentialError.encoding
        }
        if !algorithm.isAtEnd { _ = try algorithm.read(tag: 0x05) }
        let privateKey = try sequence.read(tag: 0x04)
        guard sequence.isAtEnd else { throw CredentialError.encoding }
        return Data(privateKey)
    }

    private static func parsePKCS1RSA(_ data: Data) throws -> RSAComponents {
        var sequence = DERReader(bytes: [UInt8](data))
        let body = try sequence.read(tag: 0x30)
        guard sequence.isAtEnd else { throw CredentialError.encoding }
        var values = DERReader(bytes: body)
        _ = try values.read(tag: 0x02) // version
        let n = try values.read(tag: 0x02)
        let e = try values.read(tag: 0x02)
        let d = try values.read(tag: 0x02)
        let p = try values.read(tag: 0x02)
        let q = try values.read(tag: 0x02)
        _ = try values.read(tag: 0x02) // d mod (p - 1)
        _ = try values.read(tag: 0x02) // d mod (q - 1)
        let qi = try values.read(tag: 0x02)
        guard values.isAtEnd else { throw CredentialError.encoding }
        return RSAComponents(n: n, e: e, d: d, p: p, q: q, qi: qi)
    }

    private static func encodePKCS1RSA(n: [UInt8], e: [UInt8], d: [UInt8], p: [UInt8], q: [UInt8], qi: [UInt8]) throws -> Data {
        let body = derInteger([0])
            + derInteger(n)
            + derInteger(e)
            + derInteger(d)
            + derInteger(p)
            + derInteger(q)
            + derInteger([0])
            + derInteger([0])
            + derInteger(qi)
        return Data(der(tag: 0x30, body: body))
    }

    private static func normalized(_ bytes: [UInt8]) -> Data {
        let trimmed = Array(bytes.drop { $0 == 0 })
        return Data(trimmed.isEmpty ? [0] : trimmed)
    }

    private static func derInteger(_ bytes: [UInt8]) -> [UInt8] {
        var value = bytes.drop { $0 == 0 }
        if value.isEmpty { value = [0] }
        var normalized = Array(value)
        if normalized[0] & 0x80 != 0 { normalized.insert(0, at: 0) }
        return der(tag: 0x02, body: normalized)
    }

    private static func der(tag: UInt8, body: [UInt8]) -> [UInt8] {
        [tag] + derLength(body.count) + body
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        guard length >= 0 else { return [] }
        if length < 0x80 { return [UInt8(length)] }
        let bytes = withUnsafeBytes(of: UInt32(length).bigEndian) { Array($0) }.drop { $0 == 0 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func pem(label: String, data: Data) -> String {
        let base64 = data.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { start in
            let begin = base64.index(base64.startIndex, offsetBy: start)
            let end = base64.index(begin, offsetBy: min(70, base64.distance(from: begin, to: base64.endIndex)))
            return String(base64[begin..<end])
        }
        return "-----BEGIN \(label)-----\n\(lines.joined(separator: "\n"))\n-----END \(label)-----"
    }

    private struct RSAComponents {
        let n: [UInt8]
        let e: [UInt8]
        let d: [UInt8]
        let p: [UInt8]
        let q: [UInt8]
        let qi: [UInt8]
    }

    private static func parsePKCS8Ed25519(_ data: Data) throws -> Data {
        var outer = DERReader(bytes: [UInt8](data))
        let body = try outer.read(tag: 0x30)
        guard outer.isAtEnd else { throw CredentialError.encoding }
        var sequence = DERReader(bytes: body)
        _ = try sequence.read(tag: 0x02) // version
        var algorithm = DERReader(bytes: try sequence.read(tag: 0x30))
        guard try algorithm.read(tag: 0x06) == [0x2b, 0x65, 0x70] else {
            throw CredentialError.encoding
        }
        let octets = try sequence.read(tag: 0x04)
        if octets.count == 32 {
            return Data(octets)
        }
        var nested = DERReader(bytes: octets)
        let raw = try nested.read(tag: 0x04)
        guard raw.count == 32, nested.isAtEnd else { throw CredentialError.encoding }
        return Data(raw)
    }

    private static func encodeUInt32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private struct WireReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func readBytes(count: Int) -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { return [] }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func readUInt32() throws -> UInt32 {
            let bytes = readBytes(count: 4)
            guard bytes.count == 4 else { throw CredentialError.encoding }
            return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        }

        mutating func readString() throws -> [UInt8] {
            let length = Int(try readUInt32())
            let value = readBytes(count: length)
            guard value.count == length else { throw CredentialError.encoding }
            return value
        }
    }

    private struct DERReader {
        let bytes: [UInt8]
        var offset = 0
        var isAtEnd: Bool { offset == bytes.count }

        mutating func read(tag expectedTag: UInt8) throws -> [UInt8] {
            guard offset < bytes.count, bytes[offset] == expectedTag else { throw CredentialError.encoding }
            offset += 1
            guard offset < bytes.count else { throw CredentialError.encoding }
            let firstLength = bytes[offset]
            offset += 1
            let length: Int
            if firstLength & 0x80 == 0 {
                length = Int(firstLength)
            } else {
                let count = Int(firstLength & 0x7f)
                guard count > 0, count <= 4, offset + count <= bytes.count else { throw CredentialError.encoding }
                var value = 0
                for _ in 0..<count { value = (value << 8) | Int(bytes[offset]); offset += 1 }
                length = value
            }
            guard length >= 0, offset + length <= bytes.count else { throw CredentialError.encoding }
            defer { offset += length }
            return Array(bytes[offset..<(offset + length)])
        }
    }
}
