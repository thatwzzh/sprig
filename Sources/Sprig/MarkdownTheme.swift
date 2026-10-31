import AppKit

/// 阅读主题：把开源主题的排版参数（字号/行距/字体）抄成常量。
///
/// 不引 CSS——答案区是 `NSTextView`，选了文字要能「解释」、要能挂表格和图表附件，
/// 换成 WebView 这些全会丢。所以主题只影响排版，交互保持原生。
struct MarkdownTheme {
    /// 配色：参照 Typora 各主题的取色，明暗两套用动态色自动切换
    struct Palette {
        var text: NSColor
        var heading: NSColor
        var secondary: NSColor
        var accent: NSColor
        var codeText: NSColor
        var codeBackground: NSColor
        var inlineCodeBackground: NSColor
        var rule: NSColor
        var tableHeader: NSColor
        var tableBackground: NSColor
    }

    /// 明暗两条色值，跟随系统外观自动选
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    var id: String
    var name: String
    var palette: Palette
    var bodySize: CGFloat
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat
    var heading1: CGFloat
    var heading2: CGFloat
    var heading3: CGFloat
    var codeSize: CGFloat
    var useSerif: Bool

    var bodyFont: NSFont {
        if useSerif {
            // 中文优先宋体系，退到 Georgia；都拿不到就用系统字体
            for name in ["Songti SC", "STSong", "Georgia"] {
                if let serif = NSFont(name: name, size: bodySize) { return serif }
            }
        }
        return .systemFont(ofSize: bodySize)
    }

    var monoFont: NSFont {
        .monospacedSystemFont(ofSize: codeSize, weight: .regular)
    }

    var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    // MARK: - 预设

    static let `default` = MarkdownTheme(
        id: "default", name: "默认",
        palette: Palette(
            text: dynamic(light: hex(0x24292F), dark: hex(0xD6D6D6)),
            heading: dynamic(light: hex(0x1F2328), dark: hex(0xF0F0F0)),
            secondary: dynamic(light: hex(0x6E7781), dark: hex(0x9A9A9A)),
            accent: dynamic(light: hex(0x0969DA), dark: hex(0x6CB6FF)),
            codeText: dynamic(light: hex(0x24292F), dark: hex(0xD6D6D6)),
            codeBackground: dynamic(light: hex(0xF2F3F4), dark: hex(0x2B2B2B)),
            inlineCodeBackground: dynamic(light: hex(0xEFF1F3), dark: hex(0x353535)),
            rule: dynamic(light: hex(0xD8DEE4), dark: hex(0x3C3C3C)),
            tableHeader: dynamic(light: hex(0xEEF1F4), dark: hex(0x323232)),
            tableBackground: dynamic(light: hex(0xFBFCFD), dark: hex(0x262626))),
        bodySize: 14, lineSpacing: 5, paragraphSpacing: 10,
        heading1: 19, heading2: 16.5, heading3: 14.5,
        codeSize: 12.5, useSerif: false)

    /// 对齐 GitHub 的正文：紧一些、字号小一点，标题层级差距小
    static let github = MarkdownTheme(
        id: "github", name: "GitHub",
        palette: Palette(
            text: dynamic(light: hex(0x24292F), dark: hex(0xE6EDF3)),
            heading: dynamic(light: hex(0x1F2328), dark: hex(0xFFFFFF)),
            secondary: dynamic(light: hex(0x57606A), dark: hex(0x8B949E)),
            accent: dynamic(light: hex(0x0969DA), dark: hex(0x2F81F7)),
            codeText: dynamic(light: hex(0x24292F), dark: hex(0xE6EDF3)),
            codeBackground: dynamic(light: hex(0xF6F8FA), dark: hex(0x161B22)),
            inlineCodeBackground: dynamic(light: hex(0xEFF1F3), dark: hex(0x22272E)),
            rule: dynamic(light: hex(0xD0D7DE), dark: hex(0x30363D)),
            tableHeader: dynamic(light: hex(0xF6F8FA), dark: hex(0x1C2128)),
            tableBackground: dynamic(light: hex(0xFFFFFF), dark: hex(0x0D1117))),
        bodySize: 13.5, lineSpacing: 4, paragraphSpacing: 8,
        heading1: 18, heading2: 15.5, heading3: 14,
        codeSize: 12, useSerif: false)

    /// 对齐 Typora 的「出版感」：衬线正文、行距更松、段间距更大
    static let newsprint = MarkdownTheme(
        id: "newsprint", name: "Newsprint",
        palette: Palette(
            text: dynamic(light: hex(0x33302B), dark: hex(0xD8D2C8)),
            heading: dynamic(light: hex(0x1A1815), dark: hex(0xEFEAE2)),
            secondary: dynamic(light: hex(0x7A7466), dark: hex(0xA39B8C)),
            accent: dynamic(light: hex(0x8B5E3C), dark: hex(0xD2A679)),
            codeText: dynamic(light: hex(0x3A3630), dark: hex(0xD8D2C8)),
            codeBackground: dynamic(light: hex(0xF4F1EA), dark: hex(0x2A2723)),
            inlineCodeBackground: dynamic(light: hex(0xEDE8DE), dark: hex(0x33302B)),
            rule: dynamic(light: hex(0xDDD7CB), dark: hex(0x3B3730)),
            tableHeader: dynamic(light: hex(0xF1ECE2), dark: hex(0x302C27)),
            tableBackground: dynamic(light: hex(0xFBF9F4), dark: hex(0x24211D))),
        bodySize: 15, lineSpacing: 8, paragraphSpacing: 14,
        heading1: 21, heading2: 18, heading3: 16,
        codeSize: 12.5, useSerif: true)

    static let all: [MarkdownTheme] = [.default, .github, .newsprint]

    static func named(_ id: String) -> MarkdownTheme {
        all.first { $0.id == id } ?? .default
    }

    static var current: MarkdownTheme { named(Settings.readingTheme) }
}
