import XCTest
@testable import SprigCore

final class TermParserTests: XCTestCase {
    func testPlainText() {
        var parser = TermParser()
        let out = parser.consume("因果推断是统计学的分支。")
        XCTAssertEqual(out, [.text("因果推断是统计学的分支。")])
    }

    func testSingleTerm() {
        var parser = TermParser()
        let out = parser.consume("核心是 ⟦do-calculus⟧，它区分干预与观测。")
        XCTAssertEqual(out, [.text("核心是 "), .term("do-calculus"), .text("，它区分干预与观测。")])
    }

    func testTermSplitAcrossChunks() {
        var parser = TermParser()
        var out: [StreamSegment] = []
        out += parser.consume("核心是 ⟦do-")
        out += parser.consume("calculus⟧ 结尾")
        XCTAssertEqual(out, [.text("核心是 "), .term("do-calculus"), .text(" 结尾")])
    }

    func testMarkerSplitAcrossChunks() {
        var parser = TermParser()
        var out: [StreamSegment] = []
        out += parser.consume("看 ⟦反向")
        out += parser.consume("传播⟧。")
        XCTAssertEqual(out, [.text("看 "), .term("反向传播"), .text("。")])
    }

    /// 未闭合期间不能提前吐半个术语；流结束时按纯文本补上，标记本身被丢掉
    func testUnclosedTermIsHeldThenFlushed() {
        var parser = TermParser()
        let out = parser.consume("这是 ⟦没闭合的术语")
        XCTAssertEqual(out, [.text("这是 ")])

        let tail = parser.flush()
        XCTAssertEqual(tail, [.text("没闭合的术语")])
    }

    func testNewlineInsideTermFallsBackToPlainText() {
        var parser = TermParser()
        let out = parser.consume("⟦第一行\n第二行⟧")
        XCTAssertEqual(out, [.text("第一行\n第二行")])
    }

    func testOverlongTermFallsBackAndSwallowsClosing() {
        var parser = TermParser(maxTermLength: 5)
        let out = parser.consume("⟦1234567890⟧后面")
        XCTAssertEqual(out, [.text("1234567890后面")])
    }

    func testEmptyTermIsDropped() {
        var parser = TermParser()
        let out = parser.consume("前⟦⟧后")
        XCTAssertEqual(out, [.text("前后")])
    }

    func testFlushEmitsDanglingMarker() {
        var parser = TermParser()
        _ = parser.consume("悬空 ⟦未完")
        let out = parser.flush()
        XCTAssertEqual(out, [.text("未完")])
    }

    func testMultipleTermsInOneChunk() {
        var parser = TermParser()
        let out = parser.consume("⟦A⟧与⟦B⟧")
        XCTAssertEqual(out, [.term("A"), .text("与"), .term("B")])
    }
}

final class CardStoreTests: XCTestCase {
    func testTreeUpsertChildrenAndPath() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-store-\(UUID().uuidString).json")
        let store = CardStore(fileURL: tmp)

        let root = AnswerCard(title: "RAG", question: "什么是 RAG？", answer: "RAG 是 ⟦检索增强生成⟧。")
        await store.upsert(root)

        let child = AnswerCard(parentID: root.id,
                               title: "幻觉",
                               question: "解释「幻觉」",
                               answer: "这里指模型编造事实。",
                               selectedText: "幻觉")
        await store.upsert(child)

