import AppKit
import CoreGraphics
import CryptoKit
import WebKit

/// 把一段 HTML（通常是流程图/架构图）离屏渲染成图片。
///
/// 用途有两个：面板里直接画出来、导出 Markdown 时落成 `assets/*.png` 再引用。
/// 渲染必须是异步的（WKWebView 要加载、要排版），所以结果按内容哈希缓存。
@MainActor
enum HtmlSnapshot {
    private static var memory: [String: NSImage] = [:]
    private static var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// 内容哈希，同时用作缓存键和文件名（同内容只渲一次）
    static func key(for html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    static func cached(_ html: String) -> NSImage? {
        memory[key(for: html)]
    }

    /// 已在缓存里就直接返回，否则开一次离屏渲染
    static func image(for html: String) async -> NSImage? {
        let cacheKey = key(for: html)
        if let image = memory[cacheKey] { return image }
        if let task = inFlight[cacheKey] { return await task.value }

        let task = Task<NSImage?, Never> { @MainActor in
            let image = await render(html)
            if let image { memory[cacheKey] = image }
            inFlight[cacheKey] = nil
            return image
        }
        inFlight[cacheKey] = task
        return await task.value
    }

    private static func render(_ html: String) async -> NSImage? {
        let width: CGFloat = 680
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        // 放进一个不显示的窗口：没有 window 的 WKWebView 不会真正排版
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)

        let delegate = LoadWatcher()
        web.navigationDelegate = delegate

        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        html,body{margin:0;padding:16px;background:#fff;color:#111;
          font:14px/1.6 -apple-system,"PingFang SC",sans-serif;}
        svg,img,canvas{max-width:100%;height:auto}
        </style></head><body>\(html)</body></html>
        """
        web.loadHTMLString(page, baseURL: nil)
        await delegate.wait()
        // 等一帧，让 SVG/canvas 画完
        try? await Task.sleep(nanoseconds: 250_000_000)

        let height = await (try? web.evaluateJavaScript("Math.ceil(document.body.scrollHeight)")) as? Double
        let contentHeight = min(max(CGFloat(height ?? 400), 60), 4000)
        web.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        window.setContentSize(NSSize(width: width, height: contentHeight))
        try? await Task.sleep(nanoseconds: 120_000_000)

        // 调尺寸后再量一次：首次量到的是窗口初始高度，会留下多余白边
        let final = await (try? web.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().height)")) as? Double
        let snapshotHeight = min(max(CGFloat(final ?? contentHeight), 40), contentHeight)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: width, height: snapshotHeight)
        configuration.snapshotWidth = NSNumber(value: Double(width))
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            web.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        window.orderOut(nil)
        return image
    }

    /// 等 `didFinish`；页面加载失败也放行，让调用方拿到 nil
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
