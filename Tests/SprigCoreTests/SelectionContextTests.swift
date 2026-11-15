import XCTest
@testable import SprigCore

final class SelectionContextTests: XCTestCase {
    private func webEnvelope(selection: String = "幻觉",
                             context: String? = nil,
                             question: String? = nil) -> SelectionEnvelope {
        SelectionEnvelope(source: SelectionSource(kind: .web,
                                                  appName: "Safari",
                                                  title: "RAG 是什么",
                                                  url: "https://example.com/rag"),
                          selection: selection,
                          context: context,
                          question: question)
    }

    // MARK: - 预算

    func testLocalPolicyUsesTightBudget() {
        let policy = SelectionContextAssembler.Policy.dynamic(isLocal: true,
                                                              contextTokens: 1_000_000,
                                                              selectionCap: 2_000)
        XCTAssertEqual(policy.selectionLimit, 500)
        XCTAssertEqual(policy.contextLimit, 600)
    }

    func testCloudPolicyGrowsWithWindowAndRespectsSelectionCap() {
        let small = SelectionContextAssembler.Policy.dynamic(isLocal: false,
                                                             contextTokens: 8_000,
                                                             selectionCap: 500)
        XCTAssertEqual(small.selectionLimit, 500)

        let large = SelectionContextAssembler.Policy.dynamic(isLocal: false,
                                                             contextTokens: 1_048_576,
                                                             selectionCap: 2_000)
        XCTAssertEqual(large.selectionLimit, 1_000)
        XCTAssertLessThanOrEqual(large.contextLimit, 2_000)
    }

    func testToolReserveShrinksCloudContext() {
        let lean = SelectionContextAssembler.Policy.dynamic(isLocal: false,
                                                            contextTokens: 128_000,
                                                            toolReserve: 0,
                                                            selectionCap: 500)
        let reserved = SelectionContextAssembler.Policy.dynamic(isLocal: false,
                                                                contextTokens: 128_000,
                                                                toolReserve: 3_000,
                                                                selectionCap: 500)
        XCTAssertLessThan(reserved.contextLimit, lean.contextLimit)
    }

    // MARK: - 消息模板

    func testMessageContainsSourceContextAndSelection() {
        let envelope = webEnvelope(context: "RAG 会缓解模型的幻觉问题。")
        let message = SelectionContextAssembler.message(
            envelope: envelope,
            context: envelope.context,
            policy: .init(selectionLimit: 500, contextLimit: 2_000))

        XCTAssertTrue(message.contains("【选词来源】"))
        XCTAssertTrue(message.contains("类型：网页"))
        XCTAssertTrue(message.contains("标题：RAG 是什么"))
        XCTAssertTrue(message.contains("地址：https://example.com/rag"))
        XCTAssertTrue(message.contains("【所在上下文】"))
        XCTAssertTrue(message.contains("«幻觉»"))
        XCTAssertTrue(message.contains("【选中的片段】"))
        XCTAssertTrue(message.contains("【任务】"))
        XCTAssertTrue(message.contains("在【所在上下文】中的含义"))
    }

    func testMessageWithoutContextOmitsContextSection() {
        let message = SelectionContextAssembler.message(
            envelope: webEnvelope(),
            context: nil,
            policy: .init(selectionLimit: 500, contextLimit: 2_000))
        XCTAssertFalse(message.contains("【所在上下文】"))
        XCTAssertTrue(message.contains("请解释【选中的片段】的含义"))
    }

    func testMessageIncludesHeadingPathAndQuestion() {
        let source = SelectionSource(kind: .note,
                                     title: "RAG 笔记",
                                     filePath: "/vault/RAG.md",
                                     vaultName: "notes",
                                     headingPath: ["RAG", "检索"])
        let envelope = SelectionEnvelope(source: source,
                                         selection: "召回率",
                                         context: "检索阶段通常看召回率。",
                                         question: "它和准确率什么关系？")
        let message = SelectionContextAssembler.message(
            envelope: envelope,
            context: envelope.context,
            policy: .init(selectionLimit: 500, contextLimit: 2_000))
        XCTAssertTrue(message.contains("文件：/vault/RAG.md"))
        XCTAssertTrue(message.contains("库：notes"))
        XCTAssertTrue(message.contains("位置：RAG › 检索"))
        XCTAssertTrue(message.contains("【我的问题】"))
        XCTAssertTrue(message.contains("它和准确率什么关系？"))
    }

    func testSelectionIsTruncatedByPolicy() {
        let envelope = webEnvelope(selection: String(repeating: "字", count: 80))
        let message = SelectionContextAssembler.message(
            envelope: envelope,
            context: nil,
            policy: .init(selectionLimit: 50, contextLimit: 2_000))
        XCTAssertTrue(message.contains(String(repeating: "字", count: 50)))
        XCTAssertFalse(message.contains(String(repeating: "字", count: 51)))
    }

    // MARK: - 上下文截取

    func testExcerptMarksSelection() {
        let excerpt = SelectionContextAssembler.excerpt(
            from: "RAG 会缓解模型的幻觉问题，但无法彻底消除。",
            selection: "幻觉",
            limit: 2_000)
        XCTAssertEqual(excerpt, "RAG 会缓解模型的«幻觉»问题，但无法彻底消除。")
    }

