import ConnSSH
import Darwin
import Foundation
import Testing
@testable import ConnPrivateNetwork

@Suite("私有网络 TCP 转发")
struct PrivateNetworkProxyTests {
    @Test("取消启动会关闭监听器并返回", .timeLimit(.minutes(1)))
    func cancelledStartDoesNotHang() async throws {
        let proxy = PrivateNetworkSOCKSProxy(socksHost: "127.0.0.1", socksPort: 1,
            socksCredential: "fixture", target: SSHEndpoint(host: "host.example"))
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let starting = Task {
            for await _ in stream { break }
            return try await proxy.start()
        }
        starting.cancel()
        continuation.finish()
        do {
            _ = try await starting.value
            Issue.record("Cancelled listener startup unexpectedly succeeded")
        } catch {
            #expect(error is CancellationError || error as? PrivateNetworkError == .proxyUnavailable)
        }
        await proxy.close()
    }

    @Test("真实 SOCKS5 认证和 SSH banner 可通过本机转发器", .timeLimit(.minutes(1)))
    func forwardsSOCKS5Stream() async throws {
        let server = try LoopbackSocket()
        defer { server.close() }
        let serving = Task.detached {
            let peer = try server.accept()
            defer { peer.close() }
            #expect(try peer.read(3) == Data([5, 1, 2]))
            try peer.write(Data([5, 2]))
            #expect(try peer.read(2) == Data([1, 5]))
            #expect(try peer.read(5) == Data("tsnet".utf8))
            #expect(try peer.read(1) == Data([7]))
            #expect(try peer.read(7) == Data("fixture".utf8))
            try peer.write(Data([1, 0]))
            #expect(try peer.read(5) == Data([5, 1, 0, 3, 12]))
            #expect(try peer.read(12) == Data("host.example".utf8))
            #expect(try peer.read(2) == Data([0, 22]))
            try peer.write(Data([5, 0, 0, 1, 127, 0, 0, 1, 0, 22]))
            try peer.write(Data("SSH-2.0-fixture\r\n".utf8))
            #expect(try peer.read(4) == Data("ping".utf8))
        }
        let proxy = try await PrivateNetworkSOCKSProxy(
            socksHost: "127.0.0.1", socksPort: server.port,
            socksCredential: "fixture", target: SSHEndpoint(host: "host.example")
        ).start()
        do {
            try #require(proxy.endpoint.port > 0, "start must return a bound listening port")
            try await Task.detached {
                let client = try LoopbackSocket(connectingTo: proxy.endpoint.port)
                defer { client.close() }
                #expect(try client.read(17) == Data("SSH-2.0-fixture\r\n".utf8))
                try client.write(Data("ping".utf8))
            }.value
            try await serving.value
            await proxy.close()
        } catch {
            await proxy.close()
            throw error
        }
    }
}

/// Blocking fixture sockets run only in detached test tasks, with bounded IO.
private final class LoopbackSocket: @unchecked Sendable {
    let descriptor: Int32
    let port: Int
    private struct SocketError: Error { let operation: String; var code: Int32 = errno }

    init(connectingTo port: Int? = nil) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        self.descriptor = descriptor
        guard descriptor >= 0 else { throw SocketError(operation: "socket") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port ?? 0).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                port == nil ? Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    : Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { let error = SocketError(operation: port == nil ? "bind" : "connect"); Darwin.close(descriptor); throw error }
        if port == nil, listen(descriptor, 1) != 0 { let error = SocketError(operation: "listen"); Darwin.close(descriptor); throw error }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        self.port = Int(UInt16(bigEndian: address.sin_port))
    }

    private init(descriptor: Int32) { self.descriptor = descriptor; port = 0 }
    func accept() throws -> LoopbackSocket {
        let peer = Darwin.accept(descriptor, nil, nil)
        guard peer >= 0 else { throw SocketError(operation: "accept") }
        return LoopbackSocket(descriptor: peer)
    }
    func close() { Darwin.close(descriptor) }
    func read(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let received = Darwin.read(descriptor, &bytes, bytes.count)
            guard received > 0 else { throw SocketError(operation: "read (count=\(received))") }
            result.append(contentsOf: bytes.prefix(received))
        }
        return result
    }
    func write(_ data: Data) throws {
        let sent = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard sent == data.count else { throw SocketError(operation: "write") }
    }
}
