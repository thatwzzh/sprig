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
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.controlAccentColor.withAlphaComponent(0.55),
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
            attributes[.font] = NSFont.systemFont(ofSize: Theme.answerFontPointSize, weight: .medium)
        }
        storage.append(NSAttributedString(string: text, attributes: attributes))
    }

    func scrollToBottom() {
        guard let scrollView = enclosingScrollView else { return }
        let documentHeight = frame.height
        let visibleHeight = scrollView.contentSize.height
        let target = max(0, documentHeight - visibleHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
