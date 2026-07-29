import Foundation

/// 镜像与容器的引用关系判定。纯函数，不碰网络。
///
/// **为什么不用 `docker images --filter dangling=true`**：那个过滤器给的是
/// 「无 tag」的镜像，与「没被容器引用」是两码事——一个打了 tag 的镜像完全
/// 可能没人用。拿 dangling 当「未使用」会漏掉一大批真正能删的镜像，更糟的是
/// 反过来让用户以为「没标徽标 = 还在用」而不敢删。
///
/// 容器段本来就要拉 `docker ps -a`，把那份结果拿来比对即可，**不额外跑命令**。
public enum ImageUsage {
    /// 没有任何容器引用的镜像 id 集合（`ImageInfo.id`）。
    public static func unusedImageIDs(
        images: [ImageInfo],
        containers: [ContainerInfo]
    ) -> Set<String> {
        let referenced = containers.map(\.image)
        return Set(
            images
                .filter { image in !referenced.contains { matches(image, reference: $0) } }
                .map(\.id)
        )
    }

    /// 引用某镜像的容器（含已停止的——它引用着就删不掉该镜像）。
    public static func containersUsing(
        _ image: ImageInfo,
        in containers: [ContainerInfo]
    ) -> [ContainerInfo] {
        containers.filter { matches(image, reference: $0.image) }
    }

    /// 容器的 `image` 字段是否指向该镜像。
    ///
    /// 三种写法都要认：`repo:tag`、完整 ID（可带 `sha256:` 前缀）、12 位短 ID。
    /// 认漏会把在用的镜像标成「未使用」，用户据此删掉就是事故。
    private static func matches(_ image: ImageInfo, reference: String) -> Bool {
        if reference == image.reference { return true }
        let bare = reference.hasPrefix("sha256:")
            ? String(reference.dropFirst("sha256:".count))
            : reference
        // ImageInfo.imageID 是 docker images 给的 12 位短 ID；容器可能给完整 64 位。
        // 两个方向都要判：短的是长的前缀，或反过来。
        guard !bare.isEmpty, !image.imageID.isEmpty else { return false }
        return bare.hasPrefix(image.imageID) || image.imageID.hasPrefix(bare)
    }
}
