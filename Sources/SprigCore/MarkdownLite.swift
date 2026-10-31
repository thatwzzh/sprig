import Foundation

/// 一段行内内容。只覆盖答案里真正会出现的几种：粗体、斜体、行内代码，以及 `⟦术语⟧`。
public enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case bold(String)
    case italic(String)
    case code(String)
    case term(String)
}

public enum MarkdownBlockKind: Equatable, Sendable {
    case paragraph
    case heading(Int)
    case bullet
    /// 有序列表，附带原始序号（"1."、"2."）
    case ordered(String)
    case quote
    /// ``` 围起来的代码块，附带第一行写的语言（可能为空）
    case code(String)
    /// GFM 表格：表头 + 数据行（单元格已是纯文本）
    case table(header: [String], rows: [[String]])
    /// ```sprig-chart 的图表，解析成结构化数据由 UI 画
    case chart(ChartSpec)
    /// ```html 块：UI 层渲染成图片（流程图/架构图），渲染不了就退回显示源码
    case html(String)
    /// ```mermaid 块：UI 层渲染成图片，渲染不了就退回带高亮的源码
    case mermaid(String)
}

/// 图表数据。模型用 ```sprig-chart 加一段 JSON 描述，知枝负责画。
public struct ChartSpec: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case bar
        case line
    }

    public var kind: Kind
    public var title: String
    public var labels: [String]
    public var values: [Double]

    public init(kind: Kind, title: String = "", labels: [String], values: [Double]) {
        self.kind = kind
        self.title = title
        self.labels = labels
        self.values = values
    }

    /// 从图表块里的 JSON 解析；任何字段不对就返回 nil（调用方退回代码块原文）
    public static func parse(_ json: String) -> ChartSpec? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = object["labels"] as? [Any], !labels.isEmpty,
              let values = object["values"] as? [Any] else { return nil }
        let kind = Kind(rawValue: (object["type"] as? String ?? "bar").lowercased()) ?? .bar
        let numbers = values.compactMap { value -> Double? in
            if let number = value as? Double { return number }
            if let number = value as? Int { return Double(number) }
            if let text = value as? String { return Double(text) }
            return nil
        }
        guard numbers.count == labels.count else { return nil }
        return ChartSpec(kind: kind,
                         title: object["title"] as? String ?? "",
                         labels: labels.map { "\($0)" },
                         values: numbers)
    }
}

public struct MarkdownBlock: Equatable, Sendable {
    public var kind: MarkdownBlockKind
    public var inlines: [MarkdownInline]

    public init(kind: MarkdownBlockKind, inlines: [MarkdownInline]) {
        self.kind = kind
        self.inlines = inlines
    }

    public var plainText: String {
        inlines.map { inline in
            switch inline {
            case .text(let value), .bold(let value), .italic(let value),
                 .code(let value), .term(let value):
                return value
            }
        }.joined()
    }
}

