import Foundation

/// 结构化的上下文检索：把文档切成「章节 / 页 / 幻灯片 / 段落」，
/// 先取选区所在段落，再按词法相关度补充 1–2 段最相关的其他段落。
///
/// 全程本地计算，不调用模型：上下文预算固定，优先保证「选区语境」，
/// 远处信息只有在真正命中选区的关键词时才带进来。
public struct ContextSection: Sendable, Equatable {
    public var label: String?
    public var text: String

    public init(label: String? = nil, text: String) {
        self.label = label
        self.text = text
    }
}

public enum ContextRetrieval {
    /// 返回带段落/页码标签的上下文；选区不在任何 section 里返回 nil，调用方退回旧的段落逻辑。
    public static func excerpt(sections: [ContextSection],
                               selection: String,
                               limit: Int) -> String? {
        let picked = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !picked.isEmpty, limit > 80, !sections.isEmpty else { return nil }

        // 1. 选区所在的 section：优先，且必须真的能找到
        guard let primaryIndex = sections.firstIndex(where: {
            DocumentContext.locate(picked, in: $0.text) != nil
        }) else { return nil }
        let primary = sections[primaryIndex]

        // 2. 其他 section 按关键词相关度排序（IDF 加权 + 标签命中）
        let terms = queryTerms(from: picked)
        var scored: [(index: Int, score: Double)] = []
        for (index, section) in sections.enumerated() where index != primaryIndex {
            let score = relevance(section: section, terms: terms, selection: picked, totalSections: sections.count)
            if score > 0 { scored.append((index, score)) }
        }
        scored.sort { $0.score > $1.score }

        // 3. 主 section：给上下文预算的一半左右，保证选区语境完整
        var result: [String] = []
        var remaining = limit
        let primaryBudget = max(200, limit * 2 / 3)
        if let primaryText = excerpt(for: primary,
                                     selection: picked,
                                     limit: min(primaryBudget, remaining)) {
            result.append(labeled(primaryText, label: primary.label))
            remaining -= result[0].count
            // 选区所在段落本身已经足够完整时，不再为了「凑满预算」硬塞其他章节；
            // 只有主上下文很短（列表项、导航词、单行幻灯片）才去补相关段落。
            if primaryText.count >= 600 {
                return result.joined(separator: "\n\n")
            }
        }
        guard remaining > 120 else { return result.isEmpty ? nil : result.joined(separator: "\n\n") }

        // 4. 相关段落：最多补两段，每段最多 300 字，且必须命中关键词
        for candidate in scored.prefix(2) {
            guard remaining > 160 else { break }
            let section = sections[candidate.index]
            let budget = min(300, remaining - 20)
            if let text = excerpt(for: section,
                                  selection: bestTerm(in: section.text, terms: terms) ?? picked,
                                  limit: budget) {
                let block = labeled(text, label: section.label)
                guard block.count <= remaining else { continue }
                result.append(block)
                remaining -= block.count
            }
        }
        return result.isEmpty ? nil : result.joined(separator: "\n\n")
    }

    // MARK: - 打分

    private static func relevance(section: ContextSection,
                                  terms: [String],
                                  selection: String,
                                  totalSections: Int) -> Double {
        let text = section.text.lowercased()
        guard !text.isEmpty else { return 0 }
        var score = 0.0
        if !selection.isEmpty, text.contains(selection.lowercased()) {
            score += 6
        }
        for term in terms where text.contains(term) {
            let frequency = text.components(separatedBy: term).count - 1
            score += log(Double(totalSections + 1) / 2.0) * Double(min(frequency, 4))
        }
        if let label = section.label?.lowercased() {
            for term in terms where label.contains(term) { score += 2 }
        }
        return score
    }

    private static func bestTerm(in text: String, terms: [String]) -> String? {
        let lowered = text.lowercased()
        return terms.first { lowered.contains($0) }
    }

    // MARK: - 词项

    /// 选区拆词：英文/数字按词，CJK 取相邻二字组合（切词少依赖词典）。
    static func queryTerms(from selection: String) -> [String] {
        var terms: [String] = []
        var latin = ""
        var cjk: [Character] = []

        func flushLatin() {
            let word = latin.lowercased()
            if word.count >= 2, !terms.contains(word) { terms.append(word) }
            latin = ""
        }

        func flushCJK() {
            if cjk.count == 1 {
                terms.append(String(cjk[0]))
            } else if cjk.count >= 2 {
                for index in 0..<(cjk.count - 1) {
                    let gram = String(cjk[index...index + 1])
                    if !terms.contains(gram) { terms.append(gram) }
                }
            }
            cjk.removeAll()
        }

        for character in selection {
            if character.isLetter || character.isNumber {
                if character.unicodeScalars.allSatisfy({ $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
                    flushLatin()
                    cjk.append(character)
                } else {
                    flushCJK()
                    latin.append(character)
                }
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        if terms.isEmpty { terms.append(selection.lowercased()) }
        return Array(terms.prefix(12))
    }

    // MARK: - 组装

    private static func excerpt(for section: ContextSection,
                                selection: String,
                                limit: Int) -> String? {
        guard let range = DocumentContext.locate(selection, in: section.text) else { return nil }
        let text = DocumentContext.excerptText(in: section.text, range: range, limit: max(limit, 120))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func labeled(_ text: String, label: String?) -> String {
        guard let label, !label.isEmpty else { return text }
        return "【\(label)】\n\(text)"
    }
}
