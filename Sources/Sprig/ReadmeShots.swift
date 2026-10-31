import AppKit
import SprigCore

/// README 用图。纯开发期工具：只在 `--readme-shots` 下调用，不参与产品逻辑。
@MainActor
enum ReadmeShots {
    private static let sample = """
    ## 反向代理配置

    要点有三个：

    - **多路复用**：一个连接跑多个请求
    - 头部压缩用 `HPACK`
    - 服务端推送已废弃

    ```nginx
    server {
        listen 80;
        server_name example.com;
    }
    ```

    | 维度 | Redis | Memcached |
    | --- | --- | --- |
    | 持久化 | 支持 | 不支持 |
    """

}

/// 从上往下排的容器：`isFlipped` 让 y 从顶部开始加，拼图时不用倒着算。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
