import Foundation

/// 深度上下文：把超预算的周边资料压缩成摘要再交给解释模型。
///
/// 设计原则：
/// - 只在上下文明显超预算时才调用模型（默认 >1200 token），避免日常解释多一次请求；
/// - 摘要只压缩「周边资料」，选区所在段落仍保留原文，防止摘要把关键定义压没；
/// - 摘要失败自动退回本地段落截取，不阻塞解释。
public enum DeepContextComposer {
    public static let summaryMarker = "【长上下文摘要】"
    public static let defaultTokenThreshold = 1_200
    public static let defaultSummaryChars = 450

    public static func shouldSummarize(_ context: String,
                                       tokenThreshold: Int = defaultTokenThreshold) -> Bool {
        TokenEstimator.estimate(context) > max(tokenThreshold, 200)
    }

    /// 组装修剪后的上下文：原文局部段落 + 摘要；摘要为空则退回本地截取。
    public static func compose(localExcerpt: String?,
                               summary: String?,
                               fallback: String?,
                               limit: Int) -> String? {
        let local = localExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let polished = summary.flatMap { cleanSummary($0, maxChars: defaultSummaryChars) }

        guard let polished, !polished.isEmpty else {
            let value = (fallback?.isEmpty == false ? fallback : local)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { return nil }
            return ContextAssembler.truncate(value, limit: max(limit, 200))
        }

        var text = ""
        if let local, !local.isEmpty {
            text = local
        }
        if !text.isEmpty { text += "\n\n" }
        text += summaryMarker + "\n" + polished
        return ContextAssembler.truncate(text, limit: max(limit, 200))
    }

    /// 模型没配置/调用失败时的本地兜底：按选区关键词从原文里抽 3–8 句，
    /// 保留原句不生成新内容，零 token 成本。
    public static func extractiveSummary(context: String,
                                         selection: String,
                                         maxChars: Int = defaultSummaryChars) -> String? {
        let body = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, maxChars > 80 else { return nil }
        let terms = ContextRetrieval.queryTerms(from: selection)
        guard !terms.isEmpty else { return nil }

        let separators = CharacterSet(charactersIn: "。！？!?；;\n")
        let pieces = body.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }

        var scored: [(index: Int, text: String, score: Double)] = []
        for (index, piece) in pieces.enumerated() {
            let lowered = piece.lowercased()
            guard !lowered.isEmpty else { continue }
            var score = 0.0
            if lowered.contains(selection.lowercased()) { score += 6 }
            for term in terms {
                if lowered.contains(term) {
                    score += 1 + Double(min(term.count, 4)) * 0.5
                }
            }
            if score > 0 { scored.append((index, piece, score)) }
        }
        guard !scored.isEmpty else { return nil }
        scored.sort {
            if $0.score == $1.score { return $0.index < $1.index }
            return $0.score > $1.score
        }

        var picked: [(index: Int, text: String)] = []
        var total = 0
        for item in scored {
            guard total < maxChars else { break }
            let remaining = maxChars - total
            let text = item.text.count > remaining
                ? ContextAssembler.truncate(item.text, limit: remaining)
                : item.text
            guard !text.isEmpty else { continue }
            picked.append((item.index, text))
            total += text.count + 1
        }
        guard !picked.isEmpty else { return nil }
        picked.sort { $0.index < $1.index }
        return picked.map(\.text).joined(separator: "。")
    }

    /// 清理模型输出：去掉常见前缀/代码围栏，压掉多余空行，按句子截断。
    public static func cleanSummary(_ raw: String, maxChars: Int = defaultSummaryChars) -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        for prefix in ["【长上下文摘要】", "长上下文摘要：", "摘要：", "总结："] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ContextAssembler.truncate(text, limit: max(maxChars, 80))
    }
}
