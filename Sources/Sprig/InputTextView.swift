import AppKit

final class InputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: (() -> Void)?

    private let placeholderText: String

    init(placeholder: String = "问点什么…", font: NSFont = Theme.queryFont) {
        self.placeholderText = placeholder
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        super.init(frame: .zero, textContainer: container)

        isRichText = false
        isEditable = true
        isSelectable = true
        drawsBackground = false
        self.font = font
        textColor = .labelColor
        insertionPointColor = .controlAccentColor
        textContainerInset = NSSize(width: 0, height: 13)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    func setText(_ text: String) {
        string = text
        let length = (text as NSString).length
        setSelectedRange(NSRange(location: length, length: 0))
        onTextChange?()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = 小键盘 Enter, 53 = Esc
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.queryFont,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        (placeholderText as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// 非激活面板里 IME 候选框容易飘到屏幕角落。这里手工把光标矩形换算成屏幕坐标。
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let layoutManager, let textContainer, let window else {
            return super.firstRect(forCharacterRange: range, actualRange: actualRange)
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: actualRange)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let origin = textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        let inWindow = convert(rect, to: nil)
        return window.convertToScreen(inWindow)
    }
}
