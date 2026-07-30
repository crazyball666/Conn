import Foundation

/// 镜像与容器的引用关系判定。纯函数，不碰网络。
///
/// **为什么不用 `docker images --filter dangling=true`**：那个过滤器给的是
/// 「无 tag」的镜像，与「没被容器引用」是两码事——一个打了 tag 的镜像完全
/// 可能没人用。拿 dangling 当「未使用」会漏掉一大批真正能删的镜像，更糟的是
/// 反过来让用户以为「没标徽标 = 还在用」而不敢删。
///
/// 容器段本来就要拉 `docker ps -a`，把那份结果拿来比对即可，**不额外跑命令**。
///
/// **为什么是客户端比对，而不是设计文档原定的 `docker ps -a --filter ancestor=<引用>`**：
/// 后者由服务端按引用解析镜像再过滤，天然不会有本文件这几条判据要覆盖的歧义，
/// 但要对每个镜像单独发一条命令、且要把整条取数链路改成异步——镜像多的主机上
/// 开销更大，改动面也远超本期「只读补全」的范围。这里选择的是客户端比对 +
/// 尽量补全判据的折中方案；这段注释就是把这处早先未被记录的设计偏离补上。
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
    /// 四种写法都要认：`repo:tag` 全等、无 tag 裸引用（隐含 `:latest`）、
    /// 完整 ID / digest（可带 `sha256:` 或 `repo@sha256:` 前缀）、12 位短 ID 双向前缀。
    /// 认漏会把在用的镜像标成「未使用」，用户据此删掉就是事故——这是最容易被
    /// 忽略的一种：`docker run -d nginx` 不写 tag 时，`docker ps` 的 IMAGE 列原样
    /// 显示用户敲的 `nginx`（docker 不会补全成 `nginx:latest` 再显示），而
    /// `docker images` 给的却是 `repository=nginx, tag=latest`，四步旧比对全部
    /// 落空，镜像会被误判成「未使用」。
    private static func matches(_ image: ImageInfo, reference: String) -> Bool {
        if reference == image.reference { return true }
        // 无 tag 裸引用：补 `:latest` 再判，而不是直接判 `reference == image.repository`——
        // 后者会把「同名但只挂了非 latest tag」的镜像也误判成在用（这个容器实际
        // 引用的是隐式的 latest，不是这个 tag）。docker 对无 tag 引用的默认解析
        // 就是 latest，补全后走全等比较更贴近真实语义。
        if !reference.contains(":"), !reference.contains("@"),
           reference == image.repository, image.tag == "latest" {
            return true
        }
        // 完整 ID / digest 引用：`repo@sha256:...`（digest）先摘掉 `repo@` 前缀，
        // 剩下部分与「完整 ID」走同一套 sha256: 剥前缀 + 双向前缀比较。
        // `ImageInfo` 不单独记录 RepoDigests，这里退化成按 ID 前缀近似匹配——
        // 覆盖不了「纯按 digest 拉取、与本地 ID 恰好不重叠」的极端情况，
        // 但比完全认不出这类引用要好。
        let idPart = reference.split(separator: "@", maxSplits: 1).last.map(String.init) ?? reference
        let bare = DockerParser.stripSHA256Prefix(idPart)
        // ImageInfo.imageID 是 docker images 给的 12 位短 ID；容器可能给完整 64 位。
        // 两个方向都要判：短的是长的前缀，或反过来。
        guard !bare.isEmpty, !image.imageID.isEmpty else { return false }
        return bare.hasPrefix(image.imageID) || image.imageID.hasPrefix(bare)
    }
}
