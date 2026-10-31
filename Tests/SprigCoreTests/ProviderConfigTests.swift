import XCTest
@testable import SprigCore

final class ProviderConfigTests: XCTestCase {
    func testBuiltinsAreZhipuAndOllama() {
        let builtins = ProviderConfig.builtins()
        let zhipu = builtins.first { $0.id == ProviderConfig.builtinZhipuID }
        XCTAssertEqual(zhipu?.kind, .openAICompatible)
        XCTAssertEqual(zhipu?.model, "glm-4.7-flash")
        XCTAssertEqual(zhipu?.resolvedCategory, .free)
        XCTAssertEqual(builtins.count, 2)
        XCTAssertEqual(builtins.first { $0.id == ProviderConfig.builtinOllamaID }?.resolvedCategory, .local)
    }

    /// 没显式存过分类时：Ollama 归本地，其余一律自定义。
    func testResolvedCategoryFallsBackToKind() {
        let local = ProviderConfig(name: "o", kind: .ollama,
                                   baseURL: "http://127.0.0.1:11434", model: "qwen3:4b-instruct")
        XCTAssertEqual(local.resolvedCategory, .local)

        let remote = ProviderConfig(name: "x", kind: .openAICompatible,
                                    baseURL: "https://api.deepseek.com", model: "deepseek-chat")
        XCTAssertEqual(remote.resolvedCategory, .custom)
    }
}
