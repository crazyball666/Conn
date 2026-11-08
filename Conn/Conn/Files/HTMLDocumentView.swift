import SafariServices
import SwiftUI
import WebKit

/// 使用 WebKit 在离线沙盒内高效渲染 HTML 网页文档
struct HTMLDocumentView: View {
    let html: String
    @State private var activeURL: URL?

    var body: some View {
        HTMLWebViewRepresentable(html: html) { url in
            activeURL = url
        }
        .accessibilityIdentifier("files.html.preview")
        .sheet(item: $activeURL) { url in
            InAppHTMLSafariView(url: url)
                .ignoresSafeArea()
        }
    }
}

private struct HTMLWebViewRepresentable: UIViewRepresentable {
    let html: String
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        loadHTML(in: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            loadHTML(in: uiView)
        }
    }

    private func loadHTML(in webView: WKWebView) {
        let finalHTML: String
        // 如果 HTML 缺少移动端 viewport 设置，自动注入以确保手机端按合适比例自适应排版
        if !html.localizedCaseInsensitiveContains("<meta name=\"viewport\"")
            && !html.localizedCaseInsensitiveContains("<meta name='viewport'") {
            let viewportMeta = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes\">"
            if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
                var modified = html
                modified.insert(contentsOf: "\n" + viewportMeta, at: headRange.upperBound)
                finalHTML = modified
            } else {
                finalHTML = "<!DOCTYPE html><html><head>\(viewportMeta)</head><body>\(html)</body></html>"
            }
        } else {
            finalHTML = html
        }
        webView.loadHTMLString(finalHTML, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String = ""
        let onOpenURL: (URL) -> Void

        init(onOpenURL: @escaping (URL) -> Void) {
            self.onOpenURL = onOpenURL
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                onOpenURL(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

private struct InAppHTMLSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