/// 一个够用的 Markdown 子集解析器：标题、列表、引用、代码块、行内粗斜体与代码。
///
/// 不追求完整规范——模型回答里出现的东西就这些。解析结果是纯数据，
/// 由 UI 层决定怎么画（这里是 Core，不 import AppKit）。
public enum MarkdownLite {
    public static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var codeLines: [String] = []
        var codeLanguage = ""
        var inCode = false
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(MarkdownBlock(kind: .paragraph,
                                        inlines: inlines(paragraphLines.joined(separator: "\n"))))
            paragraphLines.removeAll()
        }

        func flushCode() {
            guard inCode else { return }
            let body = codeLines.joined(separator: "\n")
            // 图表块能解析就交给 UI 画，解析不了仍当普通代码块保留原文
            if codeLanguage.lowercased().hasPrefix("sprig-chart"),
               let spec = ChartSpec.parse(body) {
                blocks.append(MarkdownBlock(kind: .chart(spec), inlines: []))
            } else if codeLanguage.lowercased() == "mermaid" {
                blocks.append(MarkdownBlock(kind: .mermaid(body), inlines: []))
            } else if codeLanguage.lowercased() == "html" {
                blocks.append(MarkdownBlock(kind: .html(body), inlines: []))
            } else {
                blocks.append(MarkdownBlock(kind: .code(codeLanguage), inlines: [.text(body)]))
            }
            codeLines.removeAll()
            codeLanguage = ""
            inCode = false
        }

        let lines = raw.components(separatedBy: "\n")
        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            defer { lineIndex += 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                if inCode {
                    flushCode()
                } else {
                    inCode = true
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.dropFirst(heading + 1)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .heading(heading), inlines: inlines(text)))
                continue
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .quote, inlines: inlines(text)))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .bullet, inlines: inlines(text)))
                continue
            }
            if let (marker, text) = orderedMarker(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .ordered(marker), inlines: inlines(text)))
                continue
            }
            // 表格：本行有 |、下一行是 |---| 分隔行
            if trimmed.contains("|"), lineIndex + 1 < lines.count,
               isTableSeparator(lines[lineIndex + 1]) {
                flushParagraph()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                var cursor = lineIndex + 2
                while cursor < lines.count {
                    let body = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard body.contains("|"), !isTableSeparator(body) else { break }
                    rows.append(tableCells(body))
                    cursor += 1
                }
                blocks.append(MarkdownBlock(kind: .table(header: header, rows: rows), inlines: []))
                lineIndex = cursor - 1
                continue
            }

            paragraphLines.append(trimmed)
        }
        flushParagraph()
        flushCode()
        return blocks
    }

    /// `|---|---|`、`|:--:|` 这类分隔行
    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let body = cell.replacingOccurrences(of: ":", with: "")
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    /// 拆一行单元格；首尾的空壳（`|` 两侧）丢掉
    static func tableCells(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|").map {
            // 单元格是纯文本：术语标记、行内代码的反引号、粗体星号都去掉
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "⟦", with: "")
                .replacingOccurrences(of: "⟧", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "**", with: "")
        }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    /// `#` 的个数（1...6）；不是标题返回 nil
    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        // 「#标题」不算，必须是「# 标题」
        guard rest.hasPrefix(" ") else { return nil }
        return hashes.count
    }

    /// "1. xxx" → ("1.", "xxx")
    private static func orderedMarker(_ line: String) -> (String, String)? {
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex, line[index] == "." else { return nil }
        let afterDot = line.index(after: index)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let text = String(line[line.index(after: afterDot)...]).trimmingCharacters(in: .whitespaces)
        return (digits + ".", text)
    }

    /// 把一段文本按 ⟦术语⟧ 切成「普通文本 / 术语」两段，用于粗体、斜体内部的二次解析
    private static func splitTerms(_ text: String) -> [MarkdownInline] {
        guard text.contains("⟦") else { return [.text(text)] }
        var result: [MarkdownInline] = []
        var buffer = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "⟦", let close = text[index...].firstIndex(of: "⟧") {
                if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" }
                let term = String(text[text.index(after: index)..<close])
                if !term.isEmpty { result.append(.term(term)) }
                index = text.index(after: close)
            } else {
                buffer.append(text[index])
                index = text.index(after: index)
            }
        }
        if !buffer.isEmpty { result.append(.text(buffer)) }
        return result
    }

    /// 行内解析：`⟦术语⟧`、`**粗**`、`*斜*`、`` `代码` ``
    static func inlines(_ text: String) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var buffer = ""

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            result.append(.text(buffer))
            buffer = ""
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if character == "⟦", let close = text[index...].firstIndex(of: "⟧") {
                flushBuffer()
                let term = String(text[text.index(after: index)..<close])
                if !term.isEmpty { result.append(.term(term)) }
                index = text.index(after: close)
                continue
            }

            if character == "`", let close = text[index...].dropFirst().firstIndex(of: "`") {
                flushBuffer()
                let code = String(text[text.index(after: index)..<close])
                if !code.isEmpty { result.append(.code(code)) }
                index = text.index(after: close)
                continue
            }

            if character == "*" {
                let rest = text[index...]
                if rest.hasPrefix("**"), let close = rest.dropFirst(2).range(of: "**") {
                    flushBuffer()
                    let bold = String(text[text.index(index, offsetBy: 2)..<close.lowerBound])
                    // 粗体里可能还裹着 ⟦术语⟧，要拆开，否则括号会漏到界面上
                    for piece in splitTerms(bold) {
                        switch piece {
                        case .term(let term): result.append(.term(term))
                        case .text(let value): result.append(.bold(value))
                        default: break
                        }
                    }
                    index = close.upperBound
                    continue
                }
                // 单个 * 才当斜体；** 的开头不能走到这里，否则会把两个星号一起吃掉
                if !rest.hasPrefix("**"), let close = rest.dropFirst().firstIndex(of: "*") {
                    flushBuffer()
                    let italic = String(text[text.index(after: index)..<close])
                    for piece in splitTerms(italic) {
                        switch piece {
                        case .term(let term): result.append(.term(term))
                        case .text(let value): result.append(.italic(value))
                        default: break
                        }
                    }
                    index = text.index(after: close)
                    continue
                }
            }

            buffer.append(character)
            index = text.index(after: index)
        }
        flushBuffer()
        return result
    }
}
