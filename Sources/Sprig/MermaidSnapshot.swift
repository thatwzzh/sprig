import AppKit
import CryptoKit
import WebKit

/// ```mermaid 图（流程图 / 时序图 / 架构图）的离屏渲染。
///
/// 运行时（mermaid.min.js）随 app 一起打包在 `Contents/Resources`，不联网也能画。
/// 拿不到运行时、或者语法错误画不出来，就返回 nil，上层退回显示源码。
@MainActor
enum MermaidSnapshot {
    private static var memory: [String: NSImage] = [:]
    private static var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// 缓存键要带外观和当前主题：底色、图内配色都跟着它们变
    private static var appearanceTag: String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    private static var variant: String {
        appearanceTag + "|" + MarkdownTheme.current.id
    }

    /// 和答案区文本同宽，否则图比文本宽，右边会被裁掉
    static let defaultWidth = Theme.answerTextWidth

    static func key(for source: String, maxWidth: CGFloat) -> String {
        let digest = SHA256.hash(data: Data((source + "|" + variant + "|"
            + String(Int(maxWidth.rounded()))).utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    static func cached(_ source: String, maxWidth: CGFloat = defaultWidth) -> NSImage? {
        memory[key(for: source, maxWidth: maxWidth)]
    }

    static func image(for source: String, maxWidth: CGFloat = defaultWidth) async -> NSImage? {
        let cacheKey = key(for: source, maxWidth: maxWidth)
        if let image = memory[cacheKey] { return image }
        if let task = inFlight[cacheKey] { return await task.value }

        let task = Task<NSImage?, Never> { @MainActor in
            let image = await render(source, dark: appearanceTag == "dark", width: maxWidth)
            if let image { memory[cacheKey] = image }
            inFlight[cacheKey] = nil
            return image
        }
        inFlight[cacheKey] = task
        return await task.value
    }

    // MARK: - 渲染

    private static func render(_ source: String, dark: Bool, width: CGFloat) async -> NSImage? {
        guard let script = mermaidScript() else { return nil }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        // 不放进窗口的话 WKWebView 不会真正排版
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)

        let watcher = LoadWatcher()
        web.navigationDelegate = watcher
        web.loadHTMLString(page(source: source, script: script, dark: dark), baseURL: nil)
        await watcher.wait()

        // 等 mermaid 把 <pre> 换成 <svg>：最多 4 秒
        var height: CGFloat = 0
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let measured = try? await web.evaluateJavaScript(
                "(function(){var s=document.querySelector('svg');if(!s)return 0;"
                + "return Math.ceil(s.getBoundingClientRect().height);})()")
            if let value = measured as? Double, value > 24 {
                height = CGFloat(value)
                break
            }
        }
        guard height > 24 else {
            window.orderOut(nil)
            return nil
        }

        let contentHeight = min(max(height + 24, 60), 2000)
        web.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        window.setContentSize(NSSize(width: width, height: contentHeight))
        try? await Task.sleep(nanoseconds: 150_000_000)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        configuration.snapshotWidth = NSNumber(value: Double(width))
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            web.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        window.orderOut(nil)
        guard let image else { return nil }
        return rounded(image)
    }

    /// 图片是矩形的，压在文本里像个卡片；裁成圆角至少和整体风格一致
    private static func rounded(_ image: NSImage, radius: CGFloat = 6) -> NSImage {
        let size = image.size
        let output = NSImage(size: size)
        output.lockFocus()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                     xRadius: radius, yRadius: radius).addClip()
        image.draw(in: NSRect(origin: .zero, size: size))
        output.unlockFocus()
        return output
    }

    /// 运行时脚本：打包在 Contents/Resources/mermaid.min.js
    private static func mermaidScript() -> String? {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func page(source: String, script: String, dark: Bool) -> String {
        let escaped = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // 背景取代码块底色：和面板底色最接近，不会出现一块刺眼的白
        let background = hexString(MarkdownTheme.current.palette.codeBackground)
        let theme = dark ? "dark" : "default"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:8px 4px;background:\(background);}
          .mermaid{display:block;margin:0;text-align:center;}
          svg{max-width:100% !important;height:auto !important;}
        </style></head><body>
        <pre class="mermaid">\(escaped)</pre>
        <script>\(script)</script>
        <script>
          // mermaid 11 的 dist 是 esbuild 打的包，挂在私有命名空间里，没有 window.mermaid
          var __ns = globalThis.__esbuild_esm_mermaid_nm;
          var mermaid = __ns && __ns.mermaid && (__ns.mermaid.default || __ns.mermaid);
          if (mermaid) {
            mermaid.initialize({startOnLoad:false,theme:'\(theme)',securityLevel:'strict',
                                fontFamily:'-apple-system,PingFang SC,sans-serif',
                                flowchart:{htmlLabels:false,curve:'basis'}});
            mermaid.run({querySelector:'.mermaid'}).catch(function(){});
          }
        </script>
        </body></html>
        """
    }

    /// NSColor → #RRGGBB（先按当前外观解析，再取 sRGB 分量）
    private static func hexString(_ color: NSColor) -> String {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int(round(resolved.redComponent * 255)),
                      Int(round(resolved.greenComponent * 255)),
                      Int(round(resolved.blueComponent * 255)))
    }

    /// 等 didFinish；页面出错也放行，上层会退回源码
    private final class LoadWatcher: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false

        func wait() async {
            if finished { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if finished {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
    }
}
