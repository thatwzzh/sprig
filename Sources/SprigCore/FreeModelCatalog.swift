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

    /// 从清单里挑一个默认模型。
    /// 不直接取上下文最大的——免费层里 1M 窗口的往往是大参数模型，慢且容易撞限额。
    /// 优先中文/通用表现稳的，再退到快的，最后才按上下文长度兜底。
    public static func preferred(from models: [FreeModel]) -> FreeModel? {
        guard !models.isEmpty else { return nil }
        let preference = ["qwen3", "gemma-4", "nemotron-3-super", "nemotron-3.5-lightning", "inkling-small"]
        for keyword in preference {
            if let match = models.first(where: { $0.id.contains(keyword) }) {
                return match
            }
        }
        return models[0]
    }

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
