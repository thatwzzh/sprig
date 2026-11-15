import XCTest
@testable import SprigCore

final class RichDocumentContextTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    func testPDFContextUsesPDFKitText() throws {
        let url = try fixture("sample", "pdf")
        let result = try XCTUnwrap(DocumentContext.context(filePath: url.path,
                                                           selection: "召回率",
                                                           limit: 500))
        XCTAssertEqual(result.source.kind, .pdf)
        XCTAssertTrue(result.excerpt.contains("召回率"))
        XCTAssertEqual(result.source.headingPath, ["第 1 页"])
    }

    func testDocxContextExtractsParagraphs() throws {
        let url = try fixture("sample", "docx")
        let result = try XCTUnwrap(DocumentContext.context(filePath: url.path,
                                                           selection: "召回率",
                                                           limit: 500))
        XCTAssertEqual(result.source.kind, .document)
        XCTAssertTrue(result.excerpt.contains("召回率"))
        XCTAssertTrue(result.excerpt.contains("检索阶段"))
    }

    func testPptxContextExtractsSlides() throws {
        let url = try fixture("sample", "pptx")
        let result = try XCTUnwrap(DocumentContext.context(filePath: url.path,
                                                           selection: "召回率",
                                                           limit: 500))
        XCTAssertEqual(result.source.kind, .document)
        XCTAssertTrue(result.excerpt.contains("召回率"))
    }

    func testXlsxContextExtractsSharedStringsAndRows() throws {
        let url = try fixture("sample", "xlsx")
        let result = try XCTUnwrap(DocumentContext.context(filePath: url.path,
                                                           selection: "召回率",
                                                           limit: 500))
        XCTAssertEqual(result.source.kind, .document)
        XCTAssertTrue(result.excerpt.contains("召回率"))
    }

    func testPDFContextCrossesPageBoundaryWhenSelectionNearStart() throws {
        let url = try fixture("two-pages", "pdf")
        let result = try XCTUnwrap(DocumentContext.context(filePath: url.path,
                                                           selection: "用户上下文",
                                                           limit: 800))
        XCTAssertEqual(result.source.headingPath, ["第 2 页"])
        XCTAssertTrue(result.excerpt.contains("用户上下文"))
        XCTAssertTrue(result.excerpt.contains("第一页尾部"), "选区在页首时，应该带上上一页尾部而不是从页首硬切")
        XCTAssertTrue(result.excerpt.contains("第 2 页"))
    }

    func testRichDocumentMissingSelectionReturnsNil() throws {
        let url = try fixture("sample", "pdf")
        XCTAssertNil(DocumentContext.context(filePath: url.path,
                                             selection: "文档里没有的词",
                                             limit: 500))
    }

    /// PDF 每行换行，选区可能不带换行；忽略空白也要能定位
    func testLocateIgnoringWhitespaceAcrossPDFLineBreaks() {
        let text = "检索阶段通常看\n召回\n率；把文本转成向量"
        let range = DocumentContext.locate("召回率", in: text)
        XCTAssertNotNil(range)
        XCTAssertEqual(String(text[range!]), "召回\n率")
    }
}
