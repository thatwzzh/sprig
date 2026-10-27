import Foundation

/// 动态上下文装配。
///
/// 取舍：树越深、卡越多，把所有祖先都塞进 prompt 会很快吃掉上下文窗口，
/// 而且远处的分支对当前问题的帮助递减。所以按「由近到远 + 预算」分配：
/// - 当前回答：拿一半预算，必须完整（它才是被解释/追问的对象）
/// - 直接父级：最多 600 字
/// - 更远祖先：只留「标题 + 问题」，不塞回答
public enum ContextAssembler {
    public struct Node: Sendable {
        public let title: String
        public let question: String
        public let answer: String

        public init(title: String, question: String, answer: String) {
            self.title = title
            self.question = question
            self.answer = answer
        }
    }

    /// 本地模型上下文窗口小、对长输入更敏感；线上模型可以多喂。
    /// 预算单位是字符数（中文≈1 token/字，留足余量）。
    public struct Policy: Sendable {
        public let totalBudget: Int
        public let currentLimit: Int
        public let parentAnswerLimit: Int
        /// 更远祖先的回答上限；0 表示只保留「标题 + 问题」
        public let distantAnswerLimit: Int
        public let maxAncestors: Int

        public static let local = Policy(totalBudget: 2400,
                                         currentLimit: 1200,
                                         parentAnswerLimit: 600,
                                         distantAnswerLimit: 0,
                                         maxAncestors: 4)

        public static let cloud = Policy(totalBudget: 12000,
                                         currentLimit: 6000,
                                         parentAnswerLimit: 3000,
                                         distantAnswerLimit: 800,
                                         maxAncestors: 12)

        public static func forProvider(_ providerID: String) -> Policy {
            switch providerID {
            case "ollama": return .local
            default: return .cloud
            }
        }
    }

    public static func context(path: [Node], policy: Policy = .local) -> String {
        guard let current = path.last else { return "" }

        let currentAnswer = truncate(current.answer, limit: policy.currentLimit)
        var header = "【当前回答】（\(current.title)）"
        if !current.question.isEmpty {
            header += "\n问题：\(truncate(current.question, limit: 120))"
        }
        var sections: [String] = ["\(header)\n\(currentAnswer)"]

        var remaining = policy.totalBudget - currentAnswer.count
        var ancestorLines: [String] = []
        var depth = 0

        for node in path.dropLast().reversed() {
            guard depth < policy.maxAncestors, remaining > 60 else { break }
            depth += 1

            let limit = depth == 1 ? policy.parentAnswerLimit : policy.distantAnswerLimit
            if limit > 60 && remaining > 300 {
                let take = min(limit, remaining)
                let summary = truncate(node.answer, limit: take)
                ancestorLines.append("- \(node.title)：\(truncate(node.question, limit: 60))\n  \(summary)")
                remaining -= summary.count
            } else {
                // 预算不够就只留问题，别再塞回答
                ancestorLines.append("- \(node.title)：\(truncate(node.question, limit: 60))")
                remaining -= 40
            }
        }

        if !ancestorLines.isEmpty {
            sections.append("【上级上下文】\n" + ancestorLines.reversed().joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    static func truncate(_ text: String, limit: Int) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }
}
