import Foundation

/// 一个免费模型的元信息。
public struct FreeModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let contextLength: Int

    public init(id: String, name: String, contextLength: Int) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
    }

    /// 设置页里展示用：上下文长度换算成 1M / 262K 这种
    public var contextLabel: String {
        guard contextLength > 0 else { return "" }
        if contextLength >= 1_000_000 {
            return String(format: "%.1fM", Double(contextLength) / 1_000_000)
        }
        return "\(contextLength / 1000)K"
    }
}

/// 免费模型目录。
///
/// OpenRouter 的 `/api/v1/models` 是公开接口（不需要 API Key），响应里每个模型带 `pricing`；
/// `prompt` 和 `completion` 同时为 0 的就是免费模型。这是目前唯一能「自动获取」的免费入口——
/// 别家的免费额度要么得先有 Key，要么没有可枚举的清单。
public enum FreeModelCatalog {
    public static let openRouterBaseURL = "https://openrouter.ai/api/v1"
    public static let openRouterModelsURL = URL(string: "https://openrouter.ai/api/v1/models")!

    /// 拉取 OpenRouter 当前的免费模型，上下文大的排前面。
    public static func openRouterFreeModels(session: URLSession = .shared) async throws -> [FreeModel] {
        var request = URLRequest(url: openRouterModelsURL)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.server(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decode("不是 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw LLMError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw LLMError.decode(String(data: data, encoding: .utf8) ?? "")
        }

        return payload.data
            .compactMap { item -> FreeModel? in
                guard let pricing = item.pricing,
                      isFree(pricing.prompt),
                      isFree(pricing.completion) else { return nil }
                return FreeModel(id: item.id,
                                 name: item.name ?? item.id,
                                 contextLength: item.context_length ?? 0)
            }
            .sorted { ($0.contextLength, $0.id) > ($1.contextLength, $1.id) }
    }

    /// 从清单里挑默认模型，面向「知识问答 + 基于回答继续追问」这个场景。
    ///
    /// 不按上下文长度挑：免费层里窗口最大的往往是大参数模型或专用模型，又慢又容易撞限额。
    /// 先剔掉根本不能聊天的（音乐生成、内容审核、代码专用、2.6B 以下的），
    /// 再按偏好权重选——权重看的是中文表达和指令遵循，`Sprig` 的 prompt 要求模型吐 ⟦术语⟧ 标记，
    /// 太小的模型经常不守格式。
    public static func preferred(from models: [FreeModel]) -> FreeModel? {
        guard !models.isEmpty else { return nil }

        let usable = models.filter { model in
            guard model.contextLength >= 32_000 else { return false }
            return !isNonChatModel(model.id)
        }
        guard !usable.isEmpty else { return models.first }

        func weight(_ model: FreeModel) -> Int {
            let id = model.id.lowercased()
            for rule in preference where id.contains(rule.token) {
                return rule.rank
            }
            return 100
        }

        return usable.sorted { lhs, rhs in
            let lw = weight(lhs), rw = weight(rhs)
            if lw != rw { return lw < rw }
            if lhs.contextLength != rhs.contextLength { return lhs.contextLength > rhs.contextLength }
            return lhs.id < rhs.id
        }.first
    }

    /// 这些即便标着免费也不能当对话模型用。设置页的「拉取」列表也会拿它过滤，
    /// 否则会出现 price=0 的 lyria（音乐生成）这种选项。
    private static let excludedTokens = [
        "lyria",            // 音乐生成
        "content-safety",   // 内容审核专用
        "north-mini-code",  // 代码专用
        "laguna",           // 代码专用
        "lfm",              // 2.6B，容易不守输出格式
        "inkling",          // 403：OpenRouter 限定只能被 agentic harness 调用，裸 API 直接拒
        "embed",
        "rerank",
    ]

    public static func isNonChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return excludedTokens.contains { lower.contains($0) }
    }

    /// 排名越小越优先。宁可写死一张表，也不按参数量猜——免费清单每周都在变，
    /// 这张表只在出现新模型时靠 context 兜底，不会因为某个模型下架就选到奇怪的东西。
    private static let preference: [(token: String, rank: Int)] = [
        ("qwen3", 10),                  // 中文和指令遵循最稳的一档
        ("qwen", 12),
        // 实测 2026-10-28：gemma 系上游共享池经常 429，nvidia 系稳定，所以后者优先
        ("nemotron-3.5-super-vl", 20),
        ("nemotron-3.5-lightning", 24),
        ("nemotron-3-ultra", 28),
        ("gemma-4-31b", 34),            // dense 31B，格式守得住，但常被上游限流
        ("gemma-4", 38),
        ("nemotron-3-super", 42),
        ("xing4", 36),                  // 星辰，中文语料多
        ("minimax", 40),
        ("inkling-small", 44),          // 1M 上下文，追问链长也不怕
        ("nemotron-3-nano", 56),
        ("dots", 62),
        ("flint", 66),
        ("openrouter/free", 90),        // 路由器，选到什么都说不准
    ]

    /// 单价字段是字符串（"0"、"0.000001"），也见过 "0.0"，统一按数值判断
    private static func isFree(_ raw: String?) -> Bool {
        guard let raw, let value = Double(raw) else { return false }
        return value == 0
    }

    private struct Payload: Decodable {
        struct Pricing: Decodable {
            let prompt: String?
            let completion: String?
        }

        struct Item: Decodable {
            let id: String
            let name: String?
            let context_length: Int?
            let pricing: Pricing?
        }

        let data: [Item]
    }
}
