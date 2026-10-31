import CryptoKit
import Foundation

/// HTML 图块对应的图片文件名。面板渲染和 Markdown 导出都靠这个函数对齐。
public enum HtmlAsset {
    /// 内容哈希：同样的 HTML 只渲一次、只存一份图
    public static func name(for html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
        return "html-" + digest.map { String(format: "%02x", $0) }.prefix(16).joined() + ".png"
    }
}
