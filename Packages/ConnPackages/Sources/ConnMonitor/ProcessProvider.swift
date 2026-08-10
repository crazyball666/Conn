import ConnKit

/// 一个平台的进程列表能力。
public protocol ProcessProvider: Sendable {
    var platform: RemotePlatformKind { get }
    var command: String { get }
    var capabilityState: CapabilityState { get }
    func parse(_ output: String) -> [RemoteProcess]
}

public struct LinuxProcessProvider: ProcessProvider {
    public let platform = RemotePlatformKind.linux
    public let capabilityState = CapabilityState.supported

    public init() {}

    public var command: String { ProcessCollectionScript.command }

    public func parse(_ output: String) -> [RemoteProcess] {
        ProcessParser.parse(output)
    }
}

public enum ProcessProviderRegistry {
    public static func provider(for platform: RemotePlatformKind) -> (any ProcessProvider)? {
        switch platform {
        case .linux:
            LinuxProcessProvider()
        case .macOS:
            DarwinProcessProvider()
        case .windows, .unknown:
            nil
        }
    }
}
