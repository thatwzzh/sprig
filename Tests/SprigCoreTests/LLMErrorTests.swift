import XCTest
@testable import SprigCore

/// 错误文案直接决定用户能不能自己解决。这些测试钉住「按状态码给不同建议」的行为。
final class LLMErrorTests: XCTestCase {
    func testAuthErrorsMentionKey() {
        for status in [401, 403] {
            let message = LLMError.http(status: status, body: "").localizedDescription
            XCTAssertTrue(message.contains("API Key"), "\(status) 应提示 Key 有问题：\(message)")
        }
    }

    func testRateLimitSuggestsWaiting() {
        let message = LLMError.http(status: 429, body: "").localizedDescription
        XCTAssertTrue(message.contains("限流"))
        XCTAssertTrue(message.contains("等一分钟"))
    }

    func testNotFoundMentionsBaseURL() {
        let message = LLMError.http(status: 404, body: "").localizedDescription
        XCTAssertTrue(message.contains("Base URL"))
    }

    func testServerErrorSaysNotYourFault() {
        let message = LLMError.http(status: 503, body: "").localizedDescription
        XCTAssertTrue(message.contains("对方服务器") || message.contains("不是本机"))
    }

    /// 5xx 之外的未知状态码要把响应体带出来，方便排查
    func testUnknownStatusCarriesBody() {
        let message = LLMError.http(status: 418, body: "teapot").localizedDescription
        XCTAssertTrue(message.contains("418"))
        XCTAssertTrue(message.contains("teapot"))
    }

    // MARK: - 网络错误翻译

    func testOfflineIsTranslated() {
        let message = LLMError.wrapping(URLError(.notConnectedToInternet)).localizedDescription
        XCTAssertTrue(message.contains("没有联网"))
    }

    func testTimeoutIsTranslated() {
        let message = LLMError.wrapping(URLError(.timedOut)).localizedDescription
        XCTAssertTrue(message.contains("超时"))
    }

    func testHostNotFoundMentionsBaseURL() {
        let message = LLMError.wrapping(URLError(.cannotFindHost)).localizedDescription
        XCTAssertTrue(message.contains("域名") || message.contains("Base URL"))
    }

    /// 已经是 LLMError 的不要被再包一层
    func testWrappingPreservesLLMError() {
        let original = LLMError.emptyResponse
        let wrapped = LLMError.wrapping(original)
        XCTAssertEqual(wrapped.localizedDescription, original.localizedDescription)
    }
}
