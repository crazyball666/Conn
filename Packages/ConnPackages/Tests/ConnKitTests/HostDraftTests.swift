import Testing
@testable import ConnKit

@Suite("HostDraft — 表单草稿与验证")
struct HostDraftTests {
    @Test("地址与用户名必填")
    func requiresAddressAndUsername() {
        let empty = HostDraft()
        let errors = empty.validate()
        #expect(errors[.address] != nil)
        #expect(errors[.username] != nil)
        #expect(!empty.isValid)
    }

    @Test("填齐必填项即有效")
    func validWhenRequiredFilled() {
        let draft = HostDraft(address: "10.0.0.1", username: "root")
        #expect(draft.isValid)
    }

    @Test("端口越界报错")
    func portOutOfRange() {
        #expect(HostDraft(address: "h", port: 0, username: "u").validate()[.port] != nil)
        #expect(HostDraft(address: "h", port: 70000, username: "u").validate()[.port] != nil)
        #expect(HostDraft(address: "h", port: 22, username: "u").validate()[.port] == nil)
    }

    @Test("名称留空时 toHost 用地址兜底")
    func nameFallsBackToAddress() {
        let host = HostDraft(address: "10.0.0.1", username: "root").toHost()
        #expect(host.name == "10.0.0.1")
    }

    @Test("toHost 去除首尾空白")
    func toHostTrimsWhitespace() {
        let host = HostDraft(name: "  web  ", address: " 10.0.0.1 ", username: " root ").toHost()
        #expect(host.name == "web")
        #expect(host.address == "10.0.0.1")
        #expect(host.username == "root")
    }

    @Test("Host ↔ HostDraft 往返无损")
    func roundTripWithHost() {
        let original = Host(
            name: "web-01", address: "10.0.0.1", username: "root",
            port: 2222, authKind: .key, tags: ["prod"], note: "生产"
        )
        let draft = HostDraft(from: original)
        let rebuilt = draft.toHost(existingID: original.id)
        #expect(rebuilt.id == original.id)
        #expect(rebuilt.name == original.name)
        #expect(rebuilt.port == original.port)
        #expect(rebuilt.authKind == original.authKind)
        #expect(rebuilt.tags == original.tags)
        #expect(rebuilt.note == original.note)
    }

    @Test("编辑场景保留原 id，新增场景生成新 id")
    func preservesIDWhenEditing() {
        let draft = HostDraft(address: "h", username: "u")
        #expect(draft.toHost(existingID: "fixed-id").id == "fixed-id")
        #expect(draft.toHost().id != draft.toHost().id) // 两次新增 id 不同
    }
}
