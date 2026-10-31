import AppKit

/// Agent 询问许可时浮在答案区底部。选项原样来自 agent，知枝不替它决定允许还是拒绝。
final class PermissionBar: NSVisualEffectView {
    var onPick: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var optionIDs: [String] = []

    init() {
        super.init(frame: .zero)
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(title: String, detail: String, options: [(id: String, name: String)]) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        optionIDs = options.map(\.0)
        buttons.forEach { $0.removeFromSuperview() }
        buttons = options.enumerated().map { index, option in
            let button = PointerButton(title: option.name, target: self, action: #selector(pick(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12)
            button.toolTip = option.name
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    func clear() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        optionIDs = []
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        titleLabel.frame = NSRect(x: 12, y: bounds.height - 22, width: width - 24, height: 16)
        if detailLabel.isHidden {
            detailLabel.frame = .zero
        } else {
            detailLabel.frame = NSRect(x: 12, y: bounds.height - 38, width: width - 24, height: 14)
        }
        guard !buttons.isEmpty else { return }
        let gap: CGFloat = 8
        let available = width - 24 - gap * CGFloat(buttons.count - 1)
        let buttonWidth = min(148, max(72, available / CGFloat(buttons.count)))
        var x: CGFloat = 12
        for button in buttons {
            button.frame = NSRect(x: x, y: 8, width: buttonWidth, height: 24)
            x += buttonWidth + gap
        }
    }

    @objc private func pick(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < optionIDs.count else { return }
        onPick?(optionIDs[sender.tag])
    }
}
