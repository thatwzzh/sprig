import Foundation

/// 所有 provider 共用一个 URLSession。
///
/// 之前每个 provider 在 init 里各建一个 session，而 `Settings.provider` 是每次发消息
/// 现构造一次——等于每次提问都新建 session：TLS 握手重做（首字延迟多 100–300ms），
/// 旧 session 不 invalidate 还会一直挂着。
public enum HTTPClient {
    private static let lock = NSLock()
    private static var cached: URLSession?
    private static var cachedProxy: String = ""

    /// 自定义代理，形如 `http://127.0.0.1:7890`。空字符串表示跟随系统设置。
    ///
    /// 为什么需要它：系统代理关着、但代理软件用 TUN 接管流量时，
    /// 部分域名会被接走却转发不出去（TLS 阶段直接断开）。
    /// 显式指定代理能绕开这种半接管状态。
    public static var proxy: String = "" {
        didSet {
            lock.lock()
            defer { lock.unlock() }
            if proxy != cachedProxy { cached = nil }
        }
    }

    public static var streaming: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let cached, cachedProxy == proxy { return cached }
        let session = make(proxy: proxy)
        cached = session
        cachedProxy = proxy
        return session
    }

    private static func make(proxy: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = false
        // 面板可以同时挂着好几张卡在后台跑，别把并发卡太死
        config.httpMaximumConnectionsPerHost = 8

        if let (host, port) = parseProxy(proxy) {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        return URLSession(configuration: config)
    }

    /// 接受 `127.0.0.1:7890`、`http://127.0.0.1:7890` 这类写法，只取 host + port。
    /// 带账号密码的代理需要系统钥匙串，这里不处理。
    static func parseProxy(_ raw: String) -> (String, Int)? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        guard let components = URLComponents(string: value),
              let host = components.host, !host.isEmpty else { return nil }
        return (host, components.port ?? 7890)
    }
}
