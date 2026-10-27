import Foundation

/// 卡片树存储。v0 仍是 JSON：卡片量级在几百张以内，简单可靠。
/// 需要全文检索时换成 GRDB + FTS5，接口保持 upsert / all / children / path 即可。
public actor CardStore {
    public static let shared = CardStore()

    public static let fileName = "cards-v2.json"

    private var cards: [UUID: AnswerCard] = [:]
    private var loaded = false
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.legacyFileURL
    }

    /// 改名前的旧位置（Application Support/ConceptLens）；切换知识库目录时作为兜底数据源。
    /// 这里故意保留旧目录名，改名不影响老数据的读取。
    private static var legacyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("ConceptLens", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 切换知识库目录。
    /// 目标目录已有数据就直接读；没有数据时把当前库（或旧默认位置）的文件复制过去，
    /// 避免切换目录（比如新版默认 ~/Documents/Sprig）时卡片“凭空消失”。
    public func useDirectory(_ directory: URL) {
        let target = directory.appendingPathComponent(Self.fileName)
        guard target.standardizedFileURL != fileURL.standardizedFileURL else {
            loadIfNeeded()
            return
        }

        if !FileManager.default.fileExists(atPath: target.path) {
            let candidates = [fileURL, Self.legacyFileURL]
            if let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: source, to: target)
            }
        }

        fileURL = target
        cards = [:]
        loaded = false
        loadIfNeeded()
    }

    /// 当前库文件位置（设置页展示 / 排错用）
    public func currentFileURL() -> URL {
        fileURL
    }

    public func upsert(_ card: AnswerCard) {
        loadIfNeeded()
        cards[card.id] = card
        persist()
    }

    public func all() -> [AnswerCard] {
        loadIfNeeded()
        return cards.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func card(id: UUID) -> AnswerCard? {
        loadIfNeeded()
        return cards[id]
    }

    public func children(of id: UUID?) -> [AnswerCard] {
        loadIfNeeded()
        return cards.values
            .filter { $0.parentID == id }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func rename(id: UUID, title: String) {
        loadIfNeeded()
        guard var card = cards[id] else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        card.title = value
        cards[id] = card
        persist()
    }

    /// 删除一张卡连同它的所有后代
    @discardableResult
    public func delete(id: UUID) -> Set<UUID> {
        loadIfNeeded()
        var removed: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for card in cards.values {
                guard let parent = card.parentID, removed.contains(parent), !removed.contains(card.id) else { continue }
                removed.insert(card.id)
                changed = true
            }
        }
        for key in removed { cards.removeValue(forKey: key) }
        persist()
        return removed
    }

    /// 从根到指定卡片的完整路径
    public func path(to id: UUID) -> [AnswerCard] {
        loadIfNeeded()
        var result: [AnswerCard] = []
        var cursor: UUID? = id
        var guardCount = 0
        while let current = cursor, let card = cards[current], guardCount < 64 {
            result.append(card)
            cursor = card.parentID
            guardCount += 1
        }
        return result.reversed()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let list = (try? JSONDecoder().decode([AnswerCard].self, from: data)) ?? []
        cards = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(cards.values))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Sprig] 卡片落盘失败: \(error)")
        }
    }
}
