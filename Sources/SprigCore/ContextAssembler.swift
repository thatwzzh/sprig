import Foundation

/// 动态上下文装配。
///
/// 取舍：树越深、卡越多，把所有祖先都塞进 prompt 会很快吃掉上下文窗口，
/// 而且远处的分支对当前问题的帮助递减。所以按「由近到远 + 预算」分配：
/// - 当前回答：拿一半预算，必须完整（它才是被解释/追问的对象）
/// - 直接父级：最多四分之一
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

    /// 预算单位是字符数（中文≈1 token/字，留足余量）。
    public struct Policy: Sendable {
        public var totalBudget: Int
        public var currentLimit: Int
        public var parentAnswerLimit: Int
        /// 更远祖先的回答上限；0 表示只保留「标题 + 问题」
        public var distantAnswerLimit: Int
        public var maxAncestors: Int
        /// 预留给工具结果（联网搜索）的字符数。
        /// 装配器看不到搜索结果——那些是流式循环里额外追加的消息——
        /// 所以只能在这里先把空间扣出来，否则卡片上下文 + 搜索结果会叠加撑爆窗口。
        public var toolReserve: Int

        /// 本地模型：上下文窗口小、对长输入更敏感，用紧一点的预算
        public static let local = Policy(totalBudget: 2400,
                                         currentLimit: 1200,
                                         parentAnswerLimit: 600,
                                         distantAnswerLimit: 0,
                                         maxAncestors: 4,
                                         toolReserve: 0)

        /// 未知窗口时的保守云端预算
        public static let cloud = Policy(totalBudget: 12000,
                                         currentLimit: 6000,
                                         parentAnswerLimit: 3000,
                                         distantAnswerLimit: 800,
                                         maxAncestors: 12,
                                         toolReserve: 0)


        /// 按模型真实窗口算预算。
        ///
        /// 拿不到窗口（nil）时退回 `.cloud`。能拿到时按窗口的 1/3 给卡片，
        /// 封顶 3 万字——再长首字延迟和 token 费用都上去了，对问答的边际收益很低。
        /// 本地模型不受窗口影响：9B 级模型喂太长质量会明显下降，窗口大也没用。
        public static func dynamic(contextTokens: Int?,
                                   isLocal: Bool,
                                   toolReserve: Int = 0) -> Policy {
            if isLocal {
                var policy = Policy.local
                policy.toolReserve = toolReserve
                return policy
            }

            guard let tokens = contextTokens, tokens > 0 else {
                var policy = Policy.cloud
                policy.toolReserve = toolReserve
                return policy
            }

            let budget = min(max(tokens / 3, 4_000), 30_000)
            return Policy(totalBudget: budget,
                          currentLimit: budget / 2,
                          parentAnswerLimit: min(budget / 4, 6_000),
                          distantAnswerLimit: min(budget / 15, 1_500),
                          maxAncestors: 12,
                          toolReserve: toolReserve)
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

        var remaining = policy.totalBudget - currentAnswer.count - policy.toolReserve
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

    /// 截断到 limit 字以内，尽量落在句子边界上。
    ///
    /// 硬 `prefix` 会把结尾砍掉，而结论往往就在最后一句。所以从后往前找
    /// 段落换行或句末标点；只能保住一半以上才接受，否则说明这一段没有边界，硬切。
    static func truncate(_ text: String, limit: Int) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }

        let head = value.prefix(limit)

        if let cut = head.lastIndex(of: "\n") {
            let kept = head.distance(from: head.startIndex, to: cut)
            if kept >= limit / 2 {
                return String(head[..<cut]) + "…"
            }
        }

        let terminators: Set<Character> = ["。", "！", "？", "；", "…", ".", "!", "?", ";"]
        if let cut = head.lastIndex(where: { terminators.contains($0) }) {
            let kept = head.distance(from: head.startIndex, to: cut) + 1
            if kept >= limit * 6 / 10 {
                return String(head[...cut]) + "…"
            }
        }

        return String(head) + "…"
    }
}
