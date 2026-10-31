import Foundation

/// 给人读的知识库投影。一个主卡一个 Markdown，子卡按树写在同一份文件里。
/// JSON 仍是程序读取的底稿；这里的文件被改了，下次保存会被覆盖。
enum CardMarkdown {
    /// 把 ```sprig-chart 的图表块换成两列表格。
    ///
    /// 知识库是给人读的终态文档：图表 JSON 留在里面既不可读、也没法被别的工具消费，
    /// 换成「项目 / 数值」表格，信息一条不少。
    static func expandChartBlocks(in text: String) -> String {
        guard text.contains("```sprig-chart") else { return text }
        var lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```sprig-chart") else {
                result.append(lines[index])
                index += 1
                continue
            }
            index += 1
            var body: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                body.append(lines[index])
                index += 1
            }
            if index < lines.count { index += 1 }   // 跳过收尾的 ```
            result.append(contentsOf: chartTable(from: body.joined(separator: "\n")))
        }
        return result.joined(separator: "\n")
    }

    /// ```html 图块：`assets/html-<hash>.png` 存在就写成图片引用；
    /// 不存在（渲染失败/还没渲染）就把标签转义成代码块，保证 Markdown 里显示的是原文。
    static func expandHtmlBlocks(in text: String, assetsDirectory: URL?) -> String {
        guard text.contains("```html") else { return text }
        var lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```html") else {
                result.append(lines[index])
                index += 1
                continue
            }
            index += 1
            var body: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                body.append(lines[index])
                index += 1
            }
            if index < lines.count { index += 1 }
            let html = body.joined(separator: "\n")
            let name = "assets/" + HtmlAsset.name(for: html)
            let exists = assetsDirectory.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path)
            } ?? false
            if exists {
                result.append("![图示](\(name))")
                result.append("")
            } else {
                // 没渲染成功：转义尖括号，任何 Markdown 查看器都只会显示源码
                result.append("```html")
                for line in body {
                    result.append(line.replacingOccurrences(of: "<", with: "&lt;")
                                       .replacingOccurrences(of: ">", with: "&gt;"))
                }
                result.append("```")
                result.append("")
            }
        }
        return result.joined(separator: "\n")
    }

    /// 图表 JSON → 标题 + 两列表格；解析不了就原样当代码块留着
    private static func chartTable(from json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = object["labels"] as? [Any],
              let values = object["values"] as? [Any],
              !labels.isEmpty else {
            return ["```", json, "```", ""]
        }
        var out: [String] = []
        if let title = object["title"] as? String, !title.isEmpty {
            out.append("**\(title)**")
            out.append("")
        }
        out.append("| 项目 | 数值 |")
        out.append("| --- | --- |")
        for (i, label) in labels.enumerated() {
            let value = i < values.count ? "\(values[i])" : ""
            out.append("| \(label) | \(value) |")
        }
        out.append("")
        return out
    }

    struct File: Equatable {
        var name: String
        var rootID: UUID
        var body: String
    }

    static let markerPrefix = "<!-- sprig:root "

    static func files(from cards: [AnswerCard]) -> [File] {
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        var children: [UUID: [AnswerCard]] = [:]
        for card in cards {
            guard let parentID = card.parentID, byID[parentID] != nil else { continue }
            children[parentID, default: []].append(card)
        }
        for id in children.keys {
            children[id]?.sort { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }

        let roots = cards.filter { card in
            guard let parentID = card.parentID else { return true }
            return byID[parentID] == nil
        }.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var taken = Set<String>()
        return roots.map { root in
            let name = filename(for: root, taken: &taken)
            var lines: [String] = ["\(markerPrefix)\(root.id.uuidString) -->", ""]
            var seen = Set<UUID>()
            write(root, depth: 0, children: children, seen: &seen, into: &lines)
            lines.append("")
            lines.append("本文由知枝生成。要修改内容，请在应用里改；直接改这个文件不会写回知识库。")
            lines.append("")
            return File(name: name, rootID: root.id, body: lines.joined(separator: "\n"))
        }
    }

    /// 写出当前这批主卡，并删掉已经没有对应主卡、且带有知枝标记的旧文件。
    /// 没有标记的 Markdown 留着，避免误删放进同一目录的其他笔记。
    static func sync(_ cards: [AnswerCard], in directory: URL) throws {
        let generated = files(from: cards)
        let names = Set(generated.map(\.name))
        for file in generated {
            let url = directory.appendingPathComponent(file.name)
            // HTML 图块：能渲染成图片就引用图片，否则转义成代码块（原文不丢）
            let body = expandHtmlBlocks(in: file.body, assetsDirectory: directory)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        let existing = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in existing where url.pathExtension == "md" {
            guard names.contains(url.lastPathComponent) == false else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.hasPrefix(markerPrefix) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func write(_ card: AnswerCard,
                              depth: Int,
                              children: [UUID: [AnswerCard]],
                              seen: inout Set<UUID>,
                              into lines: inout [String]) {
        guard seen.insert(card.id).inserted, depth < 64 else { return }
        lines.append(heading(depth: depth, title: oneLine(card.title)))
        lines.append("")
        let question = card.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty, oneLine(question) != oneLine(card.title) {
            lines.append(question)
            lines.append("")
        }
        if let selected = card.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            lines.append("> 选中：\(oneLine(selected))")
            lines.append("")
        }
        let answer = expandChartBlocks(in: card.plainAnswer.trimmingCharacters(in: .whitespacesAndNewlines))
        if !answer.isEmpty {
            lines.append(answer)
            lines.append("")
        }
        if let log = card.searchLog, !log.isEmpty {
            for record in log where !record.query.isEmpty {
                lines.append("搜索「\(oneLine(record.query))」")
                lines.append("")
                for item in record.items where !item.url.isEmpty {
                    let title = oneLine(item.title.isEmpty ? item.url : item.title)
                    lines.append("- [\(title)](\(item.url))")
                }
                lines.append("")
            }
        }
        for child in children[card.id] ?? [] {
            write(child, depth: depth + 1, children: children, seen: &seen, into: &lines)
        }
    }

    private static func heading(depth: Int, title: String) -> String {
        let text = title.isEmpty ? "未命名" : title
        if depth < 6 {
            return String(repeating: "#", count: depth + 1) + " " + text
        }
        return "**\(text)**"
    }

    private static func filename(for card: AnswerCard, taken: inout Set<String>) -> String {
        let base = sanitized(card.title)
        var name = base + ".md"
        if taken.contains(name) {
            name = "\(base)-\(card.id.uuidString.prefix(8)).md"
        }
        while taken.contains(name) {
            name = "\(base)-\(UUID().uuidString.prefix(8)).md"
        }
        taken.insert(name)
        return name
    }

    private static func sanitized(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*%\"<>|\n\r\t")
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? " " : Character($0) }
        let collapsed = String(cleaned)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = collapsed.count > 80 ? String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces) : collapsed
        return limited.isEmpty ? "未命名" : limited
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
