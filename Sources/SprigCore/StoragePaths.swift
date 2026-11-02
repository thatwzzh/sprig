import Foundation

/// 存储位置的判断：哪些目录是 macOS 的「受保护文件夹」。
///
/// 放这些目录能用，但首次访问要授权，而且系统按「应用身份」记账——
/// 换一个 app 版本（adhoc 签名必然换）就会再问一次。UI 上要提示用户。
public enum StoragePaths {
    static let protectedFolders = ["Documents", "Desktop", "Downloads",
                                   "Movies", "Music", "Pictures"]

    public static func isProtected(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        let path = url.standardizedFileURL.path
        for folder in protectedFolders {
            if path == "\(home)/\(folder)" || path.hasPrefix("\(home)/\(folder)/") {
                return true
            }
        }
        // iCloud Drive 挂在 Mobile Documents 下
        return path.contains("/Library/Mobile Documents")
    }
}
