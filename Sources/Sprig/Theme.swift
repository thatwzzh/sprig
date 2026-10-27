import AppKit

enum Theme {
    static let panelWidth: CGFloat = 680
    static let treeWidth: CGFloat = 264
    /// 展开知识树时面板的最小高度，否则没有答案时树会被压成一条缝
    static let treeMinPanelHeight: CGFloat = 360
    static let cornerRadius: CGFloat = 14

    static let inputMinHeight: CGFloat = 46
    static let inputMaxHeight: CGFloat = 96
    static let answerMinHeight: CGFloat = 30
    static let answerMaxHeight: CGFloat = 420
    static let breadcrumbHeight: CGFloat = 28

    static let horizontalInset: CGFloat = 16

    static let queryFont = NSFont.systemFont(ofSize: 15)
    static let composerFont = NSFont.systemFont(ofSize: 13)
    static let questionFont = NSFont.systemFont(ofSize: 12.5)
    static let answerFont = NSFont.systemFont(ofSize: 13.5)
    static let answerFontPointSize: CGFloat = 13.5

    static var answerParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 6
        return style
    }
}
