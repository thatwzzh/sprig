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

    /// 输入框右侧让给「知识树按钮 + 联网搜索开关 + 模型切换按钮」的宽度。
    /// 树按钮即使隐藏也留位，否则开关树时输入框宽度变化会让文字重排、高度抖动。
    static let treeToggleSize: CGFloat = 22
    static let modelButtonGap: CGFloat = 8
    /// 联网搜索开关，和树按钮同尺寸，只是位置不同（贴着输入框）
    static let searchToggleSize: CGFloat = 22
    static let thoughtToggleSize: CGFloat = 22
    static let inputAccessoryWidth: CGFloat = treeToggleSize
        + modelButtonGap + searchToggleSize
        + modelButtonGap + thoughtToggleSize
        + modelButtonGap + ModelPickerButton.width
        + modelButtonGap
    /// 输入框里文字可用的宽度
    /// 答案区文本的真实宽度：面板 − 答案区左右留白（16×2）− 文本容器内边距（16×2）
    static let answerTextWidth: CGFloat = panelWidth - horizontalInset * 4

    static let inputTextWidth: CGFloat = panelWidth - horizontalInset * 2 - inputAccessoryWidth

    static let queryFont = NSFont.systemFont(ofSize: 15)
    static let composerFont = NSFont.systemFont(ofSize: 13)
    static let questionFont = NSFont.systemFont(ofSize: 12.5)
    static let answerFont = NSFont.systemFont(ofSize: 14)

    /// 段落样式：流式时每个 chunk 追加都要用，做成常量避免反复分配
    /// 搜索提示行用：段前段后都不留白，行距也压到最小，
    /// 否则一行提示会和正文之间空出一大块。
    static let searchLineParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }()

    /// 正文段落：行距 5、段后 10，接近 Typora 那种松弛的阅读节奏
    static let answerParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 10
        return style
    }()
}
