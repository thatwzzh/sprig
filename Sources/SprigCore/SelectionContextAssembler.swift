import Foundation

/// 外部选词卡片的上下文装配。
///
/// 和 `ContextAssembler`（祖先卡片链）是两套东西：
/// - 外部选词没有祖先链，预算几乎全给「来源元信息 + 来源上下文 + 选区」；
/// - 来源上下文来自网页/文件/AX，是不可信输入，由 Prompt 明确它是资料不是指令。
public enum SelectionContextAssembler {
    public struct Policy: Sendable, Equatable {
        /// 选区进 Prompt 的上限（最终还会被设置上限约束）
        public var selectionLimit: Int
        /// 来源上下文上限
        public var contextLimit: Int
        /// 来源元信息（标题/地址/路径）的总上限
        public var sourceLimit: Int
        /// 预留给工具结果（联网搜索）的字符数
        public var toolReserve: Int

        public init(selectionLimit: Int,
                    contextLimit: Int,
                    sourceLimit: Int = 150,
                    toolReserve: Int = 0) {
            self.selectionLimit = selectionLimit
            self.contextLimit = contextLimit
            self.sourceLimit = sourceLimit
            self.toolReserve = toolReserve
        }

        /// 按模型类型算预算。云端给 2000 字上下文；本地模型固定 600。
        /// 开了联网搜索先从预算里扣掉 toolReserve，避免上下文 + 搜索结果叠加撑爆窗口。
        public static func dynamic(isLocal: Bool,
                                   contextTokens: Int?,
                                   toolReserve: Int = 0,
                                   selectionCap: Int,
                                   deepContext: Bool = false) -> Policy {
            let cap = min(max(selectionCap, 1), SelectionEnvelope.absoluteMaxSelectionLength)
            if isLocal {
                return Policy(selectionLimit: min(cap, 500),
                              contextLimit: deepContext ? 1_200 : 600,
                              toolReserve: toolReserve)
            }
            let windowBudget = max(1_200, min(3_200, (contextTokens ?? 128_000) / 3))
            let available = max(600, windowBudget - toolReserve - min(cap, 1_000) - 150)
            return Policy(selectionLimit: min(cap, 1_000),
                          contextLimit: min(2_000, available),
                          toolReserve: toolReserve)
        }
    }

    /// 生成发给模型的 user 消息。
    public static func message(envelope: SelectionEnvelope,
                               context: String?,
                               policy: Policy) -> String {
        var lines: [String] = ["【选词来源】"]
        lines.append("类型：\(envelope.source.kind.displayName)")

        if let title = trimmed(envelope.source.title, limit: 120) {
            lines.append("标题：\(title)")
        }
        if let url = trimmed(envelope.source.url, limit: 240) {
            lines.append("地址：\(url)")
        }
        if let path = trimmed(envelope.source.filePath, limit: 240) {
            lines.append("文件：\(path)")
        }
        if let vault = trimmed(envelope.source.vaultName, limit: 120) {
            lines.append("库：\(vault)")
        }
        if let app = trimmed(envelope.source.appName, limit: 120),
           envelope.source.kind == .app || envelope.source.kind == .agent {
            lines.append("应用：\(app)")
        }
        if let headings = envelope.source.headingPath?
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }), !headings.isEmpty {
            lines.append("位置：" + headings.joined(separator: " › "))
        }

        let excerpt = excerpt(from: context,
                              selection: envelope.selection,
                              limit: policy.contextLimit)
        if let excerpt {
            lines.append("")
            lines.append("【所在上下文】")
            lines.append(excerpt)
        }

        lines.append("")
        lines.append("【选中的片段】")
        lines.append(ContextAssembler.truncate(envelope.selection, limit: max(policy.selectionLimit, 1)))

        if let question = trimmed(envelope.question, limit: 300) {
            lines.append("")
            lines.append("【我的问题】")
            lines.append(question)
        }

        lines.append("")
        lines.append("【任务】")
        if excerpt == nil {
            lines.append("请解释【选中的片段】的含义；如果用户提了具体问题，先回答它。")
        } else {
            lines.append("请解释【选中的片段】在【所在上下文】中的含义；如果用户提了具体问题，先回答它。")
        }
        return lines.joined(separator: "\n")
    }

    /// 取选区附近的一段上下文，并把选区用 `«…»` 标出来。
    ///
    /// 找不到选区原文时（网页抓取/文件内容被改写），退化为按句子边界截断的上下文，
    /// 不假装已标记。这样 Prompt 仍然能读到来源段落，只是没有定位标记。
    public static func excerpt(from context: String?,
                               selection: String,
                               limit: Int) -> String? {
        guard let raw = context, limit > 40 else { return nil }
        let value = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let picked = selection.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.count <= limit {
            return markSelection(in: value, selection: picked)
        }

        if !picked.isEmpty,
           let found = findRange(of: picked, in: value) {
            let lower = value.distance(from: value.startIndex, to: found.lowerBound)
            let upper = value.distance(from: value.startIndex, to: found.upperBound)
            // 窗口优先包住整个选区；选区比 limit 还长时只能截断
            var start = max(0, lower - limit / 3)
            if start + limit < upper {
                start = max(0, min(lower, upper - limit))
            }
            var end = min(value.count, start + limit)
            if end < upper {
                end = min(value.count, upper)
                start = max(0, end - limit)
            }
            let lowerIndex = value.index(value.startIndex, offsetBy: start)
            let upperIndex = value.index(value.startIndex, offsetBy: end)
            let window = String(value[lowerIndex..<upperIndex])
            let marked = markSelection(in: window, selection: picked) ?? window
            return (start > 0 ? "…" : "") + marked + (end < value.count ? "…" : "")
        }

        return ContextAssembler.truncate(value, limit: limit)
    }

    // MARK: - 内部

    /// Prompt 里把选区标出来；同一段只标第一次。
    static func markSelection(in text: String, selection: String) -> String? {
        guard !selection.isEmpty, let range = findRange(of: selection, in: text) else { return nil }
        let matched = String(text[range])
        return text.replacingCharacters(in: range, with: "«\(matched)»")
    }

    /// 原文里找选区：先精确匹配；再试把选区里的空白换成换行（跨行选区）。
    static func findRange(of selection: String, in text: String) -> Range<String.Index>? {
        if let range = text.range(of: selection) { return range }
        let variants = [
            selection.replacingOccurrences(of: " ", with: "\n"),
            selection.replacingOccurrences(of: " ", with: "\n\n"),
        ]
        for variant in variants {
            if let range = text.range(of: variant) { return range }
        }
        return nil
    }

    private static func trimmed(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let value = raw.replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.count > limit ? String(value.prefix(limit)) + "…" : value
    }
}
