import XCTest
@testable import SprigCore

/// 免费模型的选择策略是纯逻辑，值得钉住——
/// 清单每周都在变，靠人肉检查「有没有选到音乐模型」不现实。
final class FreeModelCatalogTests: XCTestCase {
    private func model(_ id: String, context: Int = 262_000) -> FreeModel {
        FreeModel(id: id, name: id, contextLength: context)
    }

    func testPrefersQwenWhenAvailable() {
        let models = [
            model("google/gemma-4-31b-it:free"),
            model("qwen/qwen3.8-27b:free"),
            model("nvidia/nemotron-3.5-lightning:free"),
        ]
        XCTAssertEqual(FreeModelCatalog.preferred(from: models)?.id, "qwen/qwen3.8-27b:free")
    }

    /// 音乐生成、内容审核、代码专用、2.6B 小模型都不能拿来聊知识问答
    func testSkipsNonChatModels() {
        let models = [
            model("google/lyria-3-pro-preview", context: 1_048_000),
            model("nvidia/nemotron-3.5-content-safety:free"),
            model("cohere/north-mini-code:free"),
            model("poolside/laguna-s-2.1:free"),
            model("liquid/lfm-2.5-2.6b:free"),
            model("google/gemma-4-31b-it:free"),
        ]
        XCTAssertEqual(FreeModelCatalog.preferred(from: models)?.id, "google/gemma-4-31b-it:free")
    }

    /// 路由器行为不可预测，不如自己挑一个确定的
    func testPrefersConcreteModelOverRouter() {
        let models = [
            model("openrouter/free", context: 200_000),
            model("google/gemma-4-31b-it:free"),
        ]
        XCTAssertEqual(FreeModelCatalog.preferred(from: models)?.id, "google/gemma-4-31b-it:free")
    }

    /// 一个规则都不匹配时，按上下文长度兜底
    func testFallsBackToLongestContext() {
        let models = [
            model("someone/unknown-a:free", context: 128_000),
            model("someone/unknown-b:free", context: 512_000),
        ]
        XCTAssertEqual(FreeModelCatalog.preferred(from: models)?.id, "someone/unknown-b:free")
    }

    /// 上下文太小的直接排除
    func testSkipsTinyContextModels() {
        let models = [
            model("someone/tiny:free", context: 8_000),
            model("someone/normal:free", context: 262_000),
        ]
        XCTAssertEqual(FreeModelCatalog.preferred(from: models)?.id, "someone/normal:free")
    }

    func testReturnsNilForEmptyList() {
        XCTAssertNil(FreeModelCatalog.preferred(from: []))
    }

    func testContextLabel() {
        XCTAssertEqual(model("x", context: 1_048_000).contextLabel, "1.0M")
        XCTAssertEqual(model("x", context: 262_000).contextLabel, "262K")
        XCTAssertEqual(model("x", context: 0).contextLabel, "")
    }
}
