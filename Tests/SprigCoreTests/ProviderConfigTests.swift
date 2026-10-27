import XCTest
@testable import SprigCore

final class ProviderConfigTests: XCTestCase {
    /// 自动导入的那条必须能引导到 OpenRouter 的领 Key 页面
    func testOpenRouterFreeHasKeyHelp() {
        let config = ProviderConfig.openRouterFree(model: "google/gemma-4-31b-it:free")
        XCTAssertEqual(config.kind, .openAICompatible)
        XCTAssertEqual(config.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(config.keyHelp?.url.absoluteString, "https://openrouter.ai/keys")
        XCTAssertTrue(config.isBuiltin, "内置才能保证每日同步幂等")
        XCTAssertEqual(config.id, ProviderConfig.builtinOpenRouterFreeID)
    }

    func testGeminiHasKeyHelp() {
        let config = ProviderConfig(name: "g",
                                    kind: .gemini,
                                    baseURL: "https://generativelanguage.googleapis.com",
                                    model: "gemini-2.5-flash")
        XCTAssertEqual(config.keyHelp?.url.absoluteString, "https://aistudio.google.com/apikey")
    }

    /// 本地模型不需要 Key，也不该显示「去获取」
    func testOllamaHasNoKeyHelp() {
        let config = ProviderConfig(name: "o",
                                    kind: .ollama,
                                    baseURL: "http://127.0.0.1:11434",
                                    model: "qwen3:4b-instruct")
        XCTAssertNil(config.keyHelp)
    }

    /// 不认识的网关不瞎猜地址，宁可不给入口
    func testUnknownCompatibleHasNoKeyHelp() {
        let config = ProviderConfig(name: "x",
                                    kind: .openAICompatible,
                                    baseURL: "https://api.deepseek.com",
                                    model: "deepseek-chat")
        XCTAssertNil(config.keyHelp)
    }

    /// baseURL 大小写不同也要认出来
    func testOpenRouterDetectedCaseInsensitively() {
        let config = ProviderConfig(name: "x",
                                    kind: .openAICompatible,
                                    baseURL: "https://OpenRouter.ai/api/v1",
                                    model: "a:free")
        XCTAssertNotNil(config.keyHelp)
    }
}
