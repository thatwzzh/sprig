import AppKit
import SprigCore

/// 答案区。用 NSTextView 而不是 SwiftUI Text，理由只有一个但很硬：
/// 需要在答案里原生拖选任意文字（后面「选中存卡」全靠它），
/// SwiftUI 拿不到可靠的选区回调与自定义命中测试。
final class AnswerTextView: NSTextView {
    private var showsPlaceholder = false

    /// 代码块范围标记（值是底色）。不靠 `.backgroundColor` 逐字铺，
    /// 而是按行片段整段画；颜色存在属性里，绘制时不依赖「当前主题」。
    static let codeBlockKey = NSAttributedString.Key("sprigCodeBlock")

    /// 行内代码标记（值是底色）。`.backgroundColor` 只贴字形、没有圆角也没有内边距，
    /// 中文正文里会显得很挤，所以同样自己画。
    static let inlineCodeKey = NSAttributedString.Key("sprigInlineCode")

    override func draw(_ dirtyRect: NSRect) {
        drawCodeBlockBackgrounds()
        drawInlineCodeBackgrounds()
        super.draw(dirtyRect)
    }

    /// 整块底色 + 圆角。
    ///
    /// 逐字符的 `.backgroundColor` 有两个毛病：只覆盖字形宽度（首行尤其明显，
    /// 行尾不到右边界），而且没法做圆角。这里按字形范围找到所有行片段，
    /// 取首尾行片段的上下沿，横跨整个文本容器画一个圆角矩形。
    private func drawCodeBlockBackgrounds() {
        guard let storage = textStorage, let layoutManager, let container = textContainer,
              storage.length > 0 else { return }
        layoutManager.ensureLayout(for: container)
        let origin = textContainerOrigin

        storage.enumerateAttribute(Self.codeBlockKey,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                     actualCharacterRange: nil)
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            // 用 used rect 而不是 fragment rect：末行的 fragment 会把段后间距
            // 一起算进高度（实测 18pt 的行变成 36pt），底色块底下就会多出一整行
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, _, _ in
                top = min(top, used.minY)
                bottom = max(bottom, used.maxY)
            }
            guard top < bottom else { return }

