import AppKit

/// 面板内容：
///   顶部输入（新问题）
///   面包屑（路径）
///   问题条（当前卡的问题原文）
///   回答区
///   底部输入（基于当前卡继续问）
/// 手写 frame 布局：流式输出时每 40ms 就要改高度，Auto Layout 在这个频率下会抖。
///
/// 圆角由这一层（普通 NSView）负责裁切，毛玻璃作为它的子视图铺满。
/// 不要把 cornerRadius 直接设在 NSVisualEffectView 上：它的背景层是方的，
/// 裁切只作用于内容，四角会露出白色尖角。
final class PanelContentView: NSView {
    let inputScroll = NSScrollView()
    let bottomScroll = NSScrollView()
    let answerScroll = NSScrollView()
    let breadcrumb = BreadcrumbBar()
    let questionHeader = QuestionHeaderView()
    let separator = NSView()
    let bottomSeparator = NSView()
    let selectionBar = SelectionActionBar()
    let tree = KnowledgeTreeView()
    let treeToggle = PointerButton()
    let searchToggle = PointerButton()
    let modelButton = ModelPickerButton()

    var onTreeToggle: (() -> Void)?
    var onSearchToggle: (() -> Void)?

    private let blur = NSVisualEffectView()
    private let treeDivider = NSView()
    /// 弹 modal 时压在整个面板上的蒙层
    private let dimView = NSView()

    private var inputHeight: CGFloat = Theme.inputMinHeight
    private var answerHeight: CGFloat = 0
    private var questionHeight: CGFloat = 0
    private var bottomHeight: CGFloat = 0
    private(set) var treeVisible = false

    /// 左侧问答区的宽度（不含右侧树）
    /// 内容区宽度是固定的：面板 = 内容区 680 + 可选的树 264。
    /// 之前用 bounds.width 推算，窗口 resize 有一帧延迟，
    /// 那一帧里 bounds 还是旧值，会算出 416 或 944 这种错误宽度，
    /// 结果就是内容被压窄、或者文字画到面板外面去。
    private var contentWidth: CGFloat { Theme.panelWidth }

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = Theme.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor

        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        configure(inputScroll)
        inputScroll.hasVerticalScroller = false
        inputScroll.autohidesScrollers = true

        configure(bottomScroll)
        bottomScroll.hasVerticalScroller = false
        bottomScroll.autohidesScrollers = true

        configure(answerScroll)
        answerScroll.hasVerticalScroller = true
        answerScroll.scrollerStyle = .overlay

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor

        bottomSeparator.wantsLayer = true
        bottomSeparator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor

        addSubview(inputScroll)
        addSubview(breadcrumb)
        addSubview(questionHeader)
        addSubview(separator)
        addSubview(answerScroll)
        addSubview(bottomSeparator)
        addSubview(bottomScroll)
        addSubview(selectionBar)