    func testExcerptCentersOnSelectionWhenTooLong() throws {
        let text = String(repeating: "前", count: 5_000) + "幻觉" + String(repeating: "后", count: 5_000)
        let excerpt = try XCTUnwrap(SelectionContextAssembler.excerpt(from: text,
                                                                     selection: "幻觉",
                                                                     limit: 300))
        XCTAssertTrue(excerpt.contains("«幻觉»"))
        // 窗口 300 字 + 两侧省略号 + «» 标记
        XCTAssertLessThanOrEqual(excerpt.count, 304)
        XCTAssertTrue(excerpt.hasPrefix("…"))
        XCTAssertTrue(excerpt.hasSuffix("…"))
    }

    func testExcerptFallsBackWhenSelectionNotFound() {
        let text = String(repeating: "正文。", count: 400)
        let excerpt = SelectionContextAssembler.excerpt(from: text, selection: "不存在的词", limit: 120)
        XCTAssertNotNil(excerpt)
        XCTAssertFalse(excerpt!.contains("«"))
        XCTAssertTrue(excerpt!.hasSuffix("…"))
    }

    func testExcerptCrossLineSelection() {
        let excerpt = SelectionContextAssembler.excerpt(from: "第一行\n幻觉\n第三行",
                                                        selection: "第一行 幻觉",
                                                        limit: 2_000)
        XCTAssertNotNil(excerpt)
        XCTAssertTrue(excerpt?.contains("«第一行\n幻觉»") == true)
    }

    // MARK: - Prompt 封装

    func testPromptSelectionMessageMatchesAssembler() {
        let envelope = webEnvelope(context: "上下文")
        let policy = SelectionContextAssembler.Policy(selectionLimit: 500, contextLimit: 2_000)
        XCTAssertEqual(Prompt.selectionMessage(envelope: envelope,
                                               context: envelope.context,
                                               policy: policy),
                       SelectionContextAssembler.message(envelope: envelope,
                                                         context: envelope.context,
                                                         policy: policy))
    }

    // MARK: - 追问上下文里的来源快照

    func testContextAssemblerIncludesSourceSnapshotOnce() {
        let policy = ContextAssembler.Policy.cloud
        let path = [
            ContextAssembler.Node(title: "来源", question: "", answer: "",
                                  sourceSnapshot: "第一个来源上下文"),
            ContextAssembler.Node(title: "追问", question: "这是什么意思？", answer: "回答",
                                  sourceSnapshot: "第二个来源上下文"),
            ContextAssembler.Node(title: "当前", question: "继续问", answer: "当前回答"),
        ]
        let context = ContextAssembler.context(path: path, policy: policy)
        XCTAssertTrue(context.contains("【来源上下文】"))
        XCTAssertTrue(context.contains("第二个来源上下文"))
        XCTAssertFalse(context.contains("第一个来源上下文"), "只取最近一个来源快照")
    }

    func testContextAssemblerSkipsEmptySnapshots() {
        let policy = ContextAssembler.Policy.cloud
        let path = [
            ContextAssembler.Node(title: "根", question: "问题", answer: "回答", sourceSnapshot: "   "),
            ContextAssembler.Node(title: "当前", question: "继续", answer: "当前回答"),
        ]
        let context = ContextAssembler.context(path: path, policy: policy)
        XCTAssertFalse(context.contains("【来源上下文】"))
    }

    // MARK: - Markdown 来源行

    func testWebSourceBecomesMarkdownLink() {
        let card = AnswerCard(title: "幻觉",
                              question: "",
                              selectedText: "幻觉",
                              source: SelectionSource(kind: .web,
                                                      title: "RAG 是什么",
                                                      url: "https://example.com/rag"))
        let body = CardMarkdown.files(from: [card]).first?.body ?? ""
        XCTAssertTrue(body.contains("> 选中：幻觉"))
        XCTAssertTrue(body.contains("> 来源：[RAG 是什么](https://example.com/rag)"))
    }

    func testFileSourceIncludesHeadingPath() {
        let card = AnswerCard(title: "召回率",
                              question: "",
                              selectedText: "召回率",
                              source: SelectionSource(kind: .note,
                                                      filePath: "/vault/RAG.md",
                                                      headingPath: ["RAG", "检索"]))
        let body = CardMarkdown.files(from: [card]).first?.body ?? ""
        XCTAssertTrue(body.contains("> 来源：/vault/RAG.md › RAG > 检索"))
    }

    func testMarkdownDoesNotLeakContextSnapshot() {
        let card = AnswerCard(title: "幻觉",
                              question: "",
                              selectedText: "幻觉",
                              source: SelectionSource(kind: .web, title: "RAG", url: "https://example.com"),
                              contextSnapshot: "这段上下文只应存在 JSON 里")
        let body = CardMarkdown.files(from: [card]).first?.body ?? ""
        XCTAssertFalse(body.contains("这段上下文只应存在 JSON 里"))
    }

    func testSourceDisplayLine() {
        let source = SelectionSource(kind: .web, title: "RAG 是什么", url: "https://example.com")
        XCTAssertEqual(source.displayLine, "🌐 网页 · RAG 是什么")

        let clipboard = SelectionSource(kind: .clipboard)
        XCTAssertEqual(clipboard.displayLine, "📋 剪贴板")
    }
}
