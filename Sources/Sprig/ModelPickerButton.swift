import AppKit

/// 输入框右侧的模型胶囊：显示当前模型名，点开切换。
/// 固定宽度是为了让输入框的换行位置稳定——名字长短不一时布局不跟着抖。
final class ModelPickerButton: NSButton {
    static let width: CGFloat = 136
    static let height: CGFloat = 22

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let horizontalPadding: CGFloat = 10
    private static let chevronSpace: CGFloat = 18

    var label: String = "" {
        didSet {
            guard label != oldValue else { return }
            toolTip = label
            needsDisplay = true
        }
    }

    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        title = ""
        wantsLayer = true
        setAccessibilityLabel("切换模型")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: Self.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = hovering || isHighlighted
        NSColor.labelColor.withAlphaComponent(highlighted ? 0.10 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textHeight = (label as NSString).size(withAttributes: textAttributes).height
        let textRect = NSRect(x: Self.horizontalPadding,
                              y: (bounds.height - textHeight) / 2,
                              width: bounds.width - Self.horizontalPadding - Self.chevronSpace,
                              height: textHeight)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (label as NSString).draw(in: textRect, withAttributes: [
            .font: Self.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        if let chevron = NSImage(systemSymbolName: "chevron.down",
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            let size = chevron.size
            let rect = NSRect(x: bounds.maxX - Self.horizontalPadding - size.width,
                              y: (bounds.height - size.height) / 2,
                              width: size.width,
                              height: size.height)
            chevron.draw(in: rect)
        }
    }
}
