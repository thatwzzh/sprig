import AppKit

/// 选中文字后浮在选区下方的小动作条：解释 / 追问。
/// 放在面板内部而不是独立窗口——独立窗口会抢 key window，导致面板失焦自动收起。
final class SelectionActionBar: NSVisualEffectView {
    static let barSize = NSSize(width: 118, height: 26)

    var onExplain: (() -> Void)?
    var onAsk: (() -> Void)?

    private let explainButton = PointerButton(title: "解释", target: nil, action: nil)
    private let askButton = PointerButton(title: "追问", target: nil, action: nil)
    private let divider = NSView()

    init() {
        super.init(frame: .zero)
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor

        configure(explainButton, action: #selector(handleExplain))
        explainButton.contentTintColor = .controlAccentColor
        explainButton.toolTip = "就选中的内容生成一张子卡，结合上下文解释它在这里的含义"

        configure(askButton, action: #selector(handleAsk))
        askButton.toolTip = "带着选中内容继续提问"

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor

        addSubview(explainButton)
        addSubview(divider)
        addSubview(askButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: NSButton, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        button.target = self
        button.action = action
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let padding: CGFloat = 9

        let askWidth = askButton.intrinsicContentSize.width
        askButton.frame = NSRect(x: bounds.width - padding - askWidth, y: 4, width: askWidth, height: height - 8)

        divider.frame = NSRect(x: askButton.frame.minX - 7, y: 6, width: 1, height: height - 12)

        let explainWidth = explainButton.intrinsicContentSize.width
        explainButton.frame = NSRect(x: padding, y: 4, width: explainWidth, height: height - 8)
    }

    @objc private func handleExplain() {
        onExplain?()
    }

    @objc private func handleAsk() {
        onAsk?()
    }
}
