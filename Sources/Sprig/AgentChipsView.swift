import AppKit
import SprigCore

/// 设置页里的 agent 标签流：只显示名称，状态用名称后面的图标表示，一行放不下就换行。
///
/// 单击任何一条都会打开设置弹窗（检测出来的只能改模型，自定义的还能改名字和命令）。
/// 标签边框高亮表示「面板当前用的是它」。
final class AgentChipsView: NSView {
    static let chipHeight: CGFloat = 22
    private static let gap: CGFloat = 6
    /// 末尾「＋」和自定义接入那边同一个尺寸
    private static let addWidth: CGFloat = 32
    private static let addHeight: CGFloat = 26

    var onEdit: ((UUID) -> Void)?

    /// 预设自带的一句说明（「先去终端 codex login 一次」这种），放在 tooltip 里
    private static let presetNotes: [String: String] = {
        var notes: [String: String] = [:]
        for preset in AcpAgentPresets.builtin() where !preset.note.isEmpty {
            notes[preset.id] = preset.note
        }
        return notes
    }()

    private var chips: [AgentChip] = []
    private let addButton = PointerButton(title: "＋", target: nil, action: nil)
    private var activeID: UUID?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addButton.target = self
        addButton.action = #selector(handleAdd)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.font = .systemFont(ofSize: 13)
        addButton.toolTip = "添加一条自定义 agent"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 没实现") }

    @objc private func handleAdd() {
        onAdd?()
    }

    /// 末尾那个「＋」：加一条自定义 agent
    var onAdd: (() -> Void)?

    func reload(_ configs: [AgentConfig], active: UUID?, statuses: [UUID: AcpProbeStatus]) {
        for chip in chips { chip.removeFromSuperview() }
        chips = configs.map { config in
            let note = config.presetID.flatMap { Self.presetNotes[$0] }
            let chip = AgentChip(config: config, note: note)
            chip.status = statuses[config.id]
            chip.onTap = { [weak self] in self?.onEdit?(config.id) }
            addSubview(chip)
            return chip
        }
        addButton.removeFromSuperview()
        addSubview(addButton)
        activeID = active
        needsLayout = true
    }

    func setStatus(_ status: AcpProbeStatus?, for id: UUID) {
        chips.first { $0.config.id == id }?.status = status
    }


    override func layout() {
        super.layout()
        var x: CGFloat = 0
        // 往下让 2pt：末尾的「＋」比标签高，负 y 会被裁掉
        var y: CGFloat = 2
        for chip in chips {
            chip.isActive = chip.config.id == activeID
            let width = chip.desiredWidth
            if x > 0, x + width > bounds.width {
                x = 0
                y += Self.chipHeight + Self.gap
            }
            chip.frame = NSRect(x: x, y: y, width: width, height: Self.chipHeight)
            x += width + Self.gap
        }
        // 「＋」跟着最后一个标签走
        if x > 0, x + Self.addWidth > bounds.width {
            x = 0
            y += Self.chipHeight + Self.gap
        }
        // 按钮比标签高 4pt，往下让 2pt 让它和标签居中对齐
        addButton.frame = NSRect(x: x, y: y - (Self.addHeight - Self.chipHeight) / 2,
                                 width: Self.addWidth, height: Self.addHeight)
    }

    /// 无界面核对：每个标签的名字、状态、位置
    func debugChips() -> [String] {
        chips.map { $0.debugLine }
        + ["＋@\(Int(addButton.frame.minX)),\(Int(addButton.frame.minY))"]
    }
}

private final class AgentChip: NSView {
    let config: AgentConfig
    var onTap: (() -> Void)?

    var isActive = false { didSet { needsDisplay = true } }
    var status: AcpProbeStatus? { didSet { applyStatus() } }

    private let nameLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private static let font = NSFont.systemFont(ofSize: 12)

    init(config: AgentConfig, note: String?) {
        self.config = config
        super.init(frame: .zero)
        nameLabel.font = Self.font
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.stringValue = config.displayName
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(nameLabel)
        addSubview(iconView)
        // 检测出来的只是标签，不显示可点/可编辑的暗示
        var hints = [config.command]
        if let note { hints.append(note) }
        hints.append(config.presetID == nil ? "单击编辑" : "本机检测到，只能改模型")
        toolTip = hints.joined(separator: "\n")
        applyStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 没实现") }

    /// 名字实际需要的尺寸：用 cell 的 cellSize，而不是 intrinsicContentSize——
    /// 后者比 cell 少算 2~3pt，文字就会被截成「Co…」（省略号还要占位置）。
    private var textSize: NSSize {
        let size = nameLabel.cell?.cellSize ?? nameLabel.intrinsicContentSize
        return NSSize(width: ceil(size.width) + 2, height: ceil(size.height))
    }

    var desiredWidth: CGFloat {
        textSize.width + Self.paddingLeft + Self.gapToIcon + Self.iconSize + Self.paddingRight
    }

    private static let paddingLeft: CGFloat = 8
    private static let gapToIcon: CGFloat = 6
    private static let iconSize: CGFloat = 12
    private static let paddingRight: CGFloat = 8

    var debugLine: String {
        let name = config.displayName
        return "\(name) chip=\(Int(frame.width)) label=\(Int(nameLabel.frame.width))x\(Int(nameLabel.frame.height)) "
            + "need=\(Int(textSize.width))x\(Int(textSize.height)) @\(Int(frame.minX)),\(Int(frame.minY))"
    }

    /// 宽度是父视图按内容算好后设进来的，改尺寸必须重排内部，否则会留着「窄标签」的旧布局
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // 都用文字/图标自身的高度居中：框比文字高时，NSTextField 会把文字顶到上沿
        let labelHeight = max(textSize.height, 15)
        let labelWidth = max(0, bounds.width - Self.paddingLeft - Self.gapToIcon - Self.iconSize - Self.paddingRight)
        nameLabel.frame = NSRect(x: Self.paddingLeft, y: (bounds.height - labelHeight) / 2,
                                 width: labelWidth, height: labelHeight)
        // 图标下沿比文字多 1pt（实测算出来上 7 下 6），抬 0.5pt 补平
        iconView.frame = NSRect(x: bounds.width - Self.paddingRight - Self.iconSize,
                                y: (bounds.height - Self.iconSize) / 2 + 0.5,
                                width: Self.iconSize, height: Self.iconSize)
        if ProcessInfo.processInfo.environment["SPRIG_CHIP_TRACE"] != nil {
            let cell = nameLabel.cell?.cellSize.width ?? -1
            FileHandle.standardError.write(Data("LAYOUT \(config.displayName) chip=\(Int(bounds.width)) label=\(Int(nameLabel.frame.width)) cell=\(Int(cell)) font=\(nameLabel.font?.pointSize ?? -1)\n".utf8))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        let fill = isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.14)
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
        fill.setFill()
        path.fill()
        (isActive ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isActive ? 1.5 : 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    /// 状态图标统一用 SF Symbol + 固定 11pt，避免不同字形大小不一
    private func applyStatus() {
        let symbol: String
        let color: NSColor
        switch status {
        case .none:
            symbol = "circle"
            color = .tertiaryLabelColor
        case .running:
            symbol = "circle.dotted"
            color = .secondaryLabelColor
        case .ok:
            symbol = "checkmark.circle.fill"
            color = .systemGreen
        case .needsLogin:
            symbol = "exclamationmark.circle.fill"
            color = .systemOrange
        case .failed:
            symbol = "xmark.circle.fill"
            color = .systemRed
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        iconView.contentTintColor = color
    }
}
