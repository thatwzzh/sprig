import AppKit

/// 选中文字后浮在选区下方的小动作条：只有「解释」。
/// 放在面板内部而不是独立窗口——独立窗口会抢 key window，导致面板失焦自动收起。
final class SelectionActionBar: NSVisualEffectView {
    static let barSize = NSSize(width: 56, height: 26)

    var onExplain: (() -> Void)?

    private let explainButton = PointerButton(title: "解释", target: nil, action: nil)

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

        addSubview(explainButton)
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
        // 只剩一个按钮，直接铺满整条，点击区域更大
        explainButton.frame = NSRect(x: 0, y: 4, width: bounds.width, height: bounds.height - 8)
    }

    @objc private func handleExplain() {
        onExplain?()
    }
}
