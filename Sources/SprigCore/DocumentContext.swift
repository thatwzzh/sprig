import Foundation

/// 本地 Markdown / 纯文本的来源上下文。
///
/// 只做「读文件 → 定位选区 → 取标题层级/所在段落」这一件事；
/// 文件反查（标题 → 路径）在 `DocumentLocator`，网页抓取在 `WebPageContext`。
public enum DocumentContext {
    public struct Result: Sendable, Equatable {
        public var source: SelectionSource
        /// 选区附近的原文（不含 «» 标记；Prompt 装配时再标）
        public var excerpt: String
    }

    /// 文件读取上限，避免把整本电子书塞进内存
    static let maxFileBytes = 512 * 1024

    public static func context(filePath: String,
                               selection: String,
                               limit: Int,
                               vaultName: String? = nil) -> Result? {
        let url = URL(fileURLWithPath: filePath)
        let ext = url.pathExtension.lowercased()
        if ["pdf", "docx", "pptx", "xlsx"].contains(ext) {
            return RichDocumentContext.context(filePath: filePath,
                                               selection: selection,
                                               limit: limit,
                                               vaultName: vaultName)
        }
        guard let rawText = readText(at: url) else { return nil }
        // Windows/老编辑器写出的 CRLF 会让「空行分段」和选区定位都失效，先统一换行
        let normalizedText = rawText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // YAML frontmatter / HTML 注释是元数据，不该混进解释上下文；
        // 用等长换行替换，保证选区偏移不变。
        let sanitized = sanitizedMarkdown(normalizedText)
        let text: String
        let range: Range<String.Index>
        if let found = locate(selection, in: sanitized) {
            text = sanitized
            range = found
        } else if let found = locate(selection, in: normalizedText) {
            text = normalizedText
            range = found
        } else {
            return nil
        }

        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        let headings = headingPath(in: text, upTo: offset)
        let sections = ext == "md" || ext == "markdown"
            ? markdownSections(in: text)
            : paragraphSections(in: text)
        let excerpt = ContextRetrieval.excerpt(sections: sections,
                                               selection: selection,
                                               limit: max(limit, 200))
            ?? excerptText(in: text, range: range, limit: max(limit, 200))
        guard !excerpt.isEmpty else { return nil }

        let title = headings.first
            ?? url.deletingPathExtension().lastPathComponent
        let anchor = anchor(in: text, range: range)
        let source = SelectionSource(kind: .markdown,
                                     title: title,
                                     filePath: filePath,
                                     vaultName: vaultName,
                                     headingPath: headings.isEmpty ? nil : headings,
                                     anchor: anchor)
        return Result(source: source, excerpt: excerpt)
    }

    // MARK: - 结构切分

