import Foundation

/// 所有 provider 共用一个 URLSession。
///
/// 之前每个 provider 在 init 里各建一个 session，而 `Settings.provider` 是每次发消息
/// 现构造一次——等于每次提问都新建 session：TLS 握手重做（首字延迟多 100–300ms），
/// 旧 session 不 invalidate 还会一直挂着。
public enum HTTPClient {
    public static let streaming: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = false
        // 面板可以同时挂着好几张卡在后台跑，别把并发卡太死
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()
}
