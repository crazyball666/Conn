import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private struct MarketingAsset {
    let name: String
    let zhTitle: String
    let zhSubtitle: String
    let enTitle: String
    let enSubtitle: String
}

private let assets = [
    MarketingAsset(
        name: "server-list",
        zhTitle: "随时掌控你的服务器",
        zhSubtitle: "SSH 连接、实时指标与分组管理",
        enTitle: "Your servers, in control",
        enSubtitle: "SSH access, live metrics, and smart groups"
    ),
    MarketingAsset(
        name: "host-detail",
        zhTitle: "主机状态，一目了然",
        zhSubtitle: "CPU、内存、磁盘与网络指标",
        enTitle: "Every host at a glance",
        enSubtitle: "CPU, memory, disk, and network insights"
    ),
    MarketingAsset(
        name: "terminal-output",
        zhTitle: "随身终端，快速响应",
        zhSubtitle: "移动快捷键、多会话与安全连接",
        enTitle: "A terminal that travels",
        enSubtitle: "Mobile shortcuts, multiple sessions, secure access"
    ),
    MarketingAsset(
        name: "docker-containers",
        zhTitle: "Docker 运维更简单",
        zhSubtitle: "容器、镜像、网络与 Compose",
        enTitle: "Docker, made operational",
        enSubtitle: "Containers, images, networks, and Compose"
    ),
    MarketingAsset(
        name: "script-run",
        zhTitle: "批量执行运维脚本",
        zhSubtitle: "选择主机、Shell 类型与执行记录",
        enTitle: "Run scripts across hosts",
        enSubtitle: "Host selection, shell types, and execution history"
    ),
    MarketingAsset(
        name: "file-browser",
        zhTitle: "远程文件，随时处理",
        zhSubtitle: "浏览、搜索、编辑与保存",
        enTitle: "Remote files, within reach",
        enSubtitle: "Browse, search, edit, and save"
    )
]

// Design coordinates stay at the original iPhone 17 Pro composition size.
// The App Store export is rendered at an accepted 6.9-inch resolution.
private let designSize = CGSize(width: 1206, height: 2622)
private let canvasSize = CGSize(width: 1320, height: 2868)
private let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let screenshotRoot = repositoryRoot.appendingPathComponent("docs/app-store/screenshots")
private let rawRoot = screenshotRoot.appendingPathComponent("raw")
private let marketingRoot = screenshotRoot.appendingPathComponent("marketing")
// The revised composition is intentionally written to a separate directory
// so the first approved version remains available for side-by-side review.
private let revisedMarketingRoot = marketingRoot.appendingPathComponent("app-store-6.9")

private func cgImage(at url: URL) -> CGImage? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

private func topRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
    CGRect(x: x, y: designSize.height - y - height, width: width, height: height)
}

private func addRoundedRect(_ rect: CGRect, radius: CGFloat, to context: CGContext) {
    context.addPath(CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    ))
}

private func drawAspectFill(_ image: CGImage, in rect: CGRect, context: CGContext) {
    let imageWidth = CGFloat(image.width)
    let imageHeight = CGFloat(image.height)
    let scale = max(rect.width / imageWidth, rect.height / imageHeight)
    context.draw(image, in: CGRect(
        x: rect.midX - imageWidth * scale / 2,
        y: rect.midY - imageHeight * scale / 2,
        width: imageWidth * scale,
        height: imageHeight * scale
    ))
}

private func drawAspectFit(_ image: CGImage, in rect: CGRect, context: CGContext) {
    let imageWidth = CGFloat(image.width)
    let imageHeight = CGFloat(image.height)
    let scale = min(rect.width / imageWidth, rect.height / imageHeight)
    context.draw(image, in: CGRect(
        x: rect.midX - imageWidth * scale / 2,
        y: rect.midY - imageHeight * scale / 2,
        width: imageWidth * scale,
        height: imageHeight * scale
    ))
}

private func drawText(
    _ text: String,
    rect: CGRect,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    context: CGContext,
    alignment: NSTextAlignment = .left
) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style
    ]
    let converted = topRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (text as NSString).draw(in: converted, withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
}

private func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

guard let background = cgImage(at: marketingRoot.appendingPathComponent("connterm-background.png")) else {
    fatalError("Missing marketing background")
}

