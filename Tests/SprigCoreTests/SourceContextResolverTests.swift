import XCTest
@testable import SprigCore

final class SourceContextResolverTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func write(_ text: String, at relativePath: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let markdown = """
    # RAG

    RAG 是检索增强生成。

    ## 检索

    检索阶段通常看召回率；把文本转成向量后按相似度找最相近的几段。

    ### 向量数据库

    向量数据库负责存向量并做近邻搜索。

    ## 生成

    生成阶段把检索到的内容交给模型。
    """

    // MARK: - DocumentContext

    func testDocumentContextFindsHeadingPathAndExcerpt() throws {
        let url = try write(markdown, at: "notes/RAG.md")
        let result = try XCTUnwrap(DocumentContext.context(filePath: url.path,
                                                           selection: "召回率",
                                                           limit: 2_000))
        XCTAssertEqual(result.source.headingPath, ["RAG", "检索"])
        XCTAssertTrue(result.excerpt.contains("召回率"))
        XCTAssertTrue(result.excerpt.contains("检索阶段"))
        XCTAssertEqual(result.source.filePath, url.path)
        XCTAssertEqual(result.source.kind, .markdown)
        XCTAssertNotNil(result.source.anchor)
    }

    func testDocumentContextCrossLineSelection() throws {
        let url = try write(markdown, at: "RAG.md")
        let result = try XCTUnwrap(DocumentContext.context(filePath: url.path,
                                                           selection: "检索阶段通常看召回率",
                                                           limit: 2_000))
        XCTAssertTrue(result.excerpt.contains("召回率"))
    }

    func testHeadingPathSkipsFencedCode() throws {
        let text = """
        # 标题

        ```
        # 这不是标题
        ```

        ## 真标题

        目标文字在这里。
        """
        let url = try write(text, at: "code.md")
        let result = try XCTUnwrap(DocumentContext.context(filePath: url.path,
                                                           selection: "目标文字",
                                                           limit: 2_000))
        XCTAssertEqual(result.source.headingPath, ["标题", "真标题"])
    }

    func testDocumentContextStaysNearSelectionParagraph() throws {
        var paragraphs: [String] = []
        for index in 0..<10 {
            paragraphs.append("段落\(index)：" + String(repeating: "字", count: 180) + " 目标\(index)")
        }
        let text = paragraphs.joined(separator: "\n\n")
        let url = try write(text, at: "long.md")
        let result = try XCTUnwrap(DocumentContext.context(filePath: url.path,
                                                           selection: "目标4",
                                                           limit: 500))
        XCTAssertTrue(result.excerpt.contains("目标4"))
        XCTAssertFalse(result.excerpt.contains("目标0"), "不该把离得很远的段落也带上")
        XCTAssertLessThanOrEqual(result.excerpt.count, 500)
    }

    func testDocumentContextReturnsNilWhenSelectionMissing() throws {
        let url = try write(markdown, at: "RAG.md")
        XCTAssertNil(DocumentContext.context(filePath: url.path,
                                             selection: "不存在的词",
                                             limit: 2_000))
    }

    // MARK: - DocumentLocator

    func testTitleCandidatesStripVaultSuffix() {
        let vaults = [ObsidianVault(name: "notes", path: "/tmp/notes")]
        let candidates = DocumentLocator.titleCandidates(from: "RAG 笔记 - notes", vaults: vaults)
        XCTAssertEqual(candidates.first, "RAG 笔记 - notes")
        XCTAssertTrue(candidates.contains("RAG 笔记"))
    }

    func testTitleCandidatesStripEditorSuffix() {
        let candidates = DocumentLocator.titleCandidates(from: "RAG 笔记 - Obsidian", vaults: [])
        XCTAssertTrue(candidates.contains("RAG 笔记"))
        let code = DocumentLocator.titleCandidates(from: "main.swift — project - Code", vaults: [])
        XCTAssertTrue(code.contains("main.swift") || code.contains("main"))
    }

    func testLocatorFindsVaultNote() throws {
        let vaultRoot = tempRoot.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        _ = try write("# 检索\n\n召回率很重要。", at: "vault/知识/RAG.md")

        let located = DocumentLocator.locate(title: "RAG - vault",
                                            documentFolders: [],
                                            vaults: [ObsidianVault(name: "vault", path: vaultRoot.path)])
        XCTAssertEqual(located?.vaultName, "vault")
        XCTAssertTrue(located?.path.hasSuffix("vault/知识/RAG.md") == true)
    }

    func testLocatorFindsDocumentFolderFile() throws {
        let docs = tempRoot.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        _ = try write("# 笔记\n\n目标内容。", at: "docs/我的笔记.md")

        let located = DocumentLocator.locate(title: "我的笔记 - 某编辑器",
                                            documentFolders: [docs.path],
                                            vaults: [])
        XCTAssertNotNil(located)
        XCTAssertTrue(located?.path.hasSuffix("我的笔记.md") == true)
    }

    // MARK: - WebPageContext

    func testPublicURLCheck() {
        XCTAssertTrue(WebPageContext.isPublicHTTPURL(URL(string: "https://example.com/a")!))
        XCTAssertTrue(WebPageContext.isPublicHTTPURL(URL(string: "http://news.ycombinator.com")!))
        XCTAssertFalse(WebPageContext.isPublicHTTPURL(URL(string: "http://localhost:8080")!))
        XCTAssertFalse(WebPageContext.isPublicHTTPURL(URL(string: "http://127.0.0.1/")!))
        XCTAssertFalse(WebPageContext.isPublicHTTPURL(URL(string: "http://192.168.1.2/")!))
        XCTAssertFalse(WebPageContext.isPublicHTTPURL(URL(string: "http://10.0.0.1/")!))
        XCTAssertFalse(WebPageContext.isPublicHTTPURL(URL(string: "http://172.20.1.2/")!))
        XCTAssertFalse(WebPageContext.isPublicHTTPURL(URL(string: "http://169.254.1.1/")!))
        XCTAssertFalse(WebPageContext.isPublicHTTPURL(URL(string: "file:///tmp/a.html")!))
        XCTAssertFalse(WebPageContext.isPublicHTTPURL(URL(string: "https://foo.local/")!))
    }

    func testVisibleTextStripsMultilineStyleAndScript() {
        let html = """
        <html><head>
        <style>
        body { color: red; }
        .foo { margin: 0; }
        </style>
        <script>
        var x = 1;
        </script>
        </head><body>
        <p>真正的正文段落。</p>
        </body></html>
        """
        let text = WebPageContext.visibleText(fromHTML: html)
        XCTAssertFalse(text.contains("color: red"))
        XCTAssertFalse(text.contains("var x = 1"))
        XCTAssertTrue(text.contains("真正的正文段落"))
    }

    func testVisibleTextStripsScriptsAndDecodesEntities() {
        let html = """
        <html><head><title>RAG 是什么</title><style>p{color:red}</style></head>
        <body><script>alert(1)</script>
        <p>RAG 会缓解模型的幻觉问题 &amp; 提高可信度。</p>
        <script>var a = 1;</script>
        <p>第二段&nbsp;文字</p></body></html>
        """
        let text = WebPageContext.visibleText(fromHTML: html)
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("color:red"))
        XCTAssertTrue(text.contains("幻觉问题 & 提高可信度"))
        XCTAssertTrue(text.contains("第二段 文字"))
        XCTAssertEqual(WebPageContext.documentTitle(fromHTML: html), "RAG 是什么")
    }

    func testWebContextFindsSelectionWithInjectedFetcher() async {
        let html = "<html><head><title>RAG 是什么</title></head><body>"
            + "<p>RAG 会缓解模型的幻觉问题，但无法彻底消除。</p><p>其他段落。</p></body></html>"
        let fetcher: WebPageContext.Fetcher = { _ in (Data(html.utf8), "utf-8") }
        let result = await WebPageContext.context(url: "https://example.com/rag",
                                                  selection: "幻觉",
                                                  limit: 500,
                                                  fetcher: fetcher)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "RAG 是什么")
        XCTAssertEqual(result?.foundSelection, true)
        XCTAssertTrue(result?.excerpt?.contains("幻觉") == true)
    }

    func testWebContextSelectionMissing() async {
        let html = "<html><head><title>标题</title></head><body><p>别的内容。</p></body></html>"
        let fetcher: WebPageContext.Fetcher = { _ in (Data(html.utf8), "utf-8") }
        let result = await WebPageContext.context(url: "https://example.com/a",
                                                  selection: "不存在的词",
                                                  limit: 500,
                                                  fetcher: fetcher)
        XCTAssertEqual(result?.foundSelection, false)
    }

    func testWebContextRejectsPrivateURLBeforeFetching() async {
        let fetcher: WebPageContext.Fetcher = { _ in
            XCTFail("私网 URL 不应该发起请求")
            return (Data(), nil)
        }
        let result = await WebPageContext.context(url: "http://127.0.0.1/secret",
                                                  selection: "x",
                                                  limit: 500,
                                                  fetcher: fetcher)
        XCTAssertNil(result)
    }

    // MARK: - Resolver

    func testResolverUsesProvidedContextFirst() async {
        let envelope = SelectionEnvelope(source: SelectionSource(kind: .web,
                                                                 title: "RAG",
                                                                 url: "https://example.com"),
                                         selection: "幻觉",
                                         context: "入口方提供的上下文")
        let resolved = await SourceContextResolver.resolve(
            envelope: envelope,
            options: SourceResolverOptions(),
            webFetcher: { _ in XCTFail("有 provided context 时不该抓网页"); return (Data(), nil) })
        XCTAssertEqual(resolved.quality, .provided)
        XCTAssertEqual(resolved.context, "入口方提供的上下文")
    }

    func testResolverFindsLocalFileByPath() async throws {
        let url = try write(markdown, at: "RAG.md")
        let envelope = SelectionEnvelope(source: SelectionSource(kind: .app,
                                                                 title: "RAG",
                                                                 filePath: url.path),
                                         selection: "召回率")
        let resolved = await SourceContextResolver.resolve(envelope: envelope,
                                                          options: SourceResolverOptions())
        XCTAssertEqual(resolved.quality, .document)
        XCTAssertTrue(resolved.context?.contains("召回率") == true)
        XCTAssertEqual(resolved.source.headingPath, ["RAG", "检索"])
    }

    func testResolverFetchesWebPage() async {
        let html = "<html><head><title>RAG</title></head><body><p>RAG 会缓解幻觉。</p></body></html>"
        let envelope = SelectionEnvelope(source: SelectionSource(kind: .web,
                                                                 title: "RAG",
                                                                 url: "https://example.com/rag"),
                                         selection: "幻觉")
        let resolved = await SourceContextResolver.resolve(
            envelope: envelope,
            options: SourceResolverOptions(fetchWebContext: true),
            webFetcher: { _ in (Data(html.utf8), "utf-8") })
        XCTAssertEqual(resolved.quality, .web)
        XCTAssertTrue(resolved.context?.contains("幻觉") == true)
    }

    func testResolverPrefersValidSurroundingTextOverWebFetch() async {
        let html = "<html><head><title>RAG</title></head><body><p>页面正文里的幻觉。</p></body></html>"
        let envelope = SelectionEnvelope(source: SelectionSource(kind: .web,
                                                                 title: "RAG",
                                                                 url: "https://example.com/rag"),
                                         selection: "幻觉")
        var fetched = false
        let resolved = await SourceContextResolver.resolve(
            envelope: envelope,
            fallbackContext: "用户眼前的段落：RAG 会缓解模型的幻觉问题。",
            options: SourceResolverOptions(fetchWebContext: true),
            webFetcher: { _ in
                fetched = true
                return (Data(html.utf8), "utf-8")
            })
        XCTAssertEqual(resolved.quality, .surrounding)
        XCTAssertFalse(fetched, "AX 上下文有效时不应再抓网页")
        XCTAssertTrue(resolved.context?.contains("幻觉") == true)
    }

    func testResolverDropsSurroundingTextWithoutSelection() async {
        let envelope = SelectionEnvelope(source: SelectionSource(kind: .app, title: "某 App"),
                                         selection: "供应商")
        let resolved = await SourceContextResolver.resolve(
            envelope: envelope,
            fallbackContext: ".subs p { margin: 0; color: var(--ink2); }",
            options: SourceResolverOptions(fetchWebContext: false))
        XCTAssertEqual(resolved.quality, .titleOnly)
        XCTAssertNil(resolved.context)
    }

    func testResolverFallsBackToSurroundingText() async {
        let envelope = SelectionEnvelope(source: SelectionSource(kind: .app, title: "某对话"),
                                         selection: "幻觉")
        let resolved = await SourceContextResolver.resolve(
            envelope: envelope,
            fallbackContext: "这是从 AX 读到的周边文字，包含幻觉一词。",
            options: SourceResolverOptions())
        XCTAssertEqual(resolved.quality, .surrounding)
    }

    func testResolverFindsVaultNoteByTitle() async throws {
        let vaultRoot = tempRoot.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        _ = try write("# RAG\n\n## 检索\n\n召回率很重要。", at: "vault/RAG.md")

        let envelope = SelectionEnvelope(source: SelectionSource(kind: .note,
                                                                 appName: "Obsidian",
                                                                 title: "RAG - vault"),
                                         selection: "召回率")
        let resolved = await SourceContextResolver.resolve(
            envelope: envelope,
            options: SourceResolverOptions(fetchWebContext: false,
                                           obsidianVaults: [ObsidianVault(name: "vault", path: vaultRoot.path)]))
        XCTAssertEqual(resolved.quality, .document)
        XCTAssertEqual(resolved.source.vaultName, "vault")
        XCTAssertEqual(resolved.source.kind, .note)
        XCTAssertEqual(resolved.source.headingPath, ["RAG", "检索"])
    }

    func testResolverWithoutAnyHintReturnsTitleOnly() async {
        let envelope = SelectionEnvelope(source: SelectionSource(kind: .app, title: "未知来源"),
                                         selection: "词")
        let resolved = await SourceContextResolver.resolve(envelope: envelope,
                                                          options: SourceResolverOptions())
        XCTAssertEqual(resolved.quality, .titleOnly)
        XCTAssertNil(resolved.context)
    }
}
