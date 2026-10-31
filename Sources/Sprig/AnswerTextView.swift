import AppKit
import SprigCore

/// 答案区。用 NSTextView 而不是 SwiftUI Text，理由只有一个但很硬：
/// 需要在答案里原生拖选任意文字（后面「选中存卡」全靠它），
/// SwiftUI 拿不到可靠的选区回调与自定义命中测试。
final class AnswerTextView: NSTextView {
    private var showsPlaceholder = false

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
            : Theme.panelWidth - Theme.horizontalInset * 2
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
        case .table, .chart, .html:
            break   // 表格/图表/HTML 在方法开头单独处理
        case .code:
            attributes[.font] = MarkdownTheme.current.monoFont
            attributes[.foregroundColor] = MarkdownTheme.current.palette.codeText
            attributes[.backgroundColor] = MarkdownTheme.current.palette.codeBackground
            attributes[.paragraphStyle] = Self.codeParagraph()
        }

        var inlineRuns = block.inlines
        // 末尾补一个换行：最后一段没有换行符时，AppKit 不会给这一行画底色
        if case .code = block.kind {
            inlineRuns = block.inlines.map { inline -> MarkdownInline in
                guard case .text(var value) = inline else { return inline }
                if !value.hasSuffix("\n") { value += "\n" }
                return .text(value)
            }
        }
        if case .html(let source) = block.kind {
            attributes[.font] = MarkdownTheme.current.monoFont
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.10)
            attributes[.paragraphStyle] = Self.codeParagraph()
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
                code[.backgroundColor] = MarkdownTheme.current.palette.inlineCodeBackground
                code[.foregroundColor] = MarkdownTheme.current.palette.codeText
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
    private static func imageAttachment(_ image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: Theme.answerFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Theme.answerParagraph,
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
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: Theme.answerFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Theme.answerParagraph,
        ]))
        return result
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

    /// 代码块里每个换行都是一个段落，段距必须归零，否则每行之间都会空一大截
    private static func codeParagraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = 0
        style.headIndent = 10
        style.firstLineHeadIndent = 10
        return style
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
    func appendSearchItems(_ items: [SearchItem]) {
        guard let storage = textStorage, !items.isEmpty else { return }

        let base: [NSAttributedString.Key: Any] = [
            .font: Theme.answerFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Theme.answerParagraph,
        ]
        let dim: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: Theme.answerParagraph,
        ]

        for item in items {
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(string: "\n · ", attributes: dim))

            if let url = URL(string: item.url), !item.url.isEmpty {
                var linked = base
                linked[.link] = url
                linked[.foregroundColor] = NSColor.linkColor
                line.append(NSAttributedString(string: item.title, attributes: linked))
            } else {
                line.append(NSAttributedString(string: item.title, attributes: base))
            }

            if let host = item.host {
                line.append(NSAttributedString(string: "  \(host)", attributes: dim))
            }
            storage.append(line)
        }
    }

    static func term(from url: URL) -> String? {
        guard url.scheme == "concept",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let term = components.queryItems?.first(where: { $0.name == "t" })?.value,
              !term.isEmpty else { return nil }
        return term
    }
}
