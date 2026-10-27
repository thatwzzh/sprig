import AppKit

/// 删除确认框：应用级 modal（`NSApp.runModal`），居中在面板上，不带图标。
/// 不用 `NSAlert`：它会固定占一块图标区（新版系统还把图标排在标题上方），
/// 把 icon 换成空图也只会留下空白，所以这里自绘一张和系统 alert 观感一致的卡片。
///
/// 键盘：← → 在「取消 / 删除」之间切换选中，回车执行选中项，Esc 取消。
final class ConfirmDialog: NSPanel {
    enum Result {
        case confirm
        case cancel
    }

    private let card: ConfirmCardView
    private var modalResult: Result = .cancel

    init(title: String, message: String) {
        card = ConfirmCardView(title: title, message: message)
        super.init(contentRect: NSRect(origin: .zero, size: card.preferredSize),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        isMovableByWindowBackground = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = card

        card.onCancel = { [weak self] in self?.finish(.cancel) }
        card.onConfirm = { [weak self] in self?.finish(.confirm) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 窗口级拦截，不依赖当前第一响应者
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:                        // Esc
            finish(.cancel)
            return true
        case 123:                       // ←
            card.moveSelection(-1)
            return true
        case 124:                       // →
            card.moveSelection(1)
            return true
        case 36, 76:                    // Return / Enter
            finish(card.isConfirmSelected ? .confirm : .cancel)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    func runModal(relativeTo parent: NSWindow?) -> Result {
        setContentSize(card.preferredSize)
        card.layoutSubtreeIfNeeded()
        position(relativeTo: parent)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        NSApp.runModal(for: self)
        orderOut(nil)
        return modalResult
    }

    /// 优先居中在面板上；面板不在时退回屏幕中央
    private func position(relativeTo parent: NSWindow?) {
        let size = frame.size
        let screen = parent?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let reference = parent?.frame ?? screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: reference.midX - size.width / 2,
                             y: reference.midY - size.height / 2)

        if let visible = screen?.visibleFrame {
            origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
            origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        }
        setFrameOrigin(origin)
    }

    private func finish(_ result: Result) {
        modalResult = result
        NSApp.stopModal(withCode: .OK)
    }
}

/// 对话框卡片：圆角背景 + 标题 / 说明 / 两个按钮，随外观刷新配色
private final class ConfirmCardView: NSView {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private static let width: CGFloat = 320
    private static let inset: CGFloat = 20
    private static let buttonHeight: CGFloat = 24
    private static let buttonSpacing: CGFloat = 8
    private static let cornerRadius: CGFloat = 12
    private static let ringInset: CGFloat = 3

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = PointerButton(title: "取消", target: nil, action: nil)
    private let deleteButton = PointerButton(title: "删除", target: nil, action: nil)
    private let selectionRing = RingView()

    /// 0 = 取消，1 = 删除；默认落在「删除」上
    private(set) var selectedIndex = 1

    var isConfirmSelected: Bool { selectedIndex == 1 }

    init(title: String, message: String) {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.width, height: 148)))
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        messageLabel.stringValue = message
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byWordWrapping

        configure(cancelButton, title: "取消", action: #selector(handleCancel))
        cancelButton.toolTip = "不删除（Esc）"

        configure(deleteButton, title: "删除", action: #selector(handleConfirm))
        deleteButton.attributedTitle = NSAttributedString(
            string: "删除",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.systemRed,
            ]
        )
        deleteButton.toolTip = "删除这张卡及其所有子卡"

        selectionRing.wantsLayer = true
        selectionRing.layer?.cornerRadius = 9
        selectionRing.layer?.borderWidth = 2
        selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor

        addSubview(titleLabel)
        addSubview(messageLabel)
        addSubview(selectionRing)
        addSubview(cancelButton)
        addSubview(deleteButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    // MARK: - 选中态

    func moveSelection(_ delta: Int) {
        select(index: min(max(0, selectedIndex + delta), 1))
    }

    func select(index: Int) {
        selectedIndex = index
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: - 布局

    var preferredSize: NSSize {
        let textWidth = Self.width - Self.inset * 2
        let titleHeight = Self.height(of: titleLabel.stringValue, font: Self.titleFont, width: textWidth)
        let messageHeight = Self.height(of: messageLabel.stringValue, font: Self.messageFont, width: textWidth)
        let height = Self.inset + titleHeight + 8 + messageHeight + 18 + Self.buttonHeight + Self.inset
        return NSSize(width: Self.width, height: ceil(height))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let textWidth = width - Self.inset * 2

        var y = bounds.height - Self.inset
        let titleHeight = Self.height(of: titleLabel.stringValue, font: Self.titleFont, width: textWidth)
        titleLabel.frame = NSRect(x: Self.inset, y: y - titleHeight, width: textWidth, height: titleHeight)
        y -= titleHeight + 8

        let messageHeight = Self.height(of: messageLabel.stringValue, font: Self.messageFont, width: textWidth)
        messageLabel.frame = NSRect(x: Self.inset, y: y - messageHeight, width: textWidth, height: messageHeight)

        let deleteWidth = max(deleteButton.intrinsicContentSize.width + 16, 68)
        deleteButton.frame = NSRect(x: width - Self.inset - deleteWidth,
                                    y: Self.inset,
                                    width: deleteWidth,
                                    height: Self.buttonHeight)
        let cancelWidth = max(cancelButton.intrinsicContentSize.width + 16, 68)
        cancelButton.frame = NSRect(x: deleteButton.frame.minX - Self.buttonSpacing - cancelWidth,
                                    y: Self.inset,
                                    width: cancelWidth,
                                    height: Self.buttonHeight)

        let target = selectedIndex == 1 ? deleteButton : cancelButton
        selectionRing.frame = target.frame.insetBy(dx: -Self.ringInset, dy: -Self.ringInset)
    }

    private static var titleFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .semibold) }
    private static var messageFont: NSFont { NSFont.systemFont(ofSize: 12) }

    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 13)
        button.title = title
        button.target = self
        button.action = action
    }

    @objc private func handleCancel() {
        onCancel?()
    }

    @objc private func handleConfirm() {
        onConfirm?()
    }
}

/// 选中框：只画边框，不参与点击命中
private final class RingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
