import Foundation

/// `docker system df -v` 的占用索引。
///
/// **只做索引，不做展示**：值是 docker 给的人类可读串（`1.2GB`），
/// 直接透传，不在客户端重新格式化——不同 docker 版本的单位口径不一致，
/// 二次加工只会引入偏差。
///
/// 查不到一律返回 nil，上层显示「—」。这条命令在大主机上要数秒且格式跨版本
/// 不稳，**它失败不该让任何列表看起来坏了**。
public struct DockerDiskUsage: Equatable, Sendable {
    /// 卷名 → 占用。
    private let volumeSizes: [String: String]
    /// 12 位短镜像 ID → 占用。
    private let imageSizes: [String: String]

    public init(volumeSizes: [String: String], imageSizes: [String: String]) {
        self.volumeSizes = volumeSizes
        self.imageSizes = imageSizes
    }

    public func volumeSize(_ name: String) -> String? { volumeSizes[name] }

    /// - Parameter id: 12 位短 ID（`ImageInfo.imageID` 的规格）。
    public func imageSize(_ id: String) -> String? { imageSizes[id] }
}

// MARK: - 解析

// 放在这个文件而非 DockerParser.swift：那边已经逼近 SwiftLint 的 file_length
// 阈值（500 行），再塞一段会引入新警告，而本项目的基线是「不新增」。
// 解析逻辑与它专属的 DTO 放在同一个文件里，本身也更内聚。
extension DockerParser {
    /// `docker system df -v --format '{{json .}}'` → 占用索引。
    ///
    /// 老版本 docker 不支持该 `--format`，吐出的是表格文本；此时返回 nil，
    /// 让上层显示「—」而不是崩或给出错误数字。
    public static func parseDiskUsage(_ output: String) -> DockerDiskUsage? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DiskUsageDTO.self, from: data)
        else { return nil }

        var volumes: [String: String] = [:]
        for entry in dto.volumes ?? [] {
            volumes[entry.name] = entry.size
        }
        var images: [String: String] = [:]
        for entry in dto.images ?? [] {
            // system df 给带 sha256: 前缀的长 ID，而 docker images 给 12 位短 ID。
            // 不归一化成同一规格，imageSize 永远查不到。
            let bare = entry.id.hasPrefix("sha256:") ? String(entry.id.dropFirst(7)) : entry.id
            images[String(bare.prefix(12))] = entry.size
        }
        return DockerDiskUsage(volumeSizes: volumes, imageSizes: images)
    }
}

// MARK: - DTO

private struct DiskUsageDTO: Decodable {
    let images: [DiskUsageImage]?
    let volumes: [DiskUsageVolume]?
    enum CodingKeys: String, CodingKey { case images = "Images", volumes = "Volumes" }
}

private struct DiskUsageImage: Decodable {
    let id: String
    let size: String
    enum CodingKeys: String, CodingKey { case id = "ID", size = "Size" }
}

private struct DiskUsageVolume: Decodable {
    let name: String
    let size: String
    enum CodingKeys: String, CodingKey { case name = "Name", size = "Size" }
}
