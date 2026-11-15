import Foundation

/// 网页来源上下文：抓公网页面 → 抽正文 → 在正文里定位选区 → 取所在段落。
///
/// 安全边界：
/// - 只接受 http/https，拒绝 loopback / 私有网段 / `.local`，防 SSRF 与内网内容外发；
/// - 不携带 Cookie/认证，跟随重定向后校验最终 URL；
/// - 响应体上限 2MB，正文上限 200KB；超时由调用方给（默认 8s）。
public enum WebPageContext {
    public struct Result: Sendable, Equatable {
        public var title: String
        public var url: String
        public var excerpt: String?
        /// 是否在正文里真的找到了选区（否则只能退化到标题）
        public var foundSelection: Bool
    }

    public typealias Fetcher = @Sendable (URL) async throws -> (Data, String?)

    static let maxBodyBytes = 2 * 1024 * 1024
    static let maxTextCharacters = 200_000

    public static func context(url rawURL: String,
                               selection: String,
                               limit: Int,
                               timeout: TimeInterval = 8,
                               fetcher: Fetcher? = nil) async -> Result? {
        guard let url = URL(string: rawURL), isPublicHTTPURL(url) else { return nil }

        let fetch = fetcher ?? { try await defaultFetch($0, timeout: timeout) }
        let fetched: (Data, String?)
        do {
            fetched = try await fetch(url)
        } catch {
            if debugEnabled { print("[web] fetch failed:", error) }
            return nil
        }
        let (data, encodingName) = fetched
        guard data.count > 0, data.count <= maxBodyBytes else { return nil }

        let html = decodeHTML(data, encodingName: encodingName)
        guard !html.isEmpty else { return nil }
        let title = documentTitle(fromHTML: html) ?? url.host ?? rawURL
        let text = visibleText(fromHTML: html)
        guard !text.isEmpty else {
            return Result(title: title, url: rawURL, excerpt: nil, foundSelection: false)
        }

        let sections = DocumentContext.paragraphSections(in: text)
        if let excerpt = ContextRetrieval.excerpt(sections: sections,
                                                  selection: selection,
                                                  limit: max(limit, 200)) {
            if debugEnabled {
                print("[web] bytes=\(data.count) text=\(text.count) selection=found excerpt=\(excerpt.count)")
            }
            return Result(title: title,
                          url: rawURL,
                          excerpt: excerpt,
                          foundSelection: true)
        }
        if let range = DocumentContext.locate(selection, in: text) {
            let excerpt = DocumentContext.excerptText(in: text, range: range, limit: max(limit, 200))
            if debugEnabled {
                print("[web] bytes=\(data.count) text=\(text.count) selection=found(fallback) excerpt=\(excerpt.count)")
            }
            return Result(title: title,
                          url: rawURL,
                          excerpt: excerpt.isEmpty ? nil : excerpt,
                          foundSelection: true)
        }
        if debugEnabled {
            print("[web] bytes=\(data.count) text=\(text.count) selection=missing title=\(title)")
        }
        return Result(title: title, url: rawURL, excerpt: nil, foundSelection: false)
    }

    private static var debugEnabled: Bool {
        ProcessInfo.processInfo.environment["SPRIG_WEB_DEBUG"] != nil
    }

    // MARK: - URL 安全

    public static func isPublicHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host == "0.0.0.0" { return false }
        if host.contains(":") { return false }   // IPv6 字面量一律拒绝，避免绕过 IPv4 判断

        // IPv4 字面量：拒绝 loopback / 私有 / link-local / CGNAT
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) {
            let octets = parts.compactMap { Int($0) }
            guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
            if octets[0] == 10 || octets[0] == 127 || octets[0] == 0 { return false }
            if octets[0] == 172, (16...31).contains(octets[1]) { return false }
            if octets[0] == 192, octets[1] == 168 { return false }
            if octets[0] == 169, octets[1] == 254 { return false }
            if octets[0] == 100, (64...127).contains(octets[1]) { return false }
        }
        return true
    }

    // MARK: - 抓取

    private static func defaultFetch(_ url: URL, timeout: TimeInterval) async throws -> (Data, String?) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("Sprig/0.2 (macOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              isPublicHTTPURL(finalURL) else {
            throw URLError(.badServerResponse)
        }
        return (data, http.textEncodingName)
    }

    private static func decodeHTML(_ data: Data, encodingName: String?) -> String {
        if let name = encodingName?.lowercased() {
            if name.contains("utf-8") || name.contains("utf8") {
                if let text = String(data: data, encoding: .utf8) { return text }
            }
            if name.contains("iso-8859-1") || name.contains("latin1") {
                if let text = String(data: data, encoding: .isoLatin1) { return text }
            }
            if name.contains("gbk") || name.contains("gb2312") {
                let gb18030 = String.Encoding(rawValue:
                    CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                if let text = String(data: data, encoding: gb18030) { return text }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: - 正文抽取

    static func documentTitle(fromHTML html: String) -> String? {
        guard let range = html.range(of: "<title[^>]*>(.*?)</title>",
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        let content = String(html[range])
            .replacingOccurrences(of: "<title[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</title>", with: "", options: .caseInsensitive)
        let decoded = decodeEntities(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        return decoded.count > 200 ? String(decoded.prefix(200)) : decoded
    }

    static func visibleText(fromHTML html: String) -> String {
        var text = html
        let patterns: [(String, String)] = [
            ("(?s)<!--.*?-->", ""),
            ("(?s)<(script|style|noscript|template|svg|head|nav|aside|footer|button|select|option)[^>]*>.*?</\\1>", ""),
            ("<br\\s*/?>", "\n"),
            ("</(p|div|li|tr|h[1-6]|blockquote|section|article|header|footer|pre)>", "\n"),
            ("</(td|th)>", " "),
            ("<[^>]+>", ""),
        ]
        for (pattern, replacement) in patterns {
            // 带 (?s) 内联旗标：<style>/<script> 往往是多行的，之前整块 CSS
            // 会漏进正文（还可能被当成上下文发给模型）
            text = text.replacingOccurrences(of: pattern,
                                             with: replacement,
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[\\t\\u{00A0} ]+", with: " ", options: .regularExpression)
            // HTML 缩进会在行首/行尾留下大量空格，白占字符和 token
            .replacingOccurrences(of: " +\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n +", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxTextCharacters {
            text = String(text.prefix(maxTextCharacters))
        }
        return text
    }

    static func decodeEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
            "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
            "&middot;": "·", "&copy;": "©", "&reg;": "®",
        ]
        var text = raw
        for (entity, value) in named {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }

        // 数字实体：&#123; / &#x1F600;
        guard let regex = try? NSRegularExpression(pattern: "&#([xX])?([0-9a-fA-F]+);") else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            let radix = match.range(at: 1).location == NSNotFound ? 10 : 16
            let digits = source.substring(with: match.range(at: 2))
            guard let code = UInt32(digits, radix: radix),
                  let scalar = Unicode.Scalar(code),
                  let range = Range(match.range, in: text) else { continue }
            text.replaceSubrange(range, with: String(Character(scalar)))
        }
        return text
    }
}