for language in ["zh", "en"] {
    let outputDirectory = revisedMarketingRoot.appendingPathComponent(language)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    for (index, asset) in assets.enumerated() {
        let source = rawRoot
            .appendingPathComponent(language)
            .appendingPathComponent("\(asset.name).png")
        guard let screenshot = cgImage(at: source) else {
            print("Skipping missing localized screenshot: \(source.path)")
            continue
        }
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(canvasSize.width) * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            continue
        }

        // Keep the approved composition while producing a current 6.9-inch
        // App Store image. The opaque context guarantees a PNG without alpha.
        context.scaleBy(
            x: canvasSize.width / designSize.width,
            y: canvasSize.height / designSize.height
        )

        drawAspectFill(background, in: CGRect(origin: .zero, size: designSize), context: context)

        let title = language == "zh" ? asset.zhTitle : asset.enTitle
        let subtitle = language == "zh" ? asset.zhSubtitle : asset.enSubtitle
        drawText(
            "CONNTERM",
            rect: CGRect(x: 72, y: 62, width: 420, height: 44),
            size: 26,
            weight: .bold,
            color: NSColor(calibratedRed: 0.73, green: 0.67, blue: 1, alpha: 1),
            context: context
        )
        drawText(
            title,
            rect: CGRect(x: 72, y: 138, width: 1062, height: 106),
            size: language == "zh" ? 72 : 66,
            weight: .bold,
            color: .white,
            context: context
        )
        drawText(
            subtitle,
            rect: CGRect(x: 74, y: 266, width: 1058, height: 58),
            size: 32,
            weight: .medium,
            color: NSColor(calibratedRed: 0.68, green: 0.71, blue: 0.79, alpha: 1),
            context: context
        )

        let shadow = topRect(x: 168, y: 462, width: 870, height: 1834)
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        addRoundedRect(shadow, radius: 154, to: context)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)

        // Physical side controls sit behind the titanium body, so the result
        // reads as a real device mockup rather than a decorative outline.
        context.setFillColor(NSColor(calibratedRed: 0.08, green: 0.085, blue: 0.095, alpha: 1).cgColor)
        for button in [
            topRect(x: 168, y: 728, width: 13, height: 84),
            topRect(x: 168, y: 846, width: 13, height: 140),
            topRect(x: 168, y: 1012, width: 13, height: 140),
            topRect(x: 1038, y: 866, width: 13, height: 190)
        ] {
            addRoundedRect(button, radius: 7, to: context)
            context.fillPath()
        }

        let body = topRect(x: 178, y: 470, width: 840, height: 1790)
        context.setFillColor(NSColor(calibratedRed: 0.115, green: 0.12, blue: 0.135, alpha: 1).cgColor)
        addRoundedRect(body, radius: 136, to: context)
        context.fillPath()
        context.setStrokeColor(NSColor(calibratedRed: 0.34, green: 0.35, blue: 0.39, alpha: 0.9).cgColor)
        context.setLineWidth(2)
        addRoundedRect(body.insetBy(dx: 2, dy: 2), radius: 134, to: context)
        context.strokePath()

        let bezel = topRect(x: 186, y: 478, width: 824, height: 1774)
        context.setFillColor(NSColor(calibratedRed: 0.005, green: 0.006, blue: 0.009, alpha: 1).cgColor)
        addRoundedRect(bezel, radius: 128, to: context)
        context.fillPath()

        // Preserve the simulator screenshot's exact aspect ratio so every
        // status icon, card metric, and bottom control remains fully visible.
        let screen = topRect(x: 204, y: 500, width: 786, height: 1708)
        context.saveGState()
        addRoundedRect(screen, radius: 108, to: context)
        context.clip()
        drawAspectFit(screenshot, in: screen, context: context)
        context.restoreGState()

        drawText(
            "CONNTERM",
            rect: CGRect(x: 72, y: 2482, width: 360, height: 34),
            size: 20,
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.68, alpha: 1),
            context: context
        )
        drawText(
            String(format: "%02d / %02d", index + 1, assets.count),
            rect: CGRect(x: 832, y: 2482, width: 302, height: 34),
            size: 20,
            weight: .medium,
            color: NSColor(calibratedWhite: 0.52, alpha: 1),
            context: context,
            alignment: .right
        )

        guard let output = context.makeImage() else { continue }
        try write(output, to: outputDirectory.appendingPathComponent("\(asset.name).png"))
    }
}
