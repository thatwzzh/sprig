import Foundation

/// 选区的来源锚点。用于在文档/网页变化后重新定位同一段文字
/// （W3C Web Annotation 的 TextQuoteSelector 思路：文本 + 前后缀）。
public struct TextAnchor: Codable, Sendable, Equatable {
    /// 选区前的少量文字（建议 60 字以内）
    public var prefix: String
    /// 选区后的少量文字
    public var suffix: String
    /// 在原文里的 UTF-16 偏移（拿不到就 nil）
    public var startOffset: Int?
    /// 选区长度（UTF-16）
    public var length: Int?

    public init(prefix: String = "",
                suffix: String = "",
                startOffset: Int? = nil,
                length: Int? = nil) {
        self.prefix = prefix
        self.suffix = suffix
        self.startOffset = startOffset
        self.length = length
    }
}

/// Agent 对话的来源引用。P1 只留数据结构，高保真填充留给 P2 连接器。
public struct ConversationRef: Codable, Sendable, Equatable {
    public var sessionID: String?
    public var messageRole: String?
    public var turn: Int?

    public init(sessionID: String? = nil, messageRole: String? = nil, turn: Int? = nil) {
        self.sessionID = sessionID
        self.messageRole = messageRole
        self.turn = turn
    }
}

/// 选区来源：从哪来、叫什么、地址/路径是什么。
public struct SelectionSource: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case web, agent, markdown, note, app, clipboard
        /// 本地 PDF（PDFKit 抽取正文）
        case pdf
        /// docx / pptx / xlsx 等 Office 文档（解压 XML 抽取正文）
        case document

        /// 给 UI / Prompt 用的中文类别名
        public var displayName: String {
            switch self {
            case .web: return "网页"
            case .agent: return "AI 对话"
            case .markdown: return "Markdown"
            case .note: return "笔记"
            case .pdf: return "PDF"
            case .document: return "文档"
            case .app: return "应用"
            case .clipboard: return "剪贴板"
            }
        }

        /// 来源行左侧的小图标（和现有面板的 🔍/🧠 风格一致）
        public var symbol: String {
            switch self {
            case .web: return "🌐"
            case .agent: return "💬"
            case .markdown, .note: return "📝"
            case .pdf, .document: return "📄"
            case .clipboard: return "📋"
            case .app: return "🪟"
            }
        }
    }

    public var kind: Kind
    public var appName: String?
    public var bundleID: String?
    public var title: String?
    public var url: String?
    public var filePath: String?
    public var vaultName: String?
    public var headingPath: [String]?
    public var anchor: TextAnchor?
    public var conversation: ConversationRef?

    public init(kind: Kind,
                appName: String? = nil,
                bundleID: String? = nil,
                title: String? = nil,
                url: String? = nil,
                filePath: String? = nil,
                vaultName: String? = nil,
                headingPath: [String]? = nil,
                anchor: TextAnchor? = nil,
                conversation: ConversationRef? = nil) {
        self.kind = kind
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.url = url
        self.filePath = filePath
        self.vaultName = vaultName
        self.headingPath = headingPath
        self.anchor = anchor
        self.conversation = conversation
    }

    /// 问题条上方那行来源摘要：`🌐 网页 · RAG 是什么`
    public var displayLine: String {
        var parts = ["\(kind.symbol) \(kind.displayName)"]
        if let detail = displayDetail {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    /// 来源的具体标识：优先标题，其次文件名，再其次 URL host / App 名。
    public var displayDetail: String? {
        if let title = Self.cleaned(title) {
            return title
        }
        if let path = Self.cleaned(filePath) {
            return (path as NSString).lastPathComponent
        }
        if let url = Self.cleaned(url), let host = URL(string: url)?.host {
            return host
        }
        return Self.cleaned(appName)
    }

    /// Markdown 投影里的来源行（不含换行）。
    ///
    /// 网页写成可点击链接；文件写成路径 + 标题层级；其余写成「类别 · 标题」。
    /// 注意：行内链接的标题/URL 做最小转义，避免 `]` `)` 把 Markdown 结构打断。
    public var markdownSourceLine: String {
        if let url = Self.cleaned(url), url.hasPrefix("http://") || url.hasPrefix("https://") {
            let label = Self.cleaned(title) ?? Self.cleaned(appName) ?? url
            return "> 来源：[\(Self.escapedLinkText(label))](\(Self.escapedLinkDestination(url)))"
        }
        if let path = Self.cleaned(filePath) {
            var line = "> 来源：\(path)"
            if let headings = headingPath?.filter({ !$0.isEmpty }), !headings.isEmpty {
                line += " › " + headings.joined(separator: " > ")
            }
            return Self.oneLine(line)
        }
        var parts = ["\(kind.symbol) \(kind.displayName)"]
        if let detail = displayDetail { parts.append(detail) }
        return Self.oneLine("> 来源：" + parts.joined(separator: " · "))
    }

    // MARK: - 清理

    static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = oneLine(text)
        return value.isEmpty ? nil : value
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapedLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapedLinkDestination(_ url: String) -> String {
        url.replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
    }
}

/// 外部选区进入 Sprig 的统一协议。
///
/// P0 的来源：`sprig://explain`、Services、剪贴板；P1 再加 AX 全局取词。
/// P2 的浏览器/Obsidian/DSH 连接器也复用同一结构。
public struct SelectionEnvelope: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// 任何入口都不接受超过这个长度的选区（设置上限再小，取两者较小值）
    public static let absoluteMaxSelectionLength = 2_000
    /// URL scheme 入口的硬上限：避免 URL 过长
    public static let urlMaxSelectionLength = 500
    public static let urlMaxContextLength = 1_000

    public var version: Int
    public var source: SelectionSource
    public var selection: String
    /// 入口方直接提供的上下文（可选）。P0 只有 URL scheme 的 `context` 参数会给。
    public var context: String?
    public var question: String?
    /// 选区是否被截断（UI 可提示）；旧数据没有这个字段时为 nil
    public var selectionTruncated: Bool?

    public init(version: Int = SelectionEnvelope.currentVersion,
                source: SelectionSource,
                selection: String,
                context: String? = nil,
                question: String? = nil,
                selectionTruncated: Bool? = nil) {
        self.version = version
        self.source = source
        self.selection = selection
        self.context = context
        self.question = question
        self.selectionTruncated = selectionTruncated
    }

    // MARK: - 入口解析

    /// 解析 `sprig://explain?...`。只做纯数据校验，不碰 UI / 网络。
    public static func from(url: URL) -> SelectionEnvelope? {
        guard let scheme = url.scheme?.lowercased(), scheme == "sprig",
              let host = url.host?.lowercased(), host == "explain" else { return nil }

        // 自己解析 query：URLComponents 对「已经被百分号编码过一次」的 URL
        // 不一定再解一层，导致 url 参数变成 `https%3A%2F%2F…`。这里最多解三层，
        // 兼容 LaunchServices 和手工 open 两种传入形态。
        let pairs = queryPairs(from: url)
        var values: [String: String] = [:]
        for (name, value) in pairs where name != "text" {
            if values[name] == nil { values[name] = value }
        }
        let rawText = pairs.first { $0.0 == "text" && !$0.1.isEmpty }?.1
        guard let rawText else { return nil }

        let normalized = normalizeSelection(rawText, limit: urlMaxSelectionLength)
        guard !normalized.text.isEmpty else { return nil }

        var context = values["context"].map { normalizeContext($0, limit: urlMaxContextLength) }
        if let value = context, value.isEmpty { context = nil }

        let title = clamp(values["title"], limit: 200)
        let rawURL = clamp(values["url"], limit: 4_000)
        let filePath = clamp(values["path"], limit: 4_000).flatMap(validFilePath)
        let appName = clamp(values["app"], limit: 100)
        let question = clamp(values["question"], limit: 500)

        let kind = values["kind"]
            .flatMap { SelectionSource.Kind(rawValue: $0.lowercased()) }
            ?? inferKind(url: rawURL, filePath: filePath, appName: appName)

        let source = SelectionSource(kind: kind,
                                     appName: appName,
                                     title: title,
                                     url: validWebURL(rawURL),
                                     filePath: filePath)
        return SelectionEnvelope(source: source,
                                 selection: normalized.text,
                                 context: context,
                                 question: question,
                                 selectionTruncated: normalized.truncated ? true : nil)
    }

    private static func queryPairs(from url: URL) -> [(String, String)] {
        guard let mark = url.absoluteString.firstIndex(of: "?") else { return [] }
        let query = url.absoluteString[url.absoluteString.index(after: mark)...]
        return query.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decodeQueryComponent(String(parts[0]))
            let value = parts.count > 1 ? decodeQueryComponent(String(parts[1])) : ""
            return (name, value)
        }
    }

    private static func decodeQueryComponent(_ raw: String) -> String {
        var value = raw
        for _ in 0..<3 {
            guard let decoded = value.removingPercentEncoding, decoded != value else { break }
            value = decoded
        }
        return value
    }

    /// 把任意来源的选区清洗到可用状态。
    /// - 选区会被压成单行（问题条和标题都按单行处理），多段内容进上下文。
    public static func normalizeSelection(_ raw: String,
                                          limit: Int) -> (text: String, truncated: Bool) {
        let single = SelectionSource.oneLine(raw)
        let clamped = min(max(limit, 1), absoluteMaxSelectionLength)
        var text = single
        var truncated = false
        if text.count > clamped {
            text = String(text.prefix(clamped)).trimmingCharacters(in: .whitespacesAndNewlines)
            truncated = true
        }
        return (stripControls(text), truncated)
    }

    /// 上下文保留换行，只做长度截断。
    public static func normalizeContext(_ raw: String, limit: Int) -> String {
        let value = stripControls(raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }
        return String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// 应用设置里的选区上限（调用方传 Settings 值；这里再兜一层绝对上限）。
    public func normalized(maxSelectionLength: Int) -> SelectionEnvelope {
        let clamped = min(max(maxSelectionLength, 1), Self.absoluteMaxSelectionLength)
        guard selection.count > clamped else { return self }
        var copy = self
        copy.selection = Self.stripControls(String(selection.prefix(clamped)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        copy.selectionTruncated = true
        return copy
    }

    // MARK: - 内部

    private static func clamp(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let value = stripControls(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count <= limit { return value }
        return String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inferKind(url: String?, filePath: String?, appName: String?) -> SelectionSource.Kind {
        if let url, isWebURL(url) { return .web }
        if filePath != nil { return .markdown }
        if appName != nil { return .app }
        return .app
    }

    private static func validWebURL(_ raw: String?) -> String? {
        guard let raw, isWebURL(raw) else { return nil }
        return raw
    }

    static func isWebURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private static func validFilePath(_ raw: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return expanded
    }

    private static func stripControls(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            return !CharacterSet.controlCharacters.contains(scalar)
        }.map(Character.init))
    }
}
