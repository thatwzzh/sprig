import Foundation

/// 对外身份信息：菜单、窗口标题、Bundle 显示名都用这里，避免散落硬编码。
enum AppInfo {
    /// 中文名：知识点像树枝一样长出来，短、好记、不撞名
    static let name = "知枝"
    /// 英文名 / 项目名：从枝干上新抽出的嫩枝
    static let englishName = "Sprig"

    /// 旧包名，用于首次升级时迁移 UserDefaults（按新到旧排列）
    static let legacyBundleIdentifiers = ["com.catking.sprig", "com.catking.conceptlens"]
}
