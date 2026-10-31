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

    /// 同一项给出浅色/深色两个值，省得每行都写一遍 dynamic(light:dark:)
    static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
        dynamic(light: hex(light), dark: hex(dark))
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    /// 代码着色用的几个颜色。和主题无关：换成 11 套主题各配一套 token 色，
    /// 维护成本高且容易有一两套丑；这里统一用 One 的 token 色，深浅各一套。
    struct Syntax {
        var keyword: NSColor
        var value: NSColor
        var comment: NSColor
        var number: NSColor
        var type: NSColor
    }

    static let syntax = Syntax(
        keyword: pair(0xA626A4, 0xC678DD),
        value: pair(0x50A14F, 0x98C379),
        comment: pair(0xA0A1A7, 0x7F848E),
        number: pair(0x986801, 0xD19A66),
        type: pair(0x4078F2, 0x61AFEF))

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
    /// 下拉里悬停显示的说明（比如「Latte / Mocha」）
    var note: String = ""

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

    // MARK: - 8 套流行配色
    //
    // 取色来自各家官方调色板；浅色/深色成对给，跟随系统外观切换。
    // 之所以都取「浅色变体」：答案区没有自己的背景，浅色外观下必须能压在面板底色上。

    /// Solarized：Ethan Schoonover 的低对比配色，护眼经典
    static let solarized = MarkdownTheme(
        id: "solarized", name: "Solarized",
        palette: Palette(
            text: pair(0x657B83, 0x839496),
            heading: pair(0x586E75, 0x93A1A1),
            secondary: pair(0x93A1A1, 0x586E75),
            accent: pair(0x268BD2, 0x268BD2),
            codeText: pair(0x657B83, 0x93A1A1),
            codeBackground: pair(0xEEE8D5, 0x073642),
            inlineCodeBackground: pair(0xE7E0C9, 0x073642),
            rule: pair(0xDDD6C1, 0x0B3C47),
            tableHeader: pair(0xEEE8D5, 0x073642),
            tableBackground: pair(0xFDF6E3, 0x002B36)),
        bodySize: 14, lineSpacing: 5, paragraphSpacing: 10,
        heading1: 19, heading2: 16.5, heading3: 14.5,
        codeSize: 12.5, useSerif: false, note: "Light / Dark")

    /// One：Atom 的 One Light / One Dark，VS Code 装机量最高的主题
    static let one = MarkdownTheme(
        id: "one", name: "One",
        palette: Palette(
            text: pair(0x383A42, 0xABB2BF),
            heading: pair(0x202227, 0xE6E6E6),
            secondary: pair(0xA0A1A7, 0x7F848E),
            accent: pair(0x4078F2, 0x61AFEF),
            codeText: pair(0x383A42, 0xABB2BF),
            codeBackground: pair(0xF0F0F1, 0x21252B),
            inlineCodeBackground: pair(0xEDEDEE, 0x2C313A),
            rule: pair(0xE3E3E4, 0x3A3F4B),
            tableHeader: pair(0xF0F0F1, 0x2C313A),
            tableBackground: pair(0xFAFAFA, 0x282C34)),
        bodySize: 14, lineSpacing: 5, paragraphSpacing: 10,
        heading1: 19, heading2: 16.5, heading3: 14.5,
        codeSize: 12.5, useSerif: false, note: "One Light / One Dark")

    /// Catppuccin：近 2 万 star、360+ 个移植，Latte / Mocha
    static let catppuccin = MarkdownTheme(
        id: "catppuccin", name: "Catppuccin",
        palette: Palette(
            text: pair(0x4C4F69, 0xCDD6F4),
            heading: pair(0x4C4F69, 0xCDD6F4),
            secondary: pair(0x8C8FA1, 0xA6ADC8),
            accent: pair(0x1E66F5, 0x89B4FA),
            codeText: pair(0x4C4F69, 0xCDD6F4),
            codeBackground: pair(0xE6E9EF, 0x181825),
            inlineCodeBackground: pair(0xDCE0E8, 0x313244),
            rule: pair(0xCCD0DA, 0x313244),
            tableHeader: pair(0xE6E9EF, 0x313244),
            tableBackground: pair(0xEFF1F5, 0x1E1E2E)),
        bodySize: 14, lineSpacing: 6, paragraphSpacing: 10,
        heading1: 19, heading2: 16.5, heading3: 14.5,
        codeSize: 12.5, useSerif: false, note: "Latte / Mocha")

    /// Dracula：一千多万安装量，官方浅色变体是 Alucard
    static let dracula = MarkdownTheme(
        id: "dracula", name: "Dracula",
        palette: Palette(
            text: pair(0x1F1F1F, 0xF8F8F2),
            heading: pair(0x1F1F1F, 0xF8F8F2),
            secondary: pair(0x6C664B, 0x6272A4),
            accent: pair(0x644AC9, 0xBD93F9),
            codeText: pair(0x1F1F1F, 0xF8F8F2),
            codeBackground: pair(0xF3EDDC, 0x21222C),
            inlineCodeBackground: pair(0xEFE7D3, 0x44475A),
            rule: pair(0xE3D9BE, 0x44475A),
            tableHeader: pair(0xF3EDDC, 0x343746),
            tableBackground: pair(0xFFFBEB, 0x282A36)),
        bodySize: 14.5, lineSpacing: 6, paragraphSpacing: 11,
        heading1: 19, heading2: 16.5, heading3: 14.5,
        codeSize: 12.5, useSerif: false, note: "Alucard / Dracula")

    /// Nord：低饱和冷色，浅色用 Nord Light 的雪白底
    static let nord = MarkdownTheme(
        id: "nord", name: "Nord",
        palette: Palette(
            text: pair(0x2E3440, 0xD8DEE9),
            heading: pair(0x2E3440, 0xECEFF4),
            secondary: pair(0x6D7A8C, 0x7B88A1),
            accent: pair(0x5E81AC, 0x88C0D0),
            codeText: pair(0x2E3440, 0xD8DEE9),
            codeBackground: pair(0xE5E9F0, 0x2E3440),
            inlineCodeBackground: pair(0xD8DEE9, 0x3B4252),
            rule: pair(0xD8DEE9, 0x434C5E),
            tableHeader: pair(0xE5E9F0, 0x3B4252),
            tableBackground: pair(0xECEFF4, 0x2E3440)),
        bodySize: 14, lineSpacing: 6, paragraphSpacing: 11,
        heading1: 19, heading2: 16.5, heading3: 14.5,
        codeSize: 12.5, useSerif: false, note: "Nord Light / Nord")

    /// Gruvbox：暖色复古，来自 Vim 社区
    static let gruvbox = MarkdownTheme(
        id: "gruvbox", name: "Gruvbox",
        palette: Palette(
            text: pair(0x3C3836, 0xEBDBB2),
            heading: pair(0x282828, 0xFBF1C7),
            secondary: pair(0x928374, 0x928374),
            accent: pair(0x076678, 0x83A598),
            codeText: pair(0x3C3836, 0xEBDBB2),
            codeBackground: pair(0xF2E5BC, 0x1D2021),
            inlineCodeBackground: pair(0xEBDBB2, 0x32302F),
            rule: pair(0xD5C4A1, 0x3C3836),
            tableHeader: pair(0xF2E5BC, 0x32302F),
            tableBackground: pair(0xFBF1C7, 0x282828)),
        bodySize: 14, lineSpacing: 5, paragraphSpacing: 10,
        heading1: 19, heading2: 16.5, heading3: 14.5,
        codeSize: 12.5, useSerif: false, note: "Light / Dark")

    /// Rosé Pine：低饱和莫兰迪，Dawn / Moon
    static let rosePine = MarkdownTheme(
        id: "rosepine", name: "Rosé Pine",
        palette: Palette(
            text: pair(0x575279, 0xE0DEF4),
            heading: pair(0x464261, 0xE0DEF4),
            secondary: pair(0x9893A5, 0x908CAA),
            accent: pair(0x286983, 0x9CCFD8),
            codeText: pair(0x575279, 0xE0DEF4),
            codeBackground: pair(0xF2E9E1, 0x1F1D2E),
            inlineCodeBackground: pair(0xEDE3DA, 0x393552),
            rule: pair(0xE7DCD2, 0x393552),
            tableHeader: pair(0xF2E9E1, 0x2A273F),
            tableBackground: pair(0xFAF4ED, 0x232136)),
        bodySize: 14.5, lineSpacing: 6, paragraphSpacing: 12,
        heading1: 19, heading2: 16.5, heading3: 14.5,
        codeSize: 12.5, useSerif: false, note: "Dawn / Moon")

    /// Tokyo Night：蓝紫调，增长最快的主题之一；浅色用 Day
    static let tokyoNight = MarkdownTheme(
        id: "tokyonight", name: "Tokyo Night",
        palette: Palette(
            text: pair(0x3760BF, 0xA9B1D6),
            heading: pair(0x2E7DE9, 0xC0CAF5),
            secondary: pair(0x6172B0, 0x565F89),
            accent: pair(0x2E7DE9, 0x7AA2F7),
            codeText: pair(0x3760BF, 0xA9B1D6),
            codeBackground: pair(0xD0D5E3, 0x16161E),
            inlineCodeBackground: pair(0xC4C8DA, 0x292E42),
            rule: pair(0xBFC4D6, 0x3B4261),
            tableHeader: pair(0xD0D5E3, 0x1F2335),
            tableBackground: pair(0xE1E2E7, 0x1A1B26)),
        bodySize: 14, lineSpacing: 5, paragraphSpacing: 10,
        heading1: 19, heading2: 16.5, heading3: 14.5,
        codeSize: 12.5, useSerif: false, note: "Day / Night")

    /// GitHub 放在第一位：它是默认主题
    static let all: [MarkdownTheme] = [
        .github, .newsprint,
        .solarized, .one, .catppuccin, .dracula,
        .nord, .gruvbox, .rosePine, .tokyoNight,
    ]

    static var fallback: MarkdownTheme { .github }

    static func named(_ id: String) -> MarkdownTheme {
        all.first { $0.id == id } ?? fallback
    }

    static var current: MarkdownTheme { named(Settings.readingTheme) }
}
