import AppKit

/// 面包屑：显示当前卡片在树里的路径，点击祖先可回跳。
final class BreadcrumbBar: NSView {
    var onSelect: ((Int) -> Void)?

    private var titles: [String] = []
    private var items: [(view: NSView, width: CGFloat)] = []

    private let hairline = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        addSubview(hairline)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(titles: [String]) {
        guard self.titles != titles else { return }
        self.titles = titles
        rebuild()
    }

    private func rebuild() {
        items.forEach { $0.view.removeFromSuperview() }
        items.removeAll()

        for (index, title) in titles.enumerated() {
            if index > 0 {
                let chevron = NSTextField(labelWithString: "›")
                chevron.font = NSFont.systemFont(ofSize: 11)
                chevron.textColor = .tertiaryLabelColor
                items.append((chevron, 12))
                addSubview(chevron)
            }

            let isCurrent = index == titles.count - 1
            let short = title.count > 14 ? String(title.prefix(14)) + "…" : title
            let button = PointerButton(title: short, target: self, action: #selector(handleTap(_:)))
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = NSFont.systemFont(ofSize: 11.5, weight: isCurrent ? .medium : .regular)
            button.contentTintColor = isCurrent ? .labelColor : .secondaryLabelColor
            button.isEnabled = !isCurrent
            button.tag = index
            let width = min(max(button.intrinsicContentSize.width, 16), 130)
            items.append((button, width))
            addSubview(button)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)

        var x: CGFloat = Theme.horizontalInset
        let limit = bounds.width - Theme.horizontalInset
        for item in items {
            if x + item.width > limit {
                item.view.isHidden = true
                continue
            }
            item.view.isHidden = false
            item.view.frame = NSRect(x: x, y: 7, width: item.width, height: 16)
            x += item.width
        }
    }

    @objc private func handleTap(_ sender: NSButton) {
        onSelect?(sender.tag)
    }
}