    /// Markdown 按标题切成 section（代码块里的 # 不算标题）。
    static func markdownSections(in text: String) -> [ContextSection] {
        var sections: [ContextSection] = []
        var stack: [String] = []
        var buffer: [String] = []
        var inFence = false

        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            guard !body.isEmpty else { return }
            sections.append(ContextSection(label: stack.isEmpty ? nil : stack.joined(separator: " › "),
                                           text: body))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineText = String(line)
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                buffer.append(lineText)
                continue
            }
            if !inFence, let heading = markdownHeading(trimmed) {
                flush()
                stack = Array(stack.prefix(heading.level - 1))
                stack.append(heading.title)
                continue
            }
            buffer.append(lineText)
        }
        flush()
        return sections
    }

    /// 纯文本按空行切段；没有结构信息，至少允许检索命中其他段落。
    static func paragraphSections(in text: String) -> [ContextSection] {
        let parts = text.components(separatedBy: "\n\n")
        var sections: [ContextSection] = []
        for part in parts {
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { sections.append(ContextSection(text: value)) }
        }
        return sections
    }

    private static func markdownHeading(_ line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (hashes.count, title)
    }

    // MARK: - 读取

    /// 去掉 Markdown 的 YAML frontmatter 与 HTML 注释（换成等长换行，保持索引不变）。
    static func sanitizedMarkdown(_ text: String) -> String {
        var result = text
        if result.hasPrefix("---\n") {
            let searchStart = result.index(result.startIndex, offsetBy: 4)
            if let closing = result.range(of: "\n---", range: searchStart..<result.endIndex) {
                var end = closing.upperBound
                if end < result.endIndex, result[end] == "\n" {
                    end = result.index(after: end)
                }
                let count = result.distance(from: result.startIndex, to: end)
                result.replaceSubrange(result.startIndex..<end,
                                       with: String(repeating: "\n", count: count))
            }
        }
        if let regex = try? NSRegularExpression(pattern: "(?s)<!--.*?-->") {
            let source = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: source.length))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let count = result.distance(from: range.lowerBound, to: range.upperBound)
                result.replaceSubrange(range, with: String(repeating: "\n", count: count))
            }
        }
        return result
    }

    static func readText(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= maxFileBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - 定位

    /// 先在原文里找选区；跨行/跨页（PDF）排版会把空白打散，最后再用「忽略空白」匹配。
    static func locate(_ selection: String, in text: String) -> Range<String.Index>? {
        let picked = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !picked.isEmpty else { return nil }
        if let range = text.range(of: picked) { return range }
        for variant in [picked.replacingOccurrences(of: " ", with: "\n"),
                        picked.replacingOccurrences(of: " ", with: "\r\n")] {
            if let range = text.range(of: variant) { return range }
        }
        return locateIgnoringWhitespace(picked, in: text)
    }

    /// 忽略所有空白后匹配（PDF 每行换行、HTML 折叠空格时用）。
    static func locateIgnoringWhitespace(_ selection: String,
                                         in text: String) -> Range<String.Index>? {
        let target = selection.filter { !$0.isWhitespace }
        guard !target.isEmpty else { return nil }

        var characters: [Character] = []
        var indices: [String.Index] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if !character.isWhitespace {
                characters.append(character)
                indices.append(cursor)
            }
            cursor = text.index(after: cursor)
        }
        let compressed = String(characters)
        guard let match = compressed.range(of: target) else { return nil }
        let startOffset = compressed.distance(from: compressed.startIndex, to: match.lowerBound)
        let endOffset = compressed.distance(from: compressed.startIndex, to: match.upperBound)
        guard startOffset < endOffset, endOffset <= indices.count else { return nil }
        let end = text.index(after: indices[endOffset - 1])
        return indices[startOffset]..<end
    }

    // MARK: - 标题层级

    /// 选区之前最近的 Markdown 标题栈（跳过 fenced code block）。
    static func headingPath(in text: String, upTo offset: Int) -> [String] {
        var stack: [String] = []
        var inFence = false
        var cursor = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if cursor > offset { break }
            let lineText = String(line)
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            } else if !inFence {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes >= 1, hashes <= 6 {
                    let rest = trimmed.dropFirst(hashes)
                    if rest.hasPrefix(" ") {
                        let title = rest.trimmingCharacters(in: .whitespaces)
                        if !title.isEmpty {
                            stack = Array(stack.prefix(hashes - 1))
                            stack.append(title)
                        }
                    }
                }
            }
            cursor += lineText.count + 1
        }
        return stack
    }

    // MARK: - 段落截取

    /// 选区附近的一段原文：优先取「选区所在段落」，不够再向前后各扩一段，
    /// 最多 limit 字；段落本身超长时才在段内居中开窗。不带标记。
    static func excerptText(in text: String,
                            range: Range<String.Index>,
                            limit: Int) -> String {
        guard limit > 0 else { return "" }
        let paragraph = paragraphRange(containing: range, in: text)
        let core = text[paragraph]
        if core.count > limit {
            return windowText(in: text, range: range, limit: limit, container: paragraph)
        }

        let ranges = paragraphRanges(in: text)
        guard let index = ranges.firstIndex(where: { $0.contains(range.lowerBound) }) else {
            return core.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lower = index
        var upper = index
        var start = paragraph.lowerBound
        var end = paragraph.upperBound
        var current = core.count
        // 选区段落本身够长就不再扩；太短（如导航词）最多补到 500 字，
        // 避免为了“凑满 limit”把整页无关段落都塞进上下文。
        let target = min(limit, max(current, 500))

        while current < target {
            var expanded = false
            if lower > 0 {
                let candidate = text[ranges[lower - 1].lowerBound..<end]
                if candidate.count <= limit {
                    start = ranges[lower - 1].lowerBound
                    lower -= 1
                    current = candidate.count
                    expanded = true
                }
            }
            if current < limit, upper + 1 < ranges.count {
                let candidate = text[start..<ranges[upper + 1].upperBound]
                if candidate.count <= limit {
                    end = ranges[upper + 1].upperBound
                    upper += 1
                    current = candidate.count
                    expanded = true
                }
            }
            if !expanded { break }
        }
        return text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 选区所在段落（空行分隔）。
    private static func paragraphRange(containing range: Range<String.Index>,
                                       in text: String) -> Range<String.Index> {
        var start = text.startIndex
        if range.lowerBound > text.startIndex,
           let separator = text[..<range.lowerBound].range(of: "\n\n", options: .backwards) {
            start = separator.upperBound
        }
        var end = text.endIndex
        if range.upperBound < text.endIndex,
           let separator = text[range.upperBound...].range(of: "\n\n") {
            end = separator.lowerBound
        }
        return start..<end
    }

    private static func paragraphRanges(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if let separator = text.range(of: "\n\n", range: cursor..<text.endIndex) {
                result.append(cursor..<separator.lowerBound)
                cursor = separator.upperBound
            } else {
                result.append(cursor..<text.endIndex)
                break
            }
        }
        return result.isEmpty ? [text.startIndex..<text.endIndex] : result
    }

    /// 超长段落里以选区为中心开窗（尽量落在行边界）
    private static func windowText(in text: String,
                                   range: Range<String.Index>,
                                   limit: Int,
                                   container: Range<String.Index>) -> String {
        let containerStart = text.distance(from: text.startIndex, to: container.lowerBound)
        let containerLength = text.distance(from: container.lowerBound, to: container.upperBound)
        let lower = text.distance(from: text.startIndex, to: range.lowerBound) - containerStart
        let upper = text.distance(from: text.startIndex, to: range.upperBound) - containerStart
        var start = max(0, min(lower, upper - limit))
        var end = min(containerLength, start + limit)
        if end < upper {
            end = min(containerLength, upper)
            start = max(0, end - limit)
        }
        var startIndex = text.index(container.lowerBound, offsetBy: start)
        var endIndex = text.index(container.lowerBound, offsetBy: end)
        if start > 0 {
            let windowStart = text.index(startIndex, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            if let newline = text[windowStart..<startIndex].lastIndex(of: "\n") {
                startIndex = text.index(after: newline)
            }
        }
        if end < containerLength {
            let windowEnd = text.index(endIndex, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            if let newline = text[endIndex..<windowEnd].firstIndex(of: "\n") {
                endIndex = newline
            }
        }
        guard endIndex > startIndex else { return "" }
        return text[startIndex..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 锚点

    static func anchor(in text: String, range: Range<String.Index>) -> TextAnchor {
        let prefixStart = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let suffixEnd = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        return TextAnchor(prefix: String(text[prefixStart..<range.lowerBound]),
                          suffix: String(text[range.upperBound..<suffixEnd]),
                          startOffset: text.distance(from: text.startIndex, to: range.lowerBound),
                          length: text.distance(from: range.lowerBound, to: range.upperBound))
    }
}
