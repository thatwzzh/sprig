import CryptoKit
import Foundation
import SprigCore

/// 深度上下文：上下文明显超预算时，调用当前模型把周边资料压缩成摘要。
///
/// - 只压缩周边资料，选区所在段落由 `DeepContextComposer` 保留原文；
/// - 默认只在 >1200 token 时触发，摘要最多 450 字，结果按内容哈希缓存；
/// - 模型未配置/调用失败时静默返回 nil，调用方退回本地截取，不影响解释。
@MainActor
final class ContextCompressor {
    static let shared = ContextCompressor()

    private var cache: [String: String] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]
    private let cacheLimit = 64

    func summarize(context: String, selection: String) async -> String? {
        guard Settings.deepContextEnabled else { return nil }
        let config = Settings.activeConfig
        guard config.isConfigured else { return nil }
        guard !context.isEmpty else { return nil }

        let key = cacheKey(context: context, selection: selection, config: config)
        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task<String?, Never> { @MainActor in
            let provider = config.makeProvider(disableThinking: true)
            var output = ""
            do {
                let messages: [ChatMessage] = [
                    .system(Prompt.contextSummary),
                    .user(Prompt.summaryMessage(context: context, selection: selection)),
                ]
                for try await chunk in provider.stream(messages: messages) {
                    if Task.isCancelled { break }
                    output += chunk
                    if output.count > 4_000 { break }
                }
            } catch {
                output = ""
            }
            let cleaned = DeepContextComposer.cleanSummary(output)
            self.inFlight[key] = nil
            if let cleaned {
                if self.cache.count >= self.cacheLimit { self.cache.removeAll() }
                self.cache[key] = cleaned
            }
            return cleaned
        }
        inFlight[key] = task
        return await task.value
    }

    private func cacheKey(context: String, selection: String, config: ProviderConfig) -> String {
        let raw = [config.id.uuidString, config.model, selection, context].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }
}
