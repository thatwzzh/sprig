import Foundation

/// 来源上下文解析的配置。UI 层从 Settings 组装。
public struct SourceResolverOptions: Sendable, Equatable {
    public var fetchWebContext: Bool
    public var documentFolders: [String]
    public var obsidianVaults: [ObsidianVault]
    public var contextLimit: Int
    public var webTimeout: TimeInterval

    public init(fetchWebContext: Bool = true,
                documentFolders: [String] = [],
                obsidianVaults: [ObsidianVault] = [],
                contextLimit: Int = 1_200,
                webTimeout: TimeInterval = 8) {
        self.fetchWebContext = fetchWebContext
        self.documentFolders = documentFolders
        self.obsidianVaults = obsidianVaults
        self.contextLimit = contextLimit
        self.webTimeout = webTimeout
    }
}

public struct ResolvedSourceContext: Sendable, Equatable {
    public enum Quality: String, Sendable {
        /// 入口方直接给了上下文（P2 连接器的高保真路径）
        case provided
        /// 网页抓取并定位到选区
        case web
        /// 本地 Markdown/文本文件里定位到选区
        case document
        /// AX 拿到的周边文字
        case surrounding
        /// 只有来源元信息，没有上下文
        case titleOnly
        case none
    }

    public var source: SelectionSource
    public var context: String?
    public var quality: Quality

    public init(source: SelectionSource, context: String?, quality: Quality) {
        self.source = source
        self.context = context
        self.quality = quality
    }
}

/// 把「来源线索」变成可读上下文。
///
/// 优先级（和设计文档一致）：
/// 1. 入口方提供的 context；
/// 2. 已知文件路径 → 读文件定位；
/// 3. AX 周边文字（必须真的包含选区）——来自用户正在看的界面，通常比整页抓取更贴题；
/// 4. 网页 URL → 抓页面定位；
/// 5. 窗口标题 + 已配置文档目录/Obsidian 库 → 反查文件；
/// 6. 只有来源元信息。
public enum SourceContextResolver {
    public static func resolve(envelope: SelectionEnvelope,
                               fallbackContext: String? = nil,
                               options: SourceResolverOptions,
                               webFetcher: WebPageContext.Fetcher? = nil) async -> ResolvedSourceContext {
        var source = envelope.source
        // 普通模式 1200 字；深度上下文模式允许解析到 6000 字再压缩
        let limit = min(max(options.contextLimit, 200), 6_000)

        if let provided = cleanedContext(envelope.context, limit: limit) {
            return ResolvedSourceContext(source: source, context: provided, quality: .provided)
        }

        // 2. 明确的文件路径
        if let filePath = source.filePath,
           let result = DocumentContext.context(filePath: filePath,
                                                selection: envelope.selection,
                                                limit: limit,
                                                vaultName: source.vaultName) {
            source = enrich(result.source, from: source)
            return ResolvedSourceContext(source: source,
                                         context: cleanedContext(result.excerpt, limit: limit),
                                         quality: .document)
        }

        // 3. AX 周边文字：先定位选区再按段落裁，避免把样式表/无关文本发给模型
        if let fallbackContext,
           let surrounding = SelectionTextExcerpt.excerpt(from: fallbackContext,
                                                         selection: envelope.selection,
                                                         limit: limit) {
            return ResolvedSourceContext(source: source, context: surrounding, quality: .surrounding)
        }

        // 4. 网页抓取
        if source.kind == .web,
           options.fetchWebContext,
           let url = source.url {
            if let result = await WebPageContext.context(url: url,
                                                         selection: envelope.selection,
                                                         limit: limit,
                                                         timeout: options.webTimeout,
                                                         fetcher: webFetcher) {
                source.title = result.title
                source.url = result.url
                if result.foundSelection, let excerpt = cleanedContext(result.excerpt, limit: limit) {
                    return ResolvedSourceContext(source: source, context: excerpt, quality: .web)
                }
            }
        }

        // 5. 窗口标题反查本地文档（网页来源不参与，避免页面标题撞上同名笔记）
        if source.kind != .web,
           source.filePath == nil,
           let located = DocumentLocator.locate(title: source.title,
                                                documentFolders: options.documentFolders,
                                                vaults: options.obsidianVaults),
           let result = DocumentContext.context(filePath: located.path,
                                                selection: envelope.selection,
                                                limit: limit,
                                                vaultName: located.vaultName) {
            source = enrich(result.source, from: source)
            source.vaultName = located.vaultName ?? source.vaultName
            if source.kind == .app {
                source.kind = located.vaultName != nil ? .note : result.source.kind
            }
            return ResolvedSourceContext(source: source,
                                         context: cleanedContext(result.excerpt, limit: limit),
                                         quality: .document)
        }

        // 6. 只有来源元信息
        let hasMetadata = source.displayDetail != nil
        return ResolvedSourceContext(source: source,
                                     context: nil,
                                     quality: hasMetadata ? .titleOnly : .none)
    }

    private static func enrich(_ document: SelectionSource,
                               from original: SelectionSource) -> SelectionSource {
        var result = document
        result.kind = original.kind == .note ? .note : document.kind
        result.url = original.url
        result.appName = original.appName
        result.bundleID = original.bundleID
        result.vaultName = original.vaultName ?? document.vaultName
        return result
    }

    /// 忽略空白后判断上下文里是否真的含选区
    static func containsSelection(_ context: String, selection: String) -> Bool {
        let normalizedContext = context.filter { !$0.isWhitespace }
        let normalizedSelection = selection.filter { !$0.isWhitespace }
        guard !normalizedSelection.isEmpty else { return false }
        return normalizedContext.contains(normalizedSelection)
    }

    private static func cleanedContext(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let value = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return SelectionEnvelope.normalizeContext(value, limit: limit)
    }
}