            // 上下各留 4pt：文字贴着边会显得挤
            let band = NSRect(x: origin.x,
                              y: origin.y + top - 4,
                              width: container.size.width,
                              height: bottom - top + 8)
            color.setFill()
            NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
        }
    }

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        super.init(frame: .zero, textContainer: container)

        isRichText = true
        isEditable = false
        isSelectable = true
        drawsBackground = false
        font = Theme.answerFont
        textColor = .labelColor
        textContainerInset = NSSize(width: Theme.horizontalInset, height: 12)
        // 必须允许纵向增长：否则视图高度被锁在视口内，
        // 超出部分既不显示、也不产生可滚动区域（容器 heightTracksTextView 是 false）
        isVerticallyResizable = true
        isHorizontallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = [.width]
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: MarkdownTheme.current.palette.accent.withAlphaComponent(0.45),
            .cursor: NSCursor.pointingHand,
        ]
        textContainer?.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 让视图高度等于实际内容高度，scrollView 才有东西可滚。
    /// 面板自身高度仍然由 `Theme.answerMaxHeight` 封顶，超出靠滚动看。
    func syncHeightToContent() {
        guard let layoutManager, let container = textContainer, bounds.width > 0 else { return }
        // 别碰 container.size：widthTracksTextView = true 时 NSTextView 自己会把它
        // 设成 frame.width - inset*2。手动设成 bounds.width 会让文字右侧多出 16pt，
        // 直接画到面板外面去（"状态管理核心"的"核"被裁就是这个原因）。
        layoutManager.ensureLayout(for: container)
        let textHeight = layoutManager.usedRect(for: container).height
        let target = max(textHeight + textContainerInset.height * 2, 0)
        guard abs(frame.height - target) > 0.5 else { return }
        setFrameSize(NSSize(width: bounds.width, height: target))
    }

    /// 点答案区就把焦点从输入框拿过来：否则 ⌘C 会去复制输入框里的文字
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    func reset() {
        textStorage?.setAttributedString(NSAttributedString(string: ""))
        setSelectedRange(NSRange(location: 0, length: 0))
        showsPlaceholder = false
    }

    /// 首 token 之前先占位，否则面板会空白几百毫秒到几秒，看起来像卡死
    func showThinkingPlaceholder() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.answerFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: Theme.answerParagraph,
        ]
        textStorage?.setAttributedString(NSAttributedString(string: "正在思考…", attributes: attributes))
        showsPlaceholder = true
    }

    func clearThinkingPlaceholder() {
        guard showsPlaceholder else { return }
        showsPlaceholder = false
        textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    func append(_ text: String, term: String?) {
        guard let storage = textStorage, !text.isEmpty else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.answerFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Theme.answerParagraph,
        ]
        if let term, let url = Self.conceptURL(for: term) {
            attributes[.link] = url
            attributes[.font] = NSFont.systemFont(ofSize: MarkdownTheme.current.bodySize, weight: .medium)
        }
        storage.append(NSAttributedString(string: text, attributes: attributes))
    }

    /// 按 Markdown 重画整段答案。流式期间是纯文本追加，结束后/切卡回来走这里。
    func renderRich(_ raw: String) {
        guard let storage = textStorage else { return }
        let output = NSMutableAttributedString()
        let blocks = MarkdownLite.parse(raw)
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes()))
            }
            output.append(attributed(block))
        }
        // 同一术语只让第一次出现的地方可点，避免满屏同样的下划线
        var seen = Set<String>()
        output.enumerateAttribute(.link, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            guard let url = value as? URL, let term = Self.term(from: url) else { return }
            if seen.contains(term) {
                output.removeAttribute(.link, range: range)
            } else {
                seen.insert(term)
            }
        }
        storage.setAttributedString(output)
        setSelectedRange(NSRange(location: 0, length: 0))
        showsPlaceholder = false
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        let theme = MarkdownTheme.current
        return [
            .font: theme.bodyFont,
            .foregroundColor: theme.palette.text,
            .paragraphStyle: theme.paragraph,
        ]
    }

    private func attributed(_ block: MarkdownBlock) -> NSAttributedString {
        // 用文本视图的真实可用宽度，别用面板常量——否则宽表/宽图会被右边缘裁掉
        let available = bounds.width > 0
            ? bounds.width - textContainerInset.width * 2
            : Theme.answerTextWidth
        if case .table(let header, let rows) = block.kind {
            return Self.tableAttachment(header: header, rows: rows, maxWidth: available)
        }
        if case .chart(let spec) = block.kind {
            let image = ChartImage.draw(spec: spec, maxWidth: available)
            return Self.imageAttachment(image)
        }
        if case .html(let source) = block.kind {
            // 渲染好了就画图；还没好（或渲染失败）先按代码块显示源码，不丢内容
            if let image = HtmlSnapshot.cached(source) { return Self.imageAttachment(image) }
        }
        if case .mermaid(let source) = block.kind {
            // 固定按 answerTextWidth 渲染并查找：布局过程中 bounds 会从 1 变到 640，
            // 拿它当键会导致「明明画好了却查不到」
            if let image = MermaidSnapshot.cached(source) {
                return Self.imageAttachment(image)
            }
            // 还没渲染好（或拿不到 mermaid 运行时）：显示源码，至少能读
            return Self.codeBlock(source, language: "mermaid")
        }
        if case .code(let language) = block.kind {
            return Self.codeBlock(block.plainText, language: language)
        }

        var attributes = baseAttributes()
        var prefix = ""

        switch block.kind {
        case .paragraph:
            break
        case .heading(let level):
            let theme = MarkdownTheme.current
            let size = level == 1 ? theme.heading1 : (level == 2 ? theme.heading2 : theme.heading3)
            attributes[.font] = NSFont.systemFont(ofSize: size, weight: level == 1 ? .bold : .semibold)
            attributes[.paragraphStyle] = Self.headingParagraph(level: level)
            attributes[.foregroundColor] = MarkdownTheme.current.palette.heading
        case .bullet:
            prefix = "•   "
            attributes[.paragraphStyle] = Self.indentedParagraph()
        case .ordered(let marker):
            prefix = "\(marker)  "
            attributes[.paragraphStyle] = Self.indentedParagraph()
        case .quote:
            attributes[.foregroundColor] = MarkdownTheme.current.palette.secondary
            attributes[.paragraphStyle] = Self.indentedParagraph(indent: 10)
        case .table, .chart, .html, .mermaid:
            break   // 表格/图表/HTML/Mermaid 在方法开头单独处理
        case .code:
            break   // 在上面的 codeBlock(_:) 里单独处理
        }

        var inlineRuns = block.inlines
        if case .html(let source) = block.kind {
            attributes[.font] = MarkdownTheme.current.monoFont
            attributes[.foregroundColor] = MarkdownTheme.current.palette.codeText
            attributes[.paragraphStyle] = Self.codeParagraph()
            attributes[Self.codeBlockKey] = MarkdownTheme.current.palette.codeBackground
            inlineRuns = [.text(source)]
        }

        let result = NSMutableAttributedString()
        if !prefix.isEmpty {
            result.append(NSAttributedString(string: prefix, attributes: attributes))
        }
        for inline in inlineRuns {
            switch inline {
            case .text(let value):
                result.append(NSAttributedString(string: value, attributes: attributes))
            case .code(let value):
                var code = attributes
                code[.font] = MarkdownTheme.current.monoFont
                code[.foregroundColor] = MarkdownTheme.current.palette.codeText
                code[Self.inlineCodeKey] = MarkdownTheme.current.palette.inlineCodeBackground
                result.append(NSAttributedString(string: value, attributes: code))
            case .bold(let value):
                var bold = attributes
                bold[.font] = NSFont.systemFont(ofSize: MarkdownTheme.current.bodySize, weight: .semibold)
                result.append(NSAttributedString(string: value, attributes: bold))
            case .italic(let value):
                var italic = attributes
                italic[.font] = NSFontManager.shared.convert(Theme.answerFont, toHaveTrait: .italicFontMask)
                result.append(NSAttributedString(string: value, attributes: italic))
            case .term(let value):
                var term = attributes
                term[.font] = NSFont.systemFont(ofSize: MarkdownTheme.current.bodySize, weight: .medium)
                term[.foregroundColor] = MarkdownTheme.current.palette.accent
                if let url = Self.conceptURL(for: value) { term[.link] = url }
                result.append(NSAttributedString(string: value, attributes: term))
            }
        }
        return result
    }

    /// 表格画成图片再挂进文本：不用 NSTextTable 那一套（API 难对齐、样式也难控），
    /// 图片参与排版，高度测量自然就对。
    /// 行内代码：圆角 + 左右 3pt 内边距，垂直按行片段居中。
    ///
    /// 内边距不能靠加空格（那会改到可复制的内容），而是把画出来的矩形
    /// 往两侧各撑 3pt——文字本身没动，底色块看起来就有了呼吸。
    private func drawInlineCodeBackgrounds() {
        guard let storage = textStorage, let layoutManager, let container = textContainer,
              storage.length > 0 else { return }
        layoutManager.ensureLayout(for: container)
        let origin = textContainerOrigin
        let font = MarkdownTheme.current.monoFont

        storage.enumerateAttribute(Self.inlineCodeKey,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphs, _ in
                let overlap = NSIntersectionRange(glyphRange, lineGlyphs)
                guard overlap.length > 0 else { return }
                let glyphRect = layoutManager.boundingRect(forGlyphRange: overlap, in: container)
                let pillHeight = min(lineRect.height - 1, ceil(font.pointSize + 5))
                // 按字形包围盒居中：行框中线比大写字形中心低 2pt 左右，用它居中文字会显高
                let pill = NSRect(x: origin.x + glyphRect.minX - 3,
                                  y: origin.y + glyphRect.midY - pillHeight / 2,
                                  width: glyphRect.width + 6,
                                  height: pillHeight)
                color.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 3.5, yRadius: 3.5).fill()
            }
        }
    }

    /// 图片块的段落样式：附件没有字体行框，段落间距只能自己带，
    /// 否则表格/图表会紧贴上一段（代码块尤其明显）
    private static func figureParagraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 14
        style.paragraphSpacing = 10
        return style
    }

    private static func imageAttachment(_ image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        return attachmentString(attachment)
    }

    /// 附件 + 收尾换行，整段共用同一个段落样式
    private static func attachmentString(_ attachment: NSTextAttachment) -> NSAttributedString {
        let style = figureParagraph()
        let result = NSMutableAttributedString(attachment: attachment)
        if result.length > 0 {
            result.addAttribute(.paragraphStyle, value: style,
                                range: NSRange(location: 0, length: result.length))
        }
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: MarkdownTheme.current.bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]))
        return result
    }

    private static func tableAttachment(header: [String], rows: [[String]], maxWidth: CGFloat) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return NSAttributedString() }
        let image = TableImage.draw(header: header, rows: rows, columns: columns,
                                    maxWidth: maxWidth, palette: MarkdownTheme.current.palette)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        return attachmentString(attachment)
    }

    private static func indentedParagraph(indent: CGFloat = 18) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = MarkdownTheme.current.lineSpacing
        style.paragraphSpacing = 5
        style.headIndent = indent
        style.firstLineHeadIndent = 0
        return style
    }

    /// 标题：上面留白多、下面少，和正文拉开层次（Typora 的默认观感）
    private static func headingParagraph(level: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacingBefore = level == 1 ? 14 : (level == 2 ? 12 : 10)
        style.paragraphSpacing = level == 1 ? 8 : 6
        return style
    }

    /// 代码块里每个换行都是一个段落，所以段距只能加在首行（before）和末行（after）上，
    /// 中间的行必须归零，否则每行之间都会空一大截。
    private static func codeParagraph(before: CGFloat = 0, after: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = 10
        style.firstLineHeadIndent = 10
        return style
    }

    /// 代码块：按语言着色，逐行给样式（首行前间距、末行后间距），
    /// 整段打上标记由 draw 统一铺底色。
    private static func codeBlock(_ text: String, language: String) -> NSAttributedString {
        let theme = MarkdownTheme.current
        let tokens = CodeHighlighter.tokens(text, language: language)
        let lineCount = max(1, text.components(separatedBy: "\n").count)
        var line = 0
        let result = NSMutableAttributedString()

        func attributes(_ kind: CodeTokenKind) -> [NSAttributedString.Key: Any] {
            var color = theme.palette.codeText
            switch kind {
            case .keyword: color = MarkdownTheme.syntax.keyword
            case .string: color = MarkdownTheme.syntax.value
            case .comment: color = MarkdownTheme.syntax.comment
            case .number: color = MarkdownTheme.syntax.number
            case .type: color = MarkdownTheme.syntax.type
            case .plain: break
            }
            return [
                .font: theme.monoFont,
                .foregroundColor: color,
                // 行框下方还有几 pt 余量，段后要放大一点，否则底色块贴着下一段
                .paragraphStyle: codeParagraph(before: line == 0 ? 10 : 0,
                                              after: line == lineCount - 1 ? 18 : 0),
                Self.codeBlockKey: theme.palette.codeBackground,
            ]
        }

        for token in tokens {
            let pieces = token.text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: attributes(token.kind)))
                    line += 1
                }
                if !piece.isEmpty {
                    result.append(NSAttributedString(string: piece, attributes: attributes(token.kind)))
                }
            }
        }
        return result
    }

    func scrollToBottom() {
        guard let scrollView = enclosingScrollView else { return }
        let documentHeight = frame.height
        let visibleHeight = scrollView.contentSize.height
        let target = max(0, documentHeight - visibleHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// 报错后面的「重试」：用链接实现，点击由 PanelController 分发
    func appendRetryLink() {
        guard let storage = textStorage else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: MarkdownTheme.current.bodySize, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor,
            .paragraphStyle: Theme.answerParagraph,
        ]
        attributes[.link] = URL(string: "sprig://retry")
        storage.append(NSAttributedString(string: "\n↻ 重试本次对话\n", attributes: attributes))
    }

    static func conceptURL(for term: String) -> URL? {
        var components = URLComponents()
        components.scheme = "concept"
        components.host = "term"
        components.queryItems = [URLQueryItem(name: "t", value: term)]
        return components.url
    }

    /// 搜索提示行：整行可点，点开看来源。用紧凑段落样式，不吃正文的段间距。
    func appendSearchLine(_ text: String, url: URL) {
        guard let storage = textStorage else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: Theme.searchLineParagraph,
            .link: url,
        ]
        attributes[.cursor] = NSCursor.pointingHand
        storage.append(NSAttributedString(string: text, attributes: attributes))
    }

    /// 联网搜索的来源列表：标题可点（打开原文），后面跟域名。
    /// 不用 `append(text:term:)` 是因为这里要混排三种属性（灰点、链接、暗色域名）。

    static func term(from url: URL) -> String? {
        guard url.scheme == "concept",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let term = components.queryItems?.first(where: { $0.name == "t" })?.value,
              !term.isEmpty else { return nil }
        return term
    }
}