        let children = await store.children(of: root.id)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.title, "幻觉")

        let path = await store.path(to: child.id)
        XCTAssertEqual(path.map(\.title), ["RAG", "幻觉"])

        let roots = await store.children(of: nil)
        XCTAssertEqual(roots.count, 1)

        await store.upsert(root)
        let all = await store.all()
        XCTAssertEqual(all.count, 2)

        try? FileManager.default.removeItem(at: tmp)
    }

    func testPlainAnswerStripsMarkers() {
        let card = AnswerCard(title: "x", question: "q", answer: "这是 ⟦术语⟧ 测试")
        XCTAssertEqual(card.plainAnswer, "这是 术语 测试")
    }

    func testRenameAndCascadeDelete() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-store-\(UUID().uuidString).json")
        let store = CardStore(fileURL: tmp)

        let root = AnswerCard(title: "RAG", question: "什么是 RAG？")
        let child = AnswerCard(parentID: root.id, title: "幻觉", question: "解释幻觉")
        let grandchild = AnswerCard(parentID: child.id, title: "虚构引用", question: "举例")
        await store.upsert(root)
        await store.upsert(child)
        await store.upsert(grandchild)

        await store.rename(id: child.id, title: "模型幻觉")
        let renamed = await store.card(id: child.id)
        XCTAssertEqual(renamed?.title, "模型幻觉")

        let removed = await store.delete(id: child.id)
        XCTAssertEqual(removed.count, 2)
        let remaining = await store.all()
        XCTAssertEqual(remaining.map(\.title), ["RAG"])

        try? FileManager.default.removeItem(at: tmp)
    }

    func testUseDirectoryMigratesExistingCards() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-move-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("old.json")
        let targetDir = root.appendingPathComponent("documents/a", isDirectory: true)

        let store = CardStore(fileURL: source)
        await store.upsert(AnswerCard(title: "RAG", question: "什么是 RAG？"))

        await store.useDirectory(targetDir)
        let migrated = await store.all()
        XCTAssertEqual(migrated.map(\.title), ["RAG"])

        let targetFile = await store.currentFileURL()
        XCTAssertEqual(targetFile.standardizedFileURL,
                       targetDir.appendingPathComponent(CardStore.fileName).standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))

        // 切到已有数据的目录：读目标库，不覆盖
        let otherDir = root.appendingPathComponent("other", isDirectory: true)
        let otherStore = CardStore(fileURL: otherDir.appendingPathComponent(CardStore.fileName))
        await otherStore.upsert(AnswerCard(title: "另一本书", question: "q"))

        await store.useDirectory(otherDir)
        let loaded = await store.all()
        XCTAssertEqual(loaded.map(\.title), ["另一本书"])

        try? FileManager.default.removeItem(at: root)
    }
}

final class ContextAssemblerTests: XCTestCase {
    func testNearestAnswerIsIncludedAndBudgetRespected() {
        let path = [
            ContextAssembler.Node(title: "根问题", question: "什么是 RAG？", answer: String(repeating: "根", count: 3000)),
            ContextAssembler.Node(title: "幻觉", question: "解释幻觉", answer: "幻觉指模型编造事实。"),
        ]
        let context = ContextAssembler.context(path: path, policy: .local)
        XCTAssertTrue(context.contains("【当前回答】（幻觉）"))
        XCTAssertTrue(context.contains("幻觉指模型编造事实。"))
        XCTAssertTrue(context.contains("【上级上下文】"))
        XCTAssertTrue(context.contains("根问题"))
        XCTAssertLessThan(context.count, 1500)
    }

    func testDistantAncestorsFallBackToQuestionOnly() {
        let path = [
            ContextAssembler.Node(title: "A", question: "问题A", answer: String(repeating: "a", count: 900)),
            ContextAssembler.Node(title: "B", question: "问题B", answer: String(repeating: "b", count: 900)),
            ContextAssembler.Node(title: "C", question: "问题C", answer: String(repeating: "c", count: 900)),
        ]
        // 本地策略：当前 1200 + 父级 600 之后预算基本用尽，更远的 A 只剩问题
        let context = ContextAssembler.context(path: path, policy: .local)
        XCTAssertTrue(context.contains("问题C"))
        XCTAssertTrue(context.contains("问题B"))
        XCTAssertLessThan(context.count, 2600)
    }

    func testCloudPolicyKeepsDistantAnswers() {
        let path = [
            ContextAssembler.Node(title: "A", question: "问题A", answer: String(repeating: "a", count: 3000)),
            ContextAssembler.Node(title: "B", question: "问题B", answer: String(repeating: "b", count: 3000)),
            ContextAssembler.Node(title: "C", question: "问题C", answer: String(repeating: "c", count: 3000)),
        ]
        let local = ContextAssembler.context(path: path, policy: .local)
        let cloud = ContextAssembler.context(path: path, policy: .cloud)

        XCTAssertGreaterThan(cloud.count, local.count * 2)
        // 线上策略给更远的祖先保留了回答片段，本地策略只留问题行
        XCTAssertTrue(cloud.contains(String(repeating: "a", count: 40)))
        XCTAssertFalse(local.contains(String(repeating: "a", count: 40)))
    }
}
