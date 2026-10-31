import Foundation

/// 卡片树存储。v0 仍是 JSON：卡片量级在几百张以内，简单可靠。
/// 需要全文检索时换成 GRDB + FTS5，接口保持 upsert / all / children / path 即可。
public actor CardStore {
    public static let shared = CardStore()

    /// 程序读取的底稿。以点开头，访达里默认不显示。
    public static let fileName = ".cards.json"

    private var cards: [UUID: AnswerCard] = [:]
    private var loaded = false
    /// 读到的 JSON 无法解码时不许落盘，避免一次坏文件把库写成空的。
    private var refusePersist = false
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    /// 真正的知识库由 `useDirectory` 指过来；这只是启动前的占位。
    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Sprig", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func existingLibrary(in directory: URL) -> URL? {
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 切换知识库目录。
    /// 目标目录已有数据就直接读；没有数据时把当前库（或旧默认位置）的文件复制过去，
    /// 避免切换目录（比如新版默认 ~/Documents/Sprig）时卡片“凭空消失”。
    public func useDirectory(_ directory: URL) {
        let target = Self.existingLibrary(in: directory) ?? directory.appendingPathComponent(Self.fileName)
        guard target.standardizedFileURL != fileURL.standardizedFileURL else {
            loadIfNeeded()
            publishMarkdown()
            return
        }

        if !FileManager.default.fileExists(atPath: target.path) {
            let source = fileURL
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: source, to: target)
            }
        }

        fileURL = target
        cards = [:]
        loaded = false
        refusePersist = false
        loadIfNeeded()
        persist()
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
        let url = fileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        guard let list = try? JSONDecoder().decode([AnswerCard].self, from: data) else {
            refusePersist = true
            NSLog("[Sprig] 知识库无法解析，已停止写入以免覆盖：\(url.path)")
            return
        }
        cards = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private func persist() {
        guard !refusePersist else { return }
        let destination = fileURL
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(cards.values))
            try data.write(to: destination, options: .atomic)
        } catch {
            NSLog("[Sprig] 卡片落盘失败: \(error)")
            return
        }
        publishMarkdown()
    }

    private func publishMarkdown() {
        do {
            try CardMarkdown.sync(Array(cards.values), in: fileURL.deletingLastPathComponent())
        } catch {
            NSLog("[Sprig] Markdown 同步失败: \(error)")
        }
    }
}
