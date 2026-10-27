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
        isVerticallyResizable = false
        isHorizontallyResizable = false
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

    static func term(from url: URL) -> String? {
        guard url.scheme == "concept",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let term = components.queryItems?.first(where: { $0.name == "t" })?.value,
              !term.isEmpty else { return nil }
        return term
    }
}