        treeToggle.isBordered = false
        treeToggle.bezelStyle = .inline
        treeToggle.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "展开知识树")
        treeToggle.imagePosition = .imageOnly
        treeToggle.contentTintColor = .secondaryLabelColor
        treeToggle.target = self
        treeToggle.action = #selector(handleTreeToggle)
        treeToggle.toolTip = "展开知识树（⌘⇧T）"
        addSubview(treeToggle)

        searchToggle.isBordered = false
        searchToggle.bezelStyle = .inline
        searchToggle.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "联网搜索")
        searchToggle.imagePosition = .imageOnly
        searchToggle.contentTintColor = .secondaryLabelColor
        searchToggle.target = self
        searchToggle.action = #selector(handleSearchToggle)
        addSubview(searchToggle)
        refreshSearchToggle()

        addSubview(modelButton)

        treeDivider.wantsLayer = true
        treeDivider.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        addSubview(treeDivider)
        addSubview(tree)

        // 蒙层压在所有内容之上；modal 期间本来也点不到下面
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        dimView.isHidden = true
        addSubview(dimView)

        answerScroll.isHidden = true
        separator.isHidden = true
        bottomSeparator.isHidden = true
        bottomScroll.isHidden = true
        questionHeader.isHidden = true
        breadcrumb.isHidden = true
        selectionBar.isHidden = true
        tree.isHidden = true
        treeDivider.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ scroll: NSScrollView) {
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
    }

    func setHeights(input: CGFloat, answer: CGFloat, question: CGFloat, bottom: CGFloat) {
        inputHeight = input
        answerHeight = answer
        questionHeight = question
        bottomHeight = bottom
        // 尺寸变化后选区位置失效，先收起动作条，重新选择会再出现
        hideSelectionBar()
        needsLayout = true
    }

    /// modal 弹窗显示时给面板加一层蒙层
    func setDimmed(_ dimmed: Bool) {
        dimView.isHidden = !dimmed
    }

    func setTreeVisible(_ visible: Bool) {
        treeVisible = visible
        tree.isHidden = !visible
        treeDivider.isHidden = !visible
        treeToggle.isHidden = visible
        hideSelectionBar()
        needsLayout = true
    }

    @objc private func handleTreeToggle() {
        onTreeToggle?()
    }

    @objc private func handleSearchToggle() {
        onSearchToggle?()
    }

    /// 开关状态变了（自己点，或设置页改过）就同步图标颜色和提示
    func refreshSearchToggle() {
        let enabled = Settings.webSearchEnabled
        searchToggle.contentTintColor = enabled ? .controlAccentColor : .secondaryLabelColor
        if Settings.webSearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchToggle.toolTip = "联网搜索：还没填 Tavily Key（点击去设置）"
        } else {
            searchToggle.toolTip = enabled ? "联网搜索：开（点击关闭）" : "联网搜索：关（点击开启）"
        }
    }

    /// rect 为内容坐标系里的选区矩形（左下原点）
    func showSelectionBar(below rect: NSRect) {
        let size = SelectionActionBar.barSize
        let area = answerScroll.frame
        guard area.height > size.height + 8 else {
            hideSelectionBar()
            return
        }

        var y = rect.minY - size.height - 6
        if y < area.minY + 4 {
            y = rect.maxY + 6
        }
        y = min(max(area.minY + 4, y), area.maxY - size.height - 4)

        var x = rect.maxX - size.width
        x = min(max(8, x), max(8, contentWidth - size.width - 8))

        selectionBar.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        selectionBar.isHidden = false
        selectionBar.needsLayout = true
    }

    func hideSelectionBar() {
        selectionBar.isHidden = true
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        updateBlurMask()
        dimView.frame = bounds

        let width = contentWidth
        var top = bounds.height

        if treeVisible {
            treeDivider.frame = NSRect(x: width, y: 0, width: 1, height: bounds.height)
            tree.frame = NSRect(x: width + 1, y: 0, width: Theme.treeWidth - 1, height: bounds.height)
        }

        let rightEdge = width - Theme.horizontalInset
        treeToggle.frame = NSRect(x: rightEdge - Theme.treeToggleSize,
                                  y: bounds.height - 34,
                                  width: Theme.treeToggleSize,
                                  height: Theme.treeToggleSize)

        // 联网搜索开关：和模型胶囊同一行，垂直居中于输入框
        let searchY = top - inputHeight + (Theme.inputMinHeight - Theme.searchToggleSize) / 2
        searchToggle.frame = NSRect(
            x: rightEdge - Theme.treeToggleSize - Theme.modelButtonGap - Theme.searchToggleSize,
            y: searchY,
            width: Theme.searchToggleSize,
            height: Theme.searchToggleSize)

        // 模型按钮贴在输入框右下角：单行输入时正好垂直居中，多行时留在底部
        let pickerY = top - inputHeight + (Theme.inputMinHeight - ModelPickerButton.height) / 2
        modelButton.frame = NSRect(
            x: rightEdge - Theme.treeToggleSize - Theme.modelButtonGap - Theme.searchToggleSize
                - Theme.modelButtonGap - ModelPickerButton.width,
            y: pickerY,
            width: ModelPickerButton.width,
            height: ModelPickerButton.height)

        inputScroll.frame = NSRect(x: Theme.horizontalInset,
                                   y: top - inputHeight,
                                   width: width - Theme.horizontalInset * 2 - Theme.inputAccessoryWidth,
                                   height: inputHeight)
        top -= inputHeight

        guard answerHeight > 0 else {
            breadcrumb.isHidden = true
            questionHeader.isHidden = true
            separator.isHidden = true
            answerScroll.isHidden = true
            bottomSeparator.isHidden = true
            bottomScroll.isHidden = true
            return
        }

        breadcrumb.isHidden = false
        breadcrumb.frame = NSRect(x: 0, y: top - Theme.breadcrumbHeight, width: width, height: Theme.breadcrumbHeight)
        top -= Theme.breadcrumbHeight

        questionHeader.isHidden = questionHeight <= 0
        if questionHeight > 0 {
            questionHeader.frame = NSRect(x: 0, y: top - questionHeight, width: width, height: questionHeight)
            top -= questionHeight
        }

        separator.isHidden = false
        separator.frame = NSRect(x: 0, y: top - 1, width: width, height: 1)
        top -= 1

        bottomSeparator.isHidden = false
        bottomSeparator.frame = NSRect(x: 0, y: bottomHeight, width: width, height: 1)

        bottomScroll.isHidden = false
        bottomScroll.frame = NSRect(x: Theme.horizontalInset, y: 0,
                                    width: width - Theme.horizontalInset * 2, height: bottomHeight)

        answerScroll.isHidden = false
        // 右边留 8pt：答案文字的行尾紧贴边缘不好读，和分隔线错开也更透气
        answerScroll.frame = NSRect(x: 0, y: bottomHeight + 1,
                                    width: width - 8, height: max(0, top - bottomHeight - 1))
        // documentView 的 autoresizing 不可靠：窗口变窄后它可能停在旧宽度上，
        // 于是文字被画到可视区外。这里每次布局都对齐一次。
        if let doc = answerScroll.documentView, doc.frame.width != answerScroll.contentSize.width {
            doc.setFrameSize(NSSize(width: answerScroll.contentSize.width, height: doc.frame.height))
        }
    }

    /// NSVisualEffectView 的背景层不跟随 view.layer.cornerRadius，
    /// 除了外层容器裁切，再给它一张可拉伸的圆角遮罩，双保险。
    private func updateBlurMask() {
        guard blur.maskImage == nil else { return }
        let radius = Theme.cornerRadius
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        blur.maskImage = image
    }
}
