import Foundation

/// 选区上下文的统一裁剪：先在文本里定位选区，再取「选区所在段落 ± 邻居」，最多 limit 字。
///
/// 网页、AX 周边文字、服务/连接器给的 fallback 都走这里，
/// 避免把整页/样式表/无关聊天记录塞进 Prompt。
public enum SelectionTextExcerpt {
    public static func locate(_ selection: String, in text: String) -> Range<String.Index>? {
        DocumentContext.locate(selection, in: text)
    }

    /// 找不到选区返回 nil（调用方应降级，而不是把整段文本当上下文）。
    public static func excerpt(from text: String, selection: String, limit: Int) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let range = DocumentContext.locate(selection, in: normalized) else { return nil }
        let value = DocumentContext.excerptText(in: normalized, range: range, limit: limit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
