import XCTest
@testable import SprigCore

final class SelectionEnvelopeTests: XCTestCase {
    // MARK: - URL 解析

    func testParsesAllURLParameters() throws {
        let url = try XCTUnwrap(URL(string: "sprig://explain"
            + "?text=幻觉"
            + "&title=RAG"
            + "&url=https%3A%2F%2Fexample.com%2Fa"
            + "&kind=web"
            + "&app=Safari"
            + "&context=上下文"
            + "&question=为什么"))
        let envelope = try XCTUnwrap(SelectionEnvelope.from(url: url))
        XCTAssertEqual(envelope.version, SelectionEnvelope.currentVersion)
        XCTAssertEqual(envelope.selection, "幻觉")
        XCTAssertEqual(envelope.source.kind, .web)
        XCTAssertEqual(envelope.source.title, "RAG")
        XCTAssertEqual(envelope.source.url, "https://example.com/a")
        XCTAssertEqual(envelope.source.appName, "Safari")
        XCTAssertEqual(envelope.context, "上下文")
        XCTAssertEqual(envelope.question, "为什么")
    }

    func testInfersKindFromURL() throws {
        let url = try XCTUnwrap(URL(string: "sprig://explain?text=hi&url=https%3A%2F%2Fexample.com"))
        XCTAssertEqual(SelectionEnvelope.from(url: url)?.source.kind, .web)
    }

    func testInfersKindFromPath() throws {
        let url = try XCTUnwrap(URL(string: "sprig://explain?text=hi&path=%2Ftmp%2Fnote.md"))
        let envelope = try XCTUnwrap(SelectionEnvelope.from(url: url))
        XCTAssertEqual(envelope.source.kind, .markdown)
        XCTAssertEqual(envelope.source.filePath, "/tmp/note.md")
    }

    func testInfersKindWithoutHintsAsApp() throws {
        let url = try XCTUnwrap(URL(string: "sprig://explain?text=hi"))
        XCTAssertEqual(SelectionEnvelope.from(url: url)?.source.kind, .app)
    }

    func testTildePathIsExpanded() throws {
        let url = try XCTUnwrap(URL(string: "sprig://explain?text=hi&path=~%2Fnote.md"))
        let envelope = try XCTUnwrap(SelectionEnvelope.from(url: url))
        XCTAssertTrue(envelope.source.filePath?.hasPrefix("/") == true)
        XCTAssertTrue(envelope.source.filePath?.hasSuffix("/note.md") == true)
    }

    func testRejectsMissingOrEmptyText() throws {
        XCTAssertNil(SelectionEnvelope.from(url: try XCTUnwrap(URL(string: "sprig://explain?title=x"))))
        XCTAssertNil(SelectionEnvelope.from(url: try XCTUnwrap(URL(string: "sprig://explain?text=%20%20"))))
    }

    func testRejectsWrongSchemeOrHost() throws {
        XCTAssertNil(SelectionEnvelope.from(url: try XCTUnwrap(URL(string: "https://explain?text=x"))))
        XCTAssertNil(SelectionEnvelope.from(url: try XCTUnwrap(URL(string: "sprig://demo?text=x"))))
    }

    func testDropsNonHTTPURLButKeepsSelection() throws {
        let url = try XCTUnwrap(URL(string: "sprig://explain?text=hi&url=javascript%3Aalert(1)&kind=web"))
        let envelope = try XCTUnwrap(SelectionEnvelope.from(url: url))
        XCTAssertNil(envelope.source.url)
        XCTAssertEqual(envelope.selection, "hi")
    }

    func testURLCapsSelectionAt500() throws {
        let text = String(repeating: "a", count: 600)
        let url = try XCTUnwrap(URL(string: "sprig://explain?text=\(text)"))
        let envelope = try XCTUnwrap(SelectionEnvelope.from(url: url))
        XCTAssertEqual(envelope.selection.count, SelectionEnvelope.urlMaxSelectionLength)
        XCTAssertEqual(envelope.selectionTruncated, true)
    }

    func testNormalizeSelectionCollapsesNewlinesAndControls() {
        let parsed = SelectionEnvelope.normalizeSelection("  第一行\n第二行\u{0007}  ", limit: 500)
        XCTAssertEqual(parsed.text, "第一行 第二行")
        XCTAssertFalse(parsed.truncated)
    }

    func testNormalizedRespectsConfiguredLimit() {
        let envelope = SelectionEnvelope(source: SelectionSource(kind: .app),
                                         selection: String(repeating: "字", count: 700))
        let limited = envelope.normalized(maxSelectionLength: 500)
        XCTAssertEqual(limited.selection.count, 500)
        XCTAssertEqual(limited.selectionTruncated, true)

        let untouched = envelope.normalized(maxSelectionLength: 800)
        XCTAssertEqual(untouched.selection.count, 700)
        XCTAssertNil(untouched.selectionTruncated)
    }

    func testLimitedCannotExceedAbsoluteMax() {
        let envelope = SelectionEnvelope(source: SelectionSource(kind: .app),
                                         selection: String(repeating: "字", count: 3_000))
        let limited = envelope.normalized(maxSelectionLength: 99_999)
        XCTAssertEqual(limited.selection.count, SelectionEnvelope.absoluteMaxSelectionLength)
    }

    // MARK: - Codable / 卡片兼容

    func testEnvelopeCodableRoundTrip() throws {
        let source = SelectionSource(kind: .note,
                                     appName: "Obsidian",
                                     title: "RAG 笔记",
                                     filePath: "/vault/RAG.md",
                                     vaultName: "notes",
                                     headingPath: ["RAG", "检索"],
                                     anchor: TextAnchor(prefix: "前", suffix: "后", startOffset: 12, length: 3))
        let envelope = SelectionEnvelope(source: source,
                                         selection: "幻觉",
                                         context: "上下文",
                                         question: "解释",
                                         selectionTruncated: true)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(SelectionEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func testOldAnswerCardJSONWithoutNewFieldsStillDecodes() throws {
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111",
          "title":"RAG",
          "question":"什么是 RAG？",
          "answer":"检索增强生成。",
          "createdAt": 700000000}]
        """
        let cards = try JSONDecoder().decode([AnswerCard].self, from: Data(json.utf8))
        XCTAssertEqual(cards.count, 1)
        XCTAssertNil(cards[0].source)
        XCTAssertNil(cards[0].contextSnapshot)
    }

    func testAnswerCardWithSourceRoundTrips() throws {
        let card = AnswerCard(title: "幻觉",
                              question: "",
                              selectedText: "幻觉",
                              source: SelectionSource(kind: .web,
                                                      title: "RAG",
                                                      url: "https://example.com/a"),
                              contextSnapshot: "上下文快照")
        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(AnswerCard.self, from: data)
        XCTAssertEqual(decoded.source, card.source)
        XCTAssertEqual(decoded.contextSnapshot, "上下文快照")
    }
}
