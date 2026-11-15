import AppKit
import CryptoKit
import WebKit

/// LaTeX 数学公式的离屏渲染。
///
/// KaTeX 运行时随 app 打包在 `Contents/Resources/katex/`，不联网也能画。
/// 渲染不出来（运行时缺失 / 语法错误 / 超时）就返回 nil，上层退化为代码块显示源码。
@MainActor
enum MathSnapshot {
    private static var memory: [String: NSImage] = [:]
    private static var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// 和答案区文本同宽
    static let defaultWidth = Theme.answerTextWidth

    private static var appearanceTag: String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    private static var variant: String {
        appearanceTag + "|" + MarkdownTheme.current.id
    }

    static func key(for latex: String, display: Bool, maxWidth: CGFloat) -> String {
        let digest = SHA256.hash(data: Data((latex + "|" + String(display) + "|" + variant
            + "|" + String(Int(maxWidth.rounded()))).utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    static func cached(_ latex: String,
                       display: Bool,
                       maxWidth: CGFloat = defaultWidth) -> NSImage? {
        memory[key(for: latex, display: display, maxWidth: maxWidth)]
    }

    static func image(for latex: String,
                      display: Bool,
                      maxWidth: CGFloat = defaultWidth) async -> NSImage? {
        let cacheKey = key(for: latex, display: display, maxWidth: maxWidth)
        if let image = memory[cacheKey] { return image }
        if let task = inFlight[cacheKey] { return await task.value }

        let task = Task<NSImage?, Never> { @MainActor in
            let image = await render(latex, display: display, maxWidth: maxWidth)
            if let image { memory[cacheKey] = image }
            inFlight[cacheKey] = nil
            return image
        }
        inFlight[cacheKey] = task
        return await task.value
    }

    // MARK: - 渲染

    private static func render(_ latex: String,
                               display: Bool,
                               maxWidth: CGFloat) async -> NSImage? {
        guard let assets = loadAssets(), let baseURL = katexDirectory() else { return nil }

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: maxWidth, height: 300))
        // 不放进窗口的话 WKWebView 不会真正排版
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: maxWidth, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)

        let watcher = LoadWatcher()
        web.navigationDelegate = watcher
        let page = page(latex: latex,
                        display: display,
                        assets: assets,
                        maxWidth: maxWidth,
                        dark: appearanceTag == "dark")
        web.loadHTMLString(page, baseURL: baseURL)
        await watcher.wait()

        // 等 KaTeX 把内容渲染出来：最多 2 秒
        var size = CGSize.zero
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let measured = try? await web.evaluateJavaScript(
                "(function(){var e=document.getElementById('math');"
                + "if(!e)return null;var r=e.getBoundingClientRect();"
                + "if(r.height<4)return null;"
                + "return [Math.ceil(r.width),Math.ceil(r.height)];})()")
            if let values = measured as? [NSNumber], values.count == 2 {
                size = CGSize(width: CGFloat(truncating: values[0]),
                              height: CGFloat(truncating: values[1]))
                break
            }
        }
        guard size.width > 4, size.height > 4 else {
            window.orderOut(nil)
            return nil
        }

        let width = min(max(size.width, 24), maxWidth)
        let height = min(max(size.height, 20), 1_500)
        web.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.setContentSize(NSSize(width: width, height: height))
        try? await Task.sleep(nanoseconds: 120_000_000)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: width, height: height)
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

    private static func page(latex: String,
                             display: Bool,
                             assets: (js: String, css: String),
                             maxWidth: CGFloat,
                             dark: Bool) -> String {
        let background = hexString(MarkdownTheme.current.palette.codeBackground)
        let foreground = hexString(MarkdownTheme.current.palette.codeText)
        let fontSize = display
            ? MarkdownTheme.current.bodySize + 1.5
            : MarkdownTheme.current.bodySize
        let escapedLatex = jsonString(latex)
        let escapedJS = assets.js.replacingOccurrences(of: "</script", with: "<\\/script")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>\(assets.css)</style>
        <style>
          html,body{margin:0;padding:0;background:\(background);color:\(foreground);
            font-size:\(fontSize)px;-webkit-font-smoothing:antialiased;}
          #math{display:inline-block;padding:\(display ? "7px 12px" : "2px 6px");
            color:\(foreground);font-size:\(fontSize)px;}
          #math .katex-display{margin:0;}
          #math .katex{font-size:\(fontSize)px;}
          .katex-error{font-family:-apple-system,"PingFang SC",sans-serif;color:\(foreground);}
        </style></head><body>
        <div id="math"></div>
        <script>\(escapedJS)</script>
        <script>
          (function(){
            var el = document.getElementById('math');
            try {
              katex.render(\(escapedLatex), el, {displayMode: \(display ? "true" : "false"),
                throwOnError: false, strict: 'ignore', trust: false});
            } catch (e) {
              el.textContent = '公式渲染失败';
            }
          })();
        </script>
        </body></html>
        """
    }

    private static func loadAssets() -> (js: String, css: String)? {
        guard let jsURL = Bundle.main.url(forResource: "katex.min", withExtension: "js", subdirectory: "katex"),
              let cssURL = Bundle.main.url(forResource: "katex.min", withExtension: "css", subdirectory: "katex"),
              let js = try? String(contentsOf: jsURL, encoding: .utf8),
              let css = try? String(contentsOf: cssURL, encoding: .utf8) else { return nil }
        return (js, css)
    }

    private static func katexDirectory() -> URL? {
        Bundle.main.url(forResource: "katex", withExtension: nil)
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
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

    private static func hexString(_ color: NSColor) -> String {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int(round(resolved.redComponent * 255)),
                      Int(round(resolved.greenComponent * 255)),
                      Int(round(resolved.blueComponent * 255)))
    }

    /// 等 didFinish；页面出错也放行，上层会退化为源码
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
