import Foundation

/// 一张答案卡。整棵树就是「问答即卡片」：根卡是一次提问，子卡是从父卡里
/// 选中某个片段后产生的追问/解释。
/// 卡片里存的一次搜索记录。和面板上那行「🔍 搜索「…」」一一对应（按出现顺序）。
public struct CardSearchRecord: Codable, Sendable, Equatable {
    public let query: String
    public let items: [SearchItem]

    public init(query: String, items: [SearchItem]) {
        self.query = query
        self.items = items
    }
}

public struct AnswerCard: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var parentID: UUID?
    /// 面包屑上显示的短标题（根卡 = 问题截断，子卡 = 选中的片段）
    public var title: String
    /// 实际发给模型的问题
    public var question: String
    /// 含 ⟦⟧ 标记的原始回答，用于重新渲染
    public var answer: String
    /// 从父卡里选中的片段；根卡为 nil
    public var selectedText: String?
    /// 这张卡生成时做过的搜索。持久化下来，切卡重渲染后点来源还能打开。
    /// 可选字段，旧数据解码为 nil。
    public var searchLog: [CardSearchRecord]?
    public var createdAt: Date

    public init(id: UUID = UUID(),
                parentID: UUID? = nil,
                title: String,
                question: String,
                answer: String = "",
                selectedText: String? = nil,
                searchLog: [CardSearchRecord]? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.question = question
        self.answer = answer
        self.selectedText = selectedText
        self.searchLog = searchLog
        self.createdAt = createdAt
    }

    /// 去掉术语标记后的纯文本，用于给子卡当上下文
    public var plainAnswer: String {
        answer
            .replacingOccurrences(of: "⟦", with: "")
            .replacingOccurrences(of: "⟧", with: "")
    }
}
