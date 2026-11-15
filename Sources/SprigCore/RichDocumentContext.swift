import Foundation
import PDFKit

/// PDF / Office 文档的正文抽取。
///
/// - PDF 用系统 PDFKit；
/// - docx/pptx/xlsx 是 zip + XML：用系统 `unzip` 解到临时目录，再用 XMLParser 收集文字。
///   只支持有文字层的文档；扫描版 PDF / 纯图片文档会返回 nil，调用方保持「只有选区」。
enum RichDocumentContext {
    static func context(filePath: String,
                        selection: String,
                        limit: Int,
                        vaultName: String?) -> DocumentContext.Result? {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":
            return pdfContext(filePath: filePath,
                              selection: selection,
                              limit: limit,
                              vaultName: vaultName)
        case "docx", "pptx", "xlsx":
            return officeContext(filePath: filePath,
                                selection: selection,
                                limit: limit,
                                vaultName: vaultName,
                                ext: ext)
        default:
            return nil
        }
    }

    // MARK: - PDF

    private static func pdfContext(filePath: String,
                                   selection: String,
                                   limit: Int,
                                   vaultName: String?) -> DocumentContext.Result? {
        guard let document = PDFDocument(url: URL(fileURLWithPath: filePath)) else { return nil }
        var annotated = ""
        var pageTexts: [(number: Int, text: String)] = []
        let pageCount = min(document.pageCount, 1_000)

        for index in 0..<pageCount {
            guard let page = document.page(at: index), let pageText = page.string else { continue }
            pageTexts.append((index + 1, pageText))
            annotated += "【第 \(index + 1) 页】\n" + pageText + "\n\n"
            if annotated.count > 400_000 { break }
        }
        guard let range = DocumentContext.locate(selection, in: annotated) else { return nil }
        // 以选区为中心开窗：窗口可以跨页，前面不够时会自然带上一页尾部，
        // 不再固定从「选区所在页开头」开始（那会导致后面多、前面少）。
        // 普通模式最多 800 字；深度上下文模式放宽，交给摘要压缩
        let budget = min(max(limit, 200), limit > 1_200 ? 5_000 : 800)
        let excerpt = focusedWindow(in: annotated, range: range, limit: budget)
        guard !excerpt.isEmpty else { return nil }

        let matchedPage = pageTexts.first {
            DocumentContext.locate(selection, in: $0.text) != nil
        }?.number
        let filename = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let source = SelectionSource(kind: .pdf,
                                     title: filename,
                                     filePath: filePath,
                                     vaultName: vaultName,
                                     headingPath: matchedPage.map { ["第 \($0) 页"] },
                                     anchor: DocumentContext.anchor(in: annotated, range: range))
        return DocumentContext.Result(source: source, excerpt: excerpt)
    }

    /// 以选区为中心截取窗口（可跨页），两端尽量落在行边界，带省略号提示被截断。
    private static func focusedWindow(in text: String,
                                      range: Range<String.Index>,
                                      limit: Int) -> String {
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        let selectionLength = max(1, upper - lower)
        var start = max(0, lower - max(0, (limit - selectionLength) / 2))
        var end = min(text.count, start + limit)
        if end == text.count { start = max(0, end - limit) }
        var startIndex = text.index(text.startIndex, offsetBy: start)
        var endIndex = text.index(text.startIndex, offsetBy: end)

        if start > 0 {
            let beforeStart = text.index(startIndex, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            if let newline = text[beforeStart..<startIndex].lastIndex(of: "\n") {
                startIndex = text.index(after: newline)
            }
        }
        if end < text.count {
            let afterEnd = text.index(endIndex, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            if let newline = text[endIndex..<afterEnd].firstIndex(of: "\n") {
                endIndex = newline
            }
        }
        guard endIndex > startIndex else { return "" }
        let body = text[startIndex..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > 0 ? "…" : "") + body + (end < text.count ? "…" : "")
    }

    // MARK: - Office

    private static func officeContext(filePath: String,
                                      selection: String,
                                      limit: Int,
                                      vaultName: String?,
                                      ext: String) -> DocumentContext.Result? {
        guard let files = unzip(filePath) else { return nil }
        let text: String
        var sections: [ContextSection] = []
        var slideSections: [ContextSection] = []
        switch ext {
        case "docx":
            text = files["word/document.xml"].map(xmlText) ?? ""
        case "pptx":
            let slides = files.keys
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted(by: slideOrder)
            slideSections = slides.enumerated().compactMap { index, key in
                files[key].map {
                    ContextSection(label: "幻灯片 \(index + 1)", text: xmlText($0))
                }
            }
            sections = slideSections
            text = slideSections.map(\.text).joined(separator: "\n\n")
        case "xlsx":
            text = xlsxText(files)
        default:
            return nil
        }
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        guard let range = DocumentContext.locate(selection, in: normalized) else { return nil }
        if sections.isEmpty {
            sections = DocumentContext.paragraphSections(in: normalized)
        }
        let excerpt = ContextRetrieval.excerpt(sections: sections,
                                               selection: selection,
                                               limit: max(limit, 200))
            ?? DocumentContext.excerptText(in: normalized, range: range, limit: max(limit, 200))
        guard !excerpt.isEmpty else { return nil }

        var headingPath: [String]?
        if ext == "pptx",
           let index = slideSections.firstIndex(where: {
               DocumentContext.locate(selection, in: $0.text) != nil
           }) {
            headingPath = ["第 \(index + 1) 页"]
        }
        let filename = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let source = SelectionSource(kind: .document,
                                     title: filename,
                                     filePath: filePath,
                                     vaultName: vaultName,
                                     headingPath: headingPath,
                                     anchor: DocumentContext.anchor(in: normalized, range: range))
        return DocumentContext.Result(source: source, excerpt: excerpt)
    }

    /// slide1.xml / slide2.xml / slide10.xml 按数字排序
    private static func slideOrder(_ lhs: String, _ rhs: String) -> Bool {
        func number(_ value: String) -> Int {
            let digits = value.compactMap { $0.isNumber ? $0 : nil }
            return Int(String(digits)) ?? 0
        }
        return number(lhs) < number(rhs)
    }

    // MARK: - zip

    /// 解压到临时目录并读回 XML（只读文档内部结构，不解压图片）。
    private static func unzip(_ archive: String) -> [String: Data]? {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprig-office-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", archive, "-d", temporary.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        var result: [String: Data] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: temporary,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return nil }

        let rootPath = temporary.standardizedFileURL.path
        var totalBytes = 0
        for case let url as URL in enumerator {
            guard url.standardizedFileURL.path.hasPrefix(rootPath) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= 8 * 1_024 * 1_024 else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["xml", "rels"].contains(ext) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            totalBytes += data.count
            if totalBytes > 40 * 1_024 * 1_024 { break }
            var relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
            result[relative] = data
        }
        return result
    }

    // MARK: - XML → text

    private static func xmlText(_ data: Data) -> String {
        let collector = OfficeTextCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.text
    }

    /// 通用 OOXML 文本收集：docx 的 `<w:t>` / pptx 的 `<a:t>`，段落结束补换行。
    private final class OfficeTextCollector: NSObject, XMLParserDelegate {
        var text = ""
        private var buffer = ""
        private var capturing = false

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "t":
                capturing = true
                buffer = ""
            case "tab":
                text += "\t"
            case "br":
                text += "\n"
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { buffer += string }
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch localName(elementName) {
            case "t":
                text += buffer
                buffer = ""
                capturing = false
            case "p":
                text += "\n"
            default:
                break
            }
        }
    }

    // MARK: - xlsx

    private static func xlsxText(_ files: [String: Data]) -> String {
        // sharedStrings：被单元格以索引引用的共享文本
        var shared: [String] = []
        if let data = files["xl/sharedStrings.xml"] {
            let collector = SharedStringsCollector()
            let parser = XMLParser(data: data)
            parser.delegate = collector
            parser.parse()
            shared = collector.strings
        }

        let sheets = files.keys
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
        var lines: [String] = []
        for sheet in sheets {
            guard let data = files[sheet] else { continue }
            let collector = SheetRowsCollector(sharedStrings: shared)
            let parser = XMLParser(data: data)
            parser.delegate = collector
            parser.parse()
            lines.append(contentsOf: collector.rows)
        }
        return lines.joined(separator: "\n")
    }

    private final class SharedStringsCollector: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var buffer = ""
        private var capturing = false

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if localName(elementName) == "t" { capturing = true; buffer = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { buffer += string }
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = localName(elementName)
            if name == "t" { capturing = false }
            if name == "si" {
                strings.append(buffer)
                buffer = ""
            }
        }
    }

    private final class SheetRowsCollector: NSObject, XMLParserDelegate {
        let sharedStrings: [String]
        var rows: [String] = []
        private var cells: [String] = []
        private var cellText = ""
        private var capturing = false
        private var cellType: String?

        init(sharedStrings: [String]) {
            self.sharedStrings = sharedStrings
        }

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "c":
                cellType = attributeDict["t"]
                cellText = ""
            case "v", "t":
                capturing = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { cellText += string }
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch localName(elementName) {
            case "v", "t":
                capturing = false
            case "c":
                var value = cellText
                if cellType == "s", let index = Int(value), index >= 0, index < sharedStrings.count {
                    value = sharedStrings[index]
                }
                cells.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
                cellText = ""
                cellType = nil
            case "row":
                let row = cells.filter { !$0.isEmpty }.joined(separator: " | ")
                if !row.isEmpty { rows.append(row) }
                cells.removeAll()
            default:
                break
            }
        }
    }

    /// XMLParser 的 elementName 带命名空间前缀（w:t / a:p…），这里统一取本地名
    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[\\t\\u{00A0} ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n +", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
