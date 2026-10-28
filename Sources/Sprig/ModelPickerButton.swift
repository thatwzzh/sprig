import AppKit

/// 输入框右侧的模型胶囊：显示当前模型名，点开切换。
/// 固定宽度是为了让输入框的换行位置稳定——名字长短不一时布局不跟着抖。
final class ModelPickerButton: NSButton {
    static let width: CGFloat = 136
    static let height: CGFloat = 22

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let horizontalPadding: CGFloat = 10
    private static let chevronSpace: CGFloat = 18

    /// 流式输出时面板每 40ms 重排一次，这个按钮跟着重绘。
    /// 这几个属性原先都在 draw 里现构造——SF Symbol 的 withSymbolConfiguration 尤其贵——
    /// 改成常量后每次重绘只剩两次字符串绘制。
    private static let measureAttributes: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    private static let drawAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
    }()

    /// SF Symbol 上色后是烘焙进图像的，浅色/深色切换要重建，见 viewDidChangeEffectiveAppearance
    nonisolated(unsafe) private static var chevronImage: NSImage?

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Self.chevronImage = nil
        needsDisplay = true
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

        let textHeight = (label as NSString).size(withAttributes: Self.measureAttributes).height
        let textRect = NSRect(x: Self.horizontalPadding,
                              y: (bounds.height - textHeight) / 2,
                              width: bounds.width - Self.horizontalPadding - Self.chevronSpace,
                              height: textHeight)
        (label as NSString).draw(in: textRect, withAttributes: Self.drawAttributes)

        if let chevron = Self.chevron() {
            let size = chevron.size
            let rect = NSRect(x: bounds.maxX - Self.horizontalPadding - size.width,
                              y: (bounds.height - size.height) / 2,
                              width: size.width,
                              height: size.height)
            chevron.draw(in: rect)
        }
    }

    private static func chevron() -> NSImage? {
        if let cached = chevronImage { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        chevronImage = image
        return image
    }
}
