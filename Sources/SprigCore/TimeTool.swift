import Foundation

/// 让模型自己取当前时间。
///
/// 模型的训练数据有个截止日期，「今天」「最近」这类相对时间它只能靠猜。
/// 给一个工具比在 system prompt 里塞一行时间戳更可靠——长对话里那行会过期。
public enum TimeTool {
    public static let name = "get_current_time"

    public static var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: """
            获取当前的日期、时间和时区。
            问题里出现「今天」「现在」「今年」「最近」「上周」这类相对时间，
            或者需要计算日期差时，先调用它拿确切时间，不要凭训练数据推测。
            """,
            parametersJSON: """
            {
              "type": "object",
              "properties": {}
            }
            """
        )
    }

    /// 返回给模型的文本。同时给人类可读格式和 ISO 8601，
    /// 后者方便它做日期运算。
    public static func execute(now: Date = Date()) -> String {
        let readable = DateFormatter()
        readable.locale = Locale(identifier: "zh_CN")
        readable.timeZone = .current
        readable.dateFormat = "yyyy 年 M 月 d 日 EEEE HH:mm"

        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]

        return """
        当前时间：\(readable.string(from: now))
        ISO 8601：\(iso.string(from: now))
        时区：\(TimeZone.current.identifier)（\(TimeZone.current.localizedName(for: .generic, locale: .current) ?? "本地")）
        """
    }
}
