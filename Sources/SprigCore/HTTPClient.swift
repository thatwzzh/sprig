import Foundation

/// 所有 provider 共用一个 URLSession。
///
/// 之前每个 provider 在 init 里各建一个 session，而 `Settings.provider` 是每次发消息
/// 现构造一次——等于每次提问都新建 session：TLS 握手重做（首字延迟多 100–300ms），
/// 旧 session 不 invalidate 还会一直挂着。
enum HTTPClient {
    static let streaming: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = false
        // 流式请求同时只会有 1 条，留一点余量给会话标题之类的旁路请求
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()
}
