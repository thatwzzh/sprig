import AppKit
import SprigCore

/// 回答区顶部的问题条：显示当前这张卡对应的问题原文（子卡显示「关于「片段」」）。
/// 面包屑回答的是「我在树的哪里」，这里回答的是「我在看什么问题的答案」。
///
/// 外部选词卡还会在问题上方多一行来源（网页/对话/文档/剪贴板）；
/// 有上下文快照时右侧出一个 ⓘ，点开预览实际送进模型的上下文和 token 估算。
final class QuestionHeaderView: NSView, NSPopoverDelegate {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let contextButton = PointerButton()

    /// 点来源行时回调（P1 打开原文用；P0 不设置）
    var onOpenSource: (() -> Void)?
    /// 上下文预览的显示/关闭（PanelController 用它挡住“失焦沉底”逻辑）
    var onPreviewVisibilityChanged: ((Bool) -> Void)?

    private(set) var sourceText: String = ""
    private var contextText: String?
    private var previewPopover: NSPopover?

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        label.font = Theme.questionFont
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = true
        addSubview(label)

        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .tertiaryLabelColor
        sourceLabel.maximumNumberOfLines = 1
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.isSelectable = false
        sourceLabel.isHidden = true
        addSubview(sourceLabel)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleSourceClick))
        sourceLabel.addGestureRecognizer(click)

        contextButton.isBordered = false
        contextButton.bezelStyle = .inline
        contextButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "上下文预览")
        contextButton.imagePosition = .imageOnly
        contextButton.imageScaling = .scaleProportionallyDown
        contextButton.contentTintColor = .tertiaryLabelColor
        contextButton.target = self
        contextButton.action = #selector(toggleContextPreview)
        contextButton.isHidden = true
        addSubview(contextButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String) {
        configure(text: text, source: nil, context: nil)
    }

    func configure(text: String, source: SelectionSource?, context: String? = nil) {
        label.stringValue = text
        sourceText = source?.displayLine ?? ""
        sourceLabel.stringValue = sourceText
        sourceLabel.isHidden = sourceText.isEmpty
        sourceLabel.toolTip = source?.displayDetail
        contextText = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContext = !(contextText?.isEmpty ?? true)
        contextButton.isHidden = sourceText.isEmpty || !hasContext
        if hasContext, let contextText {
            contextButton.toolTip = "上下文 " + TokenEstimator.describe(contextText) + "（点击预览）"
        } else {
            contextButton.toolTip = nil
            closeContextPreview()
        }
        needsLayout = true
    }

    @objc private func handleSourceClick() {
        guard !sourceLabel.isHidden else { return }
        onOpenSource?()
    }

    // MARK: - 上下文预览

    @objc private func toggleContextPreview() {
        if previewPopover != nil {
            closeContextPreview()
            return
        }
        guard let contextText, !contextText.isEmpty else { return }
        let controller = ContextPreviewController(text: contextText)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = controller.preferredSize
        popover.delegate = self
        previewPopover = popover
        onPreviewVisibilityChanged?(true)
        popover.show(relativeTo: contextButton.bounds, of: contextButton, preferredEdge: .maxY)
    }

    func closeContextPreview() {
        guard let previewPopover else { return }
        self.previewPopover = nil
        previewPopover.performClose(nil)
        onPreviewVisibilityChanged?(false)
    }

    func popoverDidClose(_ notification: Notification) {
        guard previewPopover != nil else { return }
        previewPopover = nil
        onPreviewVisibilityChanged?(false)
    }

    var debugText: String { label.stringValue }
    var debugSourceText: String { sourceText }
    var debugContextTools: String {
        "contextButton:\(contextButton.isHidden ? "hidden" : "shown") "
            + "context:" + TokenEstimator.describe(contextText ?? "")
    }

    override func layout() {
        super.layout()
        let inset = Theme.horizontalInset
        let width = max(0, bounds.width - inset * 2)
        let hasSource = !sourceLabel.isHidden
        let sourceHeight: CGFloat = 16
        if hasSource {
            var labelWidth = width
            if !contextButton.isHidden {
                let buttonSize: CGFloat = 18
                contextButton.frame = NSRect(x: inset + width - buttonSize,
                                             y: max(0, bounds.height - sourceHeight - 2),
                                             width: buttonSize,
                                             height: buttonSize)
                labelWidth = max(0, width - buttonSize - 4)
            } else {
                contextButton.frame = .zero
            }
            sourceLabel.frame = NSRect(x: inset,
                                       y: max(0, bounds.height - sourceHeight - 1),
                                       width: labelWidth,
                                       height: sourceHeight)
            label.frame = NSRect(x: inset,
                                 y: 3,
                                 width: width,
                                 height: max(0, bounds.height - sourceHeight - 6))
        } else {
            contextButton.frame = .zero
            label.frame = NSRect(x: inset, y: 3, width: width, height: max(0, bounds.height - 6))
        }
    }
}

/// 上下文预览：只读、可滚动、可选中复制。
@MainActor
private final class ContextPreviewController: NSViewController {
    let preferredSize = NSSize(width: 460, height: 340)
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredSize))
        root.wantsLayer = true

        let header = NSTextField(labelWithString: "送进模型的上下文 · " + TokenEstimator.describe(text))
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .labelColor
        header.frame = NSRect(x: 14, y: preferredSize.height - 30, width: preferredSize.width - 28, height: 18)
        root.addSubview(header)

        let scroll = NSScrollView(frame: NSRect(x: 14, y: 14,
                                                width: preferredSize.width - 28,
                                                height: preferredSize.height - 52))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0,
                                                width: scroll.contentSize.width,
                                                height: scroll.contentSize.height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.string = text
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        root.addSubview(scroll)

        view = root
    }
}
