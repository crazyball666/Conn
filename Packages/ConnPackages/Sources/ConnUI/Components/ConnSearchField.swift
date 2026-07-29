import SwiftUI

/// 搜索框：放大镜 + 输入框 + 清除按钮，浅底描边圆角。
///
/// 进程列表与文件列表原先各写了一份逐字相同的实现，改一处必漏一处，故收敛成组件。
///
/// **高度钉在 `ConnSize.searchFieldHeight` 上，不由 `TextField` 的固有高度决定**
/// ——这是本组件存在的第二个理由，也是它修掉的那个缺陷：`TextField` 在「首次成为
/// 第一响应者」前后走两套测量路径（之前由 SwiftUI 量，之后交给 UIKit 的
/// `UITextField`），真机实测首次点进输入框时整个框会从 38pt 掉到 32pt，而且**再也
/// 回不去**——收起键盘、重新聚焦都不回弹。把高度交给令牌，这类抖动整类消失。
///
/// 用 `@ScaledMetric` 而不是裸字面量：钉死高度不该以牺牲动态字体为代价，
/// 框高要跟着 `.subheadline` 一起放大，否则大字号下文字会被切掉。
public struct ConnSearchField: View {
    private let prompt: String
    @Binding private var text: String

    @ScaledMetric(relativeTo: .subheadline) private var height = ConnSize.searchFieldHeight

    /// - Parameters:
    ///   - prompt: 占位文案。由调用方传入已本地化的字符串。
    ///   - text: 搜索词绑定。
    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    public var body: some View {
        HStack(spacing: ConnSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("清除"))
            }
        }
        .padding(.horizontal, ConnSpacing.sm)
        .frame(height: height)
        .background(Color.connSurface, in: .rect(cornerRadius: ConnRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 1)
        }
    }

    /// `textInputAutocapitalization` 只有 iOS 有，所以要条件编译。
    ///
    /// **本 App 不出 macOS 版**，但包必须声明 `.macOS("15.0")`：SwiftPM 在不声明时
    /// 按 macOS 10.13 处理，而 GRDB(10.15) / SwiftTerm(11) / Citadel(14) 的下限都更高，
    /// 删掉那行整个包立刻编不过。它同时也是「`swift test` 能在本机跑、不用开模拟器」
    /// 的前提，所以 ConnUI 的源码始终会被按 macOS 编译一遍。
    private var field: some View {
        let base = TextField(prompt, text: $text)
            .font(.connSubheadline)
            .foregroundStyle(.connInk)
            .autocorrectionDisabled()
        #if os(iOS)
        return base.textInputAutocapitalization(.never)
        #else
        return base
        #endif
    }
}

#Preview("ConnSearchField · 浅色") {
    struct Harness: View {
        @State private var empty = ""
        @State private var filled = "nginx"
        var body: some View {
            VStack(spacing: ConnSpacing.sm) {
                ConnSearchField("搜索进程 / PID / 用户", text: $empty)
                ConnSearchField("搜索当前目录", text: $filled)
            }
            .padding(ConnSpacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.connBg)
        }
    }
    return Harness().preferredColorScheme(.light)
}

#Preview("ConnSearchField · 深色") {
    struct Harness: View {
        @State private var empty = ""
        @State private var filled = "nginx"
        var body: some View {
            VStack(spacing: ConnSpacing.sm) {
                ConnSearchField("搜索进程 / PID / 用户", text: $empty)
                ConnSearchField("搜索当前目录", text: $filled)
            }
            .padding(ConnSpacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.connBg)
        }
    }
    return Harness().preferredColorScheme(.dark)
}
