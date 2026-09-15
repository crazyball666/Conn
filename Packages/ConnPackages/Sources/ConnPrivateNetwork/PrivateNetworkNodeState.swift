import ConnCrypto
import ConnKit
import CryptoKit
import Foundation

/// Working files required by libtailscale; durable node secrets belong in Keychain.
struct PrivateNetworkNodeState {
    private struct Snapshot: Codable {
        let controlURL: String
        let state: Data
    }
    let directory: URL
    private let profile: PrivateNetworkProfile
    private let credentialStore: any CredentialStore

    init(profile: PrivateNetworkProfile, credentialStore: any CredentialStore,
         root: URL = FileManager.default.temporaryDirectory) {
        self.profile = profile
        self.credentialStore = credentialStore
        let identity = SHA256.hash(data: Data("\(profile.id)\u{0}\(profile.controlURL)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent("Conn-Tailscale-\(identity)", isDirectory: true)
    }

    func prepare() throws {
        let saved = try credentialStore.privateNetworkNodeState(forProfile: profile.id)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let file = directory.appendingPathComponent("tailscaled.state")
        // A process may have been killed before its final checkpoint. Its working
        // copy is newer than Keychain; do not replace it with an older snapshot.
        guard !FileManager.default.fileExists(atPath: file.path), let saved else { return }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(saved.utf8))
        guard snapshot.controlURL == profile.controlURL else { return }
        try snapshot.state.write(to: file, options: .atomic)
        attributes[.posixPermissions] = 0o600
        try FileManager.default.setAttributes(attributes, ofItemAtPath: file.path)
    }

    func checkpoint() throws {
        let file = directory.appendingPathComponent("tailscaled.state")
        let snapshot = Snapshot(controlURL: profile.controlURL, state: try Data(contentsOf: file))
        let data = try JSONEncoder().encode(snapshot)
        try credentialStore.setPrivateNetworkNodeState(String(decoding: data, as: UTF8.self), forProfile: profile.id)
    }

    func removeWorkingDirectory() throws {
        try FileManager.default.removeItem(at: directory)
    }
}
