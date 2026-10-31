import AppKit
import SprigCore

@MainActor
final class PanelController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let shared = PanelController()

    /// 后台跑失败的卡：错误先存在这里，等用户切回这张卡再显示（不落盘）
    private var backgroundErrors: [UUID: String] = [:]
    /// 正在画 mermaid 的卡片，避免重复起任务
    private var diagramJobs: Set<UUID> = []

    private struct Node {
        var card: AnswerCard
        var raw: String
        var scroll: CGFloat
        /// 报错文案只用于当前面板显示：不写进 card.answer，也就不会被同步进 Markdown
        var errorText: String? = nil
    }

    private(set) var panel: QuickPanel
    private let content: PanelContentView
    private let inputView: InputTextView
    private let bottomInput: InputTextView
    private let answerView: AnswerTextView

    private var inputHeight = Theme.inputMinHeight
    private var answerHeight: CGFloat = 0
    private var questionHeight: CGFloat = 0
    private var bottomHeight: CGFloat = 0

    /// 从根卡到当前卡的路径；最后一个节点就是屏幕上正在看的这张卡
    private var stack: [Node] = []
    /// 每张卡的搜索记录，点搜索提示行时用来弹来源菜单
    private var searchResults: [UUID: [SearchReport]] = [:]
    /// 转到后台继续跑的卡片 → 已累积的原始文本。
    /// 面板一次只显示一张卡，后台那些只累积不渲染，跑完统一落库。
    private var backgroundRaw: [UUID: String] = [:]

    private var parser = TermParser()
    private var seenTerms: Set<String> = []
    private var pendingSegments: [StreamSegment] = []
    private var flushScheduled = false

    private var streamTask: Task<Void, Never>?
    private var isStreaming = false
    private var isVisible = false
    private var isTreeVisible = false
    private var isDemoted = false
    private var menuTracking = 0
    private var panelWasKeyAtMenuStart = false
    private var suppressResign = false

    private var pendingSelection = ""
    private var pendingDelete: AnswerCard?
    /// 思考强度菜单当前对应的 agent
    private var thinkingMenuAgentID: UUID?
    /// 「追问」时记住要挂到哪张卡下面
    private var pendingParentID: UUID?
    private var pendingParentSelection: String?

    private struct PermissionWait {
        var id: UUID
        var ask: AcpPermissionAsk
        var resume: (AcpPermissionOutcome) -> Void
    }

    private var permissionQueue: [PermissionWait] = []
    private var activePermission: PermissionWait?

    private var scrollObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    private override init() {
        content = PanelContentView()
        inputView = InputTextView(placeholder: "问点什么…", font: Theme.queryFont)
        bottomInput = InputTextView(placeholder: "基于这张卡继续问…", font: Theme.composerFont)
        answerView = AnswerTextView()
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.inputMinHeight))
        super.init()
        assemble()
    }

    // MARK: - 组装

    private func assemble() {
        panel.contentView = content
        panel.delegate = self
        content.inputScroll.documentView = inputView
        content.bottomScroll.documentView = bottomInput
        content.answerScroll.documentView = answerView
        bottomInput.textContainerInset = NSSize(width: 0, height: 9)

        inputView.onSubmit = { [weak self] in self?.submit() }
        inputView.onCancel = { [weak self] in self?.handleEscape() }
        inputView.onTextChange = { [weak self] in self?.inputTextChanged() }

        bottomInput.onSubmit = { [weak self] in self?.submitBottom() }
        bottomInput.onCancel = { [weak self] in self?.panel.makeFirstResponder(self?.answerView) }
        bottomInput.onTextChange = { [weak self] in self?.bottomTextChanged() }

        answerView.delegate = self

        content.breadcrumb.onSelect = { [weak self] index in self?.go(to: index) }
        content.selectionBar.onExplain = { [weak self] in self?.explainSelection() }

        content.tree.onSelect = { [weak self] card in self?.navigate(to: card) }
        content.tree.onRename = { [weak self] card, title in self?.commitRename(card, title: title) }
        content.tree.onDelete = { [weak self] card in self?.requestDelete(card) }

        content.onTreeToggle = { [weak self] in self?.toggleTree() }
        content.onSearchToggle = { [weak self] in self?.toggleWebSearch() }
        content.onThinkingTap = { [weak self] in self?.showThinkingMenu() }

        content.modelButton.target = self
        content.modelButton.action = #selector(showModelMenu)
        refreshModelButton()

        // 设置页改了接入配置 / 换了阅读主题，面板立刻重排
        NotificationCenter.default.addObserver(
            forName: .sprigProvidersDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshModelButton()
                self?.content.refreshSearchToggle()
                // 换主题时立刻重排当前答案
                if let self, !self.isStreaming, !self.stack.isEmpty {
                    self.renderCurrent()
                }
            }
        }

        // 滚动后选区矩形失效，动作条先收起，避免浮在错误位置
        content.answerScroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: content.answerScroll.contentView,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hideSelectionBar()
            }
        }

        // 菜单跟踪期间面板会 resignKey，不能据此把面板收起（右键菜单会连带消失）
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.menuTracking == 0 {
                self.panelWasKeyAtMenuStart = self.panel.isKeyWindow
            }
            self.menuTracking += 1
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.menuTracking = max(0, self.menuTracking - 1)
            if self.menuTracking == 0, self.panelWasKeyAtMenuStart {
                // 从面板里右键打开的菜单关闭后，把焦点还给面板
                self.panelWasKeyAtMenuStart = false
                self.raisePanel()
            }
        }

        applyHeights(animated: false)
        reposition()
        installKeyMonitor()
    }

    // MARK: - 显示与隐藏

    func toggle() {
        if isVisible {
            // 已显示但沉底、或停留在别的桌面：热键应该是「拉回当前桌面」而不是收起
            if isDemoted || !panel.isOnActiveSpace {
                raisePanel()
                panel.makeFirstResponder(inputView)
            } else {
                hide()
            }
        } else {
            show()
        }
    }

    func show() {
        guard !isVisible else {
            raisePanel()
            panel.makeFirstResponder(inputView)
            return
        }
        isVisible = true
        // 设置页可能改过联网开关，打开时对一次状态
        content.refreshSearchToggle()
        reposition()
        bringToActiveSpace()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()

        if !panel.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        panel.makeFirstResponder(inputView)
        suppressResign = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.suppressResign = false
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    func hideIfUnfocused() {
        guard isVisible, !suppressResign, menuTracking == 0, panel.attachedSheet == nil else { return }
        // 本 App 内部窗口（设置页）拿到焦点时不处理
        guard !NSApp.isActive else { return }
        // 需求：切到别的 App 时面板沉到底层，但不隐藏
        demotePanel()
    }

    private func demotePanel() {
        guard isVisible, !isDemoted else { return }
        isDemoted = true
        panel.level = .normal
        panel.orderBack(nil)
    }

    private func raisePanel() {
        guard isVisible else { return }
        isDemoted = false
        panel.level = .floating
        reposition()
        bringToActiveSpace()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// 热键唤起时：先把窗口迁到当前 Space，确认真的迁到了再锁回 .managed。
    /// 只靠一次定时器不可靠——accessory App 的窗口迁移可能晚一两帧。
    private func bringToActiveSpace(attempt: Int = 0) {
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        if panel.isOnActiveSpace {
            lockToManagedSpace()
            return
        }

        if attempt == 2 {
            // 兜底：激活 App，让系统把窗口一并带过来
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()

        guard attempt < 8 else {
            lockToManagedSpace()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            if self.panel.isOnActiveSpace {
                self.lockToManagedSpace()
            } else {
                self.bringToActiveSpace(attempt: attempt + 1)
            }
        }
    }

    /// 迁到目标桌面后立刻锁回 .managed：之后用户切桌面，面板不再跟随
    private func lockToManagedSpace() {
        panel.collectionBehavior = [.managed, .fullScreenAuxiliary]
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard isDemoted else { return }
        isDemoted = false
        panel.level = .floating
    }

    /// 启动时把窗口建好但不显示：第一次按热键才能 < 50ms 弹出。
    func prewarm() {
        panel.alphaValue = 0
        _ = panel.backingScaleFactor
        applyHeights(animated: false)
        reposition()
    }

    // MARK: - 布局

    private func inputTextChanged() {
        let measured = measuredInputHeight()
        guard abs(measured - inputHeight) > 0.5 else { return }
        inputHeight = measured
        applyHeights(animated: false)
    }

    private func bottomTextChanged() {
        let measured = measuredBottomHeight()
        guard abs(measured - bottomHeight) > 0.5 else { return }
        bottomHeight = measured
        applyHeights(animated: false)
    }

    /// 思考强度标签会改宽度，输入框可用宽度不能再用 Theme 里的常量
    private var inputTextWidth: CGFloat {
        let width = content.inputScroll.frame.width
        return width > 1 ? width : Theme.inputTextWidth
    }

    private func measuredInputHeight() -> CGFloat {
        measuredHeight(for: inputView,
                       width: inputTextWidth,
                       min: Theme.inputMinHeight,
                       max: Theme.inputMaxHeight)
    }

    private func measuredBottomHeight() -> CGFloat {
        measuredHeight(for: bottomInput,
                       width: Theme.panelWidth - Theme.horizontalInset * 2,
                       min: 40,
                       max: 84)
    }

    private func measuredHeight(for textView: NSTextView, width: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return minValue }
        container.containerSize = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let textHeight = layoutManager.usedRect(for: container).height
        let inset = textView.textContainerInset.height * 2
        return Swift.min(Swift.max(textHeight + inset + 4, minValue), maxValue)
    }

    private func measuredAnswerHeight() -> CGFloat {
        guard let layoutManager = answerView.layoutManager,
              let container = answerView.textContainer else { return Theme.answerMinHeight }
        layoutManager.ensureLayout(for: container)
        let textHeight = layoutManager.usedRect(for: container).height
        return min(max(textHeight + 24, Theme.answerMinHeight), Theme.answerMaxHeight)
    }

    private func measuredQuestionHeight(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let width = Theme.panelWidth - Theme.horizontalInset * 2
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Theme.questionFont]
        )
        return min(46, max(22, ceil(rect.height) + 8))
    }

    private func applyHeights(animated: Bool) {
        content.setHeights(input: inputHeight,
                           answer: answerHeight,
                           question: questionHeight,
                           bottom: answerHeight > 0 ? bottomHeight : 0)

        inputView.frame = NSRect(x: 0, y: 0,
                                 width: max(1, inputTextWidth),
                                 height: max(inputHeight, 24))
        bottomInput.frame = NSRect(x: 0, y: 0,
                                   width: max(1, Theme.panelWidth - Theme.horizontalInset * 2),
                                   height: max(bottomHeight, 24))
        // 宽高都不该在这里拍板：
        // - 宽度必须每次对齐 scrollView 的可视宽。先前用「当前宽度」会把历史上被设大的值留下来，
        //   文字就画到面板外面被树盖住（"状态管理核心"的"核"被裁就是这个）
        // - 高度由内容决定（syncHeightToContent），写死会让长答案滚不动
        let answerWidth = max(1, content.answerScroll.contentSize.width)
        answerView.frame = NSRect(x: 0, y: 0,
                                  width: answerWidth,
                                  height: max(answerView.frame.height, Theme.answerMinHeight))
        answerView.syncHeightToContent()

        let answerBlock = answerHeight > 0
            ? Theme.breadcrumbHeight + questionHeight + 1 + answerHeight + 1 + bottomHeight
            : 0
        let total = inputHeight + answerBlock
        let width = Theme.panelWidth + (isTreeVisible ? Theme.treeWidth : 0)
        let minHeight = isTreeVisible ? Theme.treeMinPanelHeight : Theme.inputMinHeight
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: width, height: max(total, minHeight))
        frame.origin.y = top - frame.size.height
        if let screen = currentScreen() {
            frame.origin.x = screen.visibleFrame.midX - width / 2
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    private func reposition() {
        let width = Theme.panelWidth + (isTreeVisible ? Theme.treeWidth : 0)
        guard let visible = currentScreen()?.visibleFrame else { return }
        let height = max(panel.frame.height, Theme.inputMinHeight)
        let x = visible.midX - width / 2
        let y = visible.maxY - height - visible.height * 0.16
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    // MARK: - 知识树

    func toggleTree() {
        setTreeVisible(!isTreeVisible)
    }

    /// 输入框右侧的联网搜索开关。
    /// 没配 Key 时直接打开设置——比让用户点一下没反应、再自己找原因强。
    func toggleWebSearch() {
        // agent 模式不接管搜索：开关状态也保持关闭的外观
        guard !Settings.usesAgent else { return }
        guard !Settings.webSearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SettingsWindowController.shared.present()
            return
        }
        Settings.webSearchEnabled.toggle()
        content.refreshSearchToggle()
    }

    /// 全局快捷键：面板没开就先打开并展开树，已开则切换显隐
    func toggleTreeShortcut() {
        guard isVisible else {
            show()
            setTreeVisible(true)
            return
        }
        // 面板沉底或在别的桌面时先拉回来，否则快捷键看起来“没反应”
        if isDemoted || !panel.isOnActiveSpace {
            raisePanel()
        }
        setTreeVisible(!isTreeVisible)
    }

    /// 知识库目录变了：当前栈里的卡可能在新库里不存在，直接回到空态并刷新树
    func storageLocationDidChange() {
        resetToEmpty()
        content.tree.reload(currentID: nil)
    }

    private func setTreeVisible(_ visible: Bool) {
        guard visible != isTreeVisible else { return }
        isTreeVisible = visible
        content.setTreeVisible(visible)
        // 宽度变化不走动画：动画期间 bounds 还是旧值，内容会先被压窄再弹回
        applyHeights(animated: false)
        if visible {
            content.tree.reload(currentID: stack.last?.card.id)
        }
    }

    private func refreshTreeIfVisible() {
        guard isTreeVisible else { return }
        content.tree.reload(currentID: stack.last?.card.id)
    }

    private func navigate(to card: AnswerCard) {
        guard stack.last?.card.id != card.id else { return }
        // 换显示而已，别把正在生成的那张卡掐掉
        detachCurrentStreaming()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let path = await CardStore.shared.path(to: card.id)
            guard !path.isEmpty else { return }
            self.stack = path.map { Node(card: $0, raw: $0.answer, scroll: 0) }
            // 这张卡可能还在后台生成：把已累积的内容先铺上，并接管后续流式
            self.adoptBackgroundIfNeeded(card.id)
            self.renderCurrent()
            self.content.tree.select(id: card.id)
            self.prepareMermaidIfNeeded(for: card)
        }
    }

    // MARK: - 模型切换

    private func showThinkingMenu() {
        guard Settings.usesAgent, let agent = Settings.activeAgent else { return }
        guard let option = Settings.cachedOptions(for: agent.id).first(where: { $0.isThoughtLevel }),
              !option.choices.isEmpty else { return }

        thinkingMenuAgentID = agent.id
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = agent.thoughtLevel

        let auto = NSMenuItem(title: "不干预（agent 默认：\(option.currentValue)）",
                              action: #selector(pickThoughtLevel(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = nil
        auto.state = current == nil ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        for choice in option.choices {
            let item = NSMenuItem(title: choice.name, action: #selector(pickThoughtLevel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.value
            item.state = current == choice.value ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: content.thinkingButton.frame.minX,
                               y: content.thinkingButton.frame.minY - 4),
                   in: content)
    }

    /// 用一两个字表示档位，跟着图标一起显示，不用点开菜单也知道当前值
    private static func shortThoughtName(_ value: String) -> String {
        switch value.lowercased() {
        case "minimal": return "极低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh", "very_high": return "很高"
        case "max": return "最高"
        case "enabled": return "开"
        case "none", "disabled": return "关"
        default: return value
        }
    }

    @objc private func pickThoughtLevel(_ sender: NSMenuItem) {
        guard let id = thinkingMenuAgentID,
              var agent = Settings.agentConfigs.first(where: { $0.id == id }) else { return }
        agent.thoughtLevel = sender.representedObject as? String
        Settings.upsertAgent(agent)
        refreshThinkingButton()
    }

    private var thoughtDiscovery: UUID?

    /// 只有 agent 暴露 thought_level/reasoning_effort 时才显示这个按钮。
    /// 缓存为空时顺手去问一次 agent（下次点开菜单就有了）。
    private func refreshThinkingButton() {
        let button = content.thinkingButton
        guard Settings.usesAgent, let agent = Settings.activeAgent else {
            button.isHidden = true
            return
        }
        if Settings.cachedOptions(for: agent.id).isEmpty, thoughtDiscovery != agent.id {
            thoughtDiscovery = agent.id
            let command = agent.command
            Task { @MainActor [weak self] in
                let client = AcpClient()
                let start = try? await client.discover(commandLine: command,
                                                       cwd: Settings.acpWorkspacePath,
                                                       path: AcpEnvironment.searchPath())
                await client.shutdown()
                if let start {
                    Settings.setCachedModels(start.models, for: agent.id)
                    Settings.setCachedOptions(start.options, for: agent.id)
                }
                self?.thoughtDiscovery = nil
                self?.refreshThinkingButton()
            }
        }
        guard let option = Settings.cachedOptions(for: agent.id).first(where: { $0.isThoughtLevel }),
              !option.choices.isEmpty else {
            button.isHidden = true
            return
        }
        button.isHidden = false
        let current = agent.thoughtLevel ?? option.currentValue
        let name = option.choices.first { $0.value == current }?.name ?? current
        button.title = agent.thoughtLevel == nil ? "" : Self.shortThoughtName(agent.thoughtLevel ?? "")
        button.toolTip = agent.thoughtLevel == nil
            ? "思考强度：跟随 agent 默认（\(name)），点击切换"
            : "思考强度：\(name)（下一问生效，点击切换）"
        button.contentTintColor = agent.thoughtLevel == nil ? .secondaryLabelColor : .controlAccentColor
        content.needsLayout = true
    }

    private func refreshModelButton() {
        // 切到 agent / 切回模型后，搜索开关的可用状态要跟着变
        defer { content.refreshSearchToggle() }
        if Settings.usesAgent, let agent = Settings.activeAgent, Settings.acpReady {
            // 选了具体模型就把模型名顶到前面：这是切换后最想知道的信息
            content.modelButton.label = agent.modelLabel.map { "ACP · \($0)" } ?? "ACP · \(agent.displayName)"
            content.modelButton.toolTip = "由 ACP agent 回答：\(agent.command)"
                + (agent.modelLabel.map { "\n模型：\($0)" } ?? "")
            refreshThinkingButton()
            return
        }
        if Settings.usesAgent {
            Settings.usesAgent = false
        }
        let config = Settings.activeConfig
        content.modelButton.label = config.modelLabel
        content.modelButton.toolTip = "\(config.displayName) · \(config.modelLabel)"
    }

    @objc private func showModelMenu() {
        // 菜单从按钮下沿展开
        makeModelMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: content.modelButton)
    }

    /// 按「本地 / 免费 / 自定义」分三组。免费类的全部模型逐个列出——
    /// 一条配置对应十几个可选模型，只在设置页里切换太绕。
    private func makeModelMenu() -> NSMenu {
        let configs = Settings.providerConfigs
        let activeID = Settings.activeProviderID
        let activeModel = Settings.activeConfig.model
        let menu = NSMenu()
        menu.autoenablesItems = false

        let agentHeader = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        agentHeader.isEnabled = false
        menu.addItem(agentHeader)
        let agents = Settings.agentConfigs
        if agents.isEmpty {
            let empty = NSMenuItem(title: "还没有 agent，去设置里加一条", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for agent in agents {
            let item = NSMenuItem(title: "ACP · \(agent.displayName)",
                                  action: #selector(pickAgent(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id.uuidString
            item.state = Settings.usesAgent && Settings.activeAgentID == agent.id ? .on : .off
            item.toolTip = agent.command
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for category in ProviderConfig.Category.allCases {
            // 没填 key / 没填模型的不进菜单：点不动，只会让列表变长
            let group = configs
                .filter { $0.resolvedCategory == category && $0.isConfigured }
                .sorted { (a: ProviderConfig, b: ProviderConfig) in a.freeSortRank < b.freeSortRank }
            guard !group.isEmpty else { continue }

            let header = NSMenuItem(title: category.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for config in group {
                for model in config.selectableModels {
                    menu.addItem(modelItem(config: config,
                                           model: model,
                                           isActive: !Settings.usesAgent
                                               && config.id == activeID
                                               && model == activeModel))
                }
            }
            menu.addItem(.separator())
        }

        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "还没有可用的模型，先去设置里填 Key", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            menu.addItem(.separator())
        }

        let manage = NSMenuItem(title: "管理模型接入…", action: #selector(openModelSettings), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        return menu
    }

    private func modelItem(config: ProviderConfig, model: String, isActive: Bool) -> NSMenuItem {
        let label = config.displayName + " · " + model
        let title = config.isConfigured ? label : label + "（未配置）"
        let item = NSMenuItem(title: title, action: #selector(pickProviderModel(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [config.id.uuidString, model]
        item.state = isActive ? .on : .off
        return item
    }

    /// 选模型 = 切换接入 + 把这条配置的 model 字段改掉。
    /// 不做「模型级配置」——否则 12 个免费模型会变成 12 条接入。
    @objc private func pickProviderModel(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let id = UUID(uuidString: pair[0]) else { return }

        var configs = Settings.providerConfigs
        if let index = configs.firstIndex(where: { $0.id == id }) {
            configs[index].model = pair[1]
            Settings.providerConfigs = configs
        }
        Settings.selectProvider(id: id)
        refreshModelButton()
    }

    @objc private func pickAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              Settings.agentConfigs.contains(where: { $0.id == id }) else { return }
        Settings.activeAgentID = id
        Settings.usesAgent = true
        refreshModelButton()
        panel.makeKey()
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        Settings.selectProvider(id: id)
        refreshModelButton()
        panel.makeKey()
    }

    @objc private func openModelSettings() {
        SettingsWindowController.shared.present()
    }

    // MARK: - 键盘

    /// LSUIElement 应用没有菜单栏，⌘C/⌘V 这类标准编辑动作没有菜单项转发就没人接。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }

            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }

            if key == "[" {
                self.goParent()
                return nil
            }
            if key == "f" {
                self.setTreeVisible(true)
                self.content.tree.focusSearch()
                return nil
            }
            // ⌘, 直接开设置。面板是浮动层，菜单栏菜单点不到，本地快捷键是唯一入口
            if key == "," {
                SettingsWindowController.shared.present()
                return nil
            }

            let selector: Selector?
            switch key {
            case "c": selector = Selector(("copy:"))
            case "v": selector = Selector(("paste:"))
            case "x": selector = Selector(("cut:"))
            case "a": selector = Selector(("selectAll:"))
            case "z": selector = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: selector = nil
            }
            guard let selector else { return event }
            return NSApp.sendAction(selector, to: nil, from: nil) ? nil : event
        }
    }

    // MARK: - 提问

    private func submit() {
        let question = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        inputView.setText("")
        inputHeight = Theme.inputMinHeight
        hideSelectionBar()

        if let parentID = pendingParentID {
            let selection = pendingParentSelection
            pendingParentID = nil
            pendingParentSelection = nil
            createChildCard(parentID: parentID,
                            selection: selection,
                            title: shortTitle(selection ?? question),
                            question: question)
        } else {
            createRootCard(question: question)
        }
    }

    /// 底部输入：一定挂在当前卡下面，带上下文
    private func submitBottom() {
        let question = bottomInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let parent = stack.last?.card else { return }
        bottomInput.setText("")
        bottomHeight = measuredBottomHeight()
        createChildCard(parentID: parent.id,
                        selection: nil,
                        title: shortTitle(question),
                        question: question)
    }

    private func createRootCard(question: String) {
        // 不取消正在进行的流式：让它继续跑完，结果直接落进那张卡。
        // 用户切回来时看到的是完整内容，而不是被截断的半截答案。
        detachCurrentStreaming()

        let card = AnswerCard(title: shortTitle(question), question: question)
        stack = [Node(card: card, raw: "", scroll: 0)]
        renderCurrent(placeholder: true)
        persistCurrentCard()

        startStreaming(messages: [
            ChatMessage.system(Prompt.answer),
            .user(question),
        ], owner: card.id)
    }

    /// 从某张卡里选中片段后生成子卡
    private func createChildCard(parentID: UUID, selection: String?, title: String, question: String) {
        guard let parentIndex = stack.firstIndex(where: { $0.card.id == parentID }) else { return }
        cancelStreaming()

        // 回退到父卡位置再挂子卡，避免在祖先链之外分叉
        stack.removeSubrange((parentIndex + 1)...)

        // 按模型真实窗口算预算；开了联网搜索就先扣掉一轮搜索的空间
        let activeConfig = Settings.activeConfig
        let policy = ContextAssembler.Policy.dynamic(
            contextTokens: contextBudgetTokens,
            isLocal: activeConfig.kind.isLocal,
            toolReserve: Settings.webSearchReady ? 3_000 : 0)
        let context = ContextAssembler.context(path: contextPath(upTo: parentIndex),
                                               policy: policy)

        let card = AnswerCard(parentID: parentID,
                              title: title,
                              question: question,
                              selectedText: selection)
        stack.append(Node(card: card, raw: "", scroll: 0))
        renderCurrent(placeholder: true)
        persistCurrentCard()

        let message = Prompt.childMessage(context: context,
                                          selection: selection,
                                          question: question.isEmpty ? nil : question)
        startStreaming(messages: [
            ChatMessage.system(Prompt.contextual),
            .user(message),
        ], owner: card.id)
    }

    /// 报错后点「重试」：用同一张卡、同样的上下文重新问一次，不新建节点。
    private func retryTurn() {
        guard !isStreaming, let node = stack.last else { return }
        let card = node.card
        let messages: [ChatMessage]
        if let parentID = card.parentID,
           let parentIndex = stack.firstIndex(where: { $0.card.id == parentID }) {
            let activeConfig = Settings.activeConfig
            let policy = ContextAssembler.Policy.dynamic(
                contextTokens: contextBudgetTokens,
                isLocal: activeConfig.kind.isLocal,
                toolReserve: Settings.webSearchReady ? 3_000 : 0)
            let context = ContextAssembler.context(path: contextPath(upTo: parentIndex), policy: policy)
            let message = Prompt.childMessage(context: context,
                                              selection: card.selectedText,
                                              question: card.question.isEmpty ? nil : card.question)
            messages = [ChatMessage.system(Prompt.contextual), .user(message)]
        } else {
            messages = [ChatMessage.system(Prompt.answer), .user(card.question)]
        }

        let index = stack.count - 1
        stack[index].raw = ""
        stack[index].errorText = nil
        backgroundErrors[card.id] = nil
        renderCurrent(placeholder: true)
        startStreaming(messages: messages, owner: card.id)
    }

    /// 上下文预算用的窗口：agent 模式按它自己报的模型窗口算，否则按接入配置。
    /// agent 没选具体模型时返回 nil，交给 Policy 用保守默认。
    private var contextBudgetTokens: Int? {
        Settings.usesAgent ? Settings.activeAgent?.modelMaxInput : Settings.activeConfig.contextLength
    }

    private func contextPath(upTo index: Int) -> [ContextAssembler.Node] {
        stack.prefix(index + 1).map { node in
            ContextAssembler.Node(
                title: node.card.title,
                question: node.card.question.isEmpty
                    ? (node.card.selectedText.map { "关于「\($0)」" } ?? node.card.title)
                    : node.card.question,
                answer: stripMarkers(node.raw)
            )
        }
    }

    private func stripMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
    }

    private func explainSelection() {
        let selection = pendingSelection
        guard let parent = stack.last?.card, !selection.isEmpty else { return }
        hideSelectionBar()
        createChildCard(parentID: parent.id,
                        selection: selection,
                        title: shortTitle(selection),
                        question: "")
    }

    // MARK: - 流式

    /// 错误文案 + 末尾的「重试」链接：首次失败和切卡回来重渲染共用
    private func applyError(_ message: String) {
        apply(.text(message))
        answerView.appendRetryLink()
    }

    private func startStreaming(messages: [ChatMessage], owner: UUID) {
        // 重试同一个节点时先把上一轮的报错清掉
        if let index = stack.firstIndex(where: { $0.card.id == owner }) {
            stack[index].errorText = nil
        }
        if Settings.usesAgent {
            startAgentStreaming(messages: messages, owner: owner)
            return
        }
        // 没填 key 就不发请求了，否则用户只能看到一条 401，比直接说清楚难懂得多
        let config = Settings.activeConfig
        guard config.isConfigured else {
            let message = "\n\n⚠️ 「\(config.displayName)」还没配好："
                + (config.kind.needsAPIKey ? "缺 API Key。" : "模型名是空的。")
                + "\n点右上角的模型按钮切一个能用的，或进「设置…」补上后重试。"
            showLocalError(message)
            return
        }

        isStreaming = true
        parser = TermParser()
        pendingSegments.removeAll()
        seenTerms.removeAll()

        let provider = Settings.provider
        // 没配搜索就传空数组，provider 走纯文本快路径，行为跟之前一致
        // 降级会换模型，所以这里记配置而不是 provider，每轮现构造
        var activeConfig = Settings.activeConfig
        // 时间工具不依赖任何配置，始终可用；搜索要配了 Key 才给
        var tools: [ToolDefinition] = [TimeTool.definition]
        if Settings.webSearchReady { tools.append(WebSearchTool.definition) }
        let searchKey = Settings.webSearchAPIKey
        let searchBackend = Settings.searchBackend
        let maxRounds = 3

        let ownerID = owner
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var conversation = messages

            do {
                // 一轮 = 一次请求 +（可能的）工具执行。模型不需要工具就提前收尾。
                for round in 0...maxRounds {
                    var requested: [ToolCall] = []
                    var fallbackTried = 0

                    // 429 是上游共享池被抢空，换个模型通常立刻可用。
                    // 只在还没吐出任何文字时换，否则会重复输出。
                    while true {
                        var produced = false
                        let provider = activeConfig.makeProvider(disableThinking: Settings.disableThinking)
                        do {
                            for try await event in provider.streamEvents(messages: conversation, tools: tools) {
                                if Task.isCancelled { return }
                                switch event {
                                case .text(let chunk):
                                    produced = true
                                    self.consume(chunk, owner: ownerID)
                                case .toolCalls(let calls):
                                    requested = calls
                                }
                            }
                            break
                        } catch let error as LLMError {
                            // TLS 抖动 / 连接中断：同一个模型重连一次就够了。
                            // 先换掉连接池——坏掉的 TLS 会话会被复用，不换池重试也白费。
                            if error.isTransient, !produced, fallbackTried < 2 {
                                HTTPClient.resetSession()
                                fallbackTried += 1
                                continue
                            }
                            // 429 是上游池被抢空；404 多半是模型下线（Gemini 换代就是这样）
                            let retryable: Bool
                            switch error {
                            case .http(429, _), .http(404, _): retryable = true
                            default: retryable = false
                            }
                            guard retryable,
                                  !produced,
                                  fallbackTried < 2,
                                  let next = self.switchToNextModel() else {
                                throw error
                            }
                            fallbackTried += 1
                            activeConfig = next
                            self.consume("\n\n（\(activeConfig.displayName) 限流，已切到 \(next.modelLabel)）\n\n", owner: ownerID)
                        }
                    }
                    if Task.isCancelled { return }

                    guard !requested.isEmpty else {
                        self.finish(owner: ownerID)
                        return
                    }
                    guard round < maxRounds else {
                        self.consume("\n\n（已连续搜索 \(maxRounds) 轮，先按现有资料回答）", owner: ownerID)
                        self.finish(owner: ownerID)
                        return
                    }

                    conversation.append(.assistantToolCalls(requested))

                    for call in requested {
                        if call.name == TimeTool.name {
                            conversation.append(.toolResult(TimeTool.execute(), for: call.id))
                            continue
                        }

                        let query: String
                        if let parsed = try? WebSearchTool.parseQuery(call.arguments) {
                            query = parsed
                        } else {
                            query = String(call.arguments.prefix(40))
                        }

                        do {
                            let report = try await WebSearchTool.execute(argumentsJSON: call.arguments,
                                                                         backend: searchBackend,
                                                                         apiKey: searchKey)
                            conversation.append(.toolResult(report.modelText, for: call.id))
                            self.showSearchResults(report, query: query, owner: ownerID)
                        } catch {
                            let reason = LLMError.wrapping(error).localizedDescription
                            conversation.append(.toolResult("搜索失败：\(reason)", for: call.id))
                            self.consume("\n\n🔍 搜索「\(query)」失败：\(reason)\n\n", owner: ownerID)
                        }
                    }
                }
                self.finish(owner: ownerID)
            } catch {
                if Task.isCancelled { return }
                self.fail(owner: ownerID, error: error)
            }
        }
    }

    /// 把这一问交给 ACP agent。只转发用户说的话；工具、推理和许可都在 agent 进程里。
    private func startAgentStreaming(messages: [ChatMessage], owner: UUID) {
        guard Settings.acpReady else {
            showLocalError("\n\n⚠️ 还没接入 ACP agent。\n点右上角的模型按钮，选「接入 ACP Agent…」，填启动命令，例如 agent acp。")
            return
        }
        guard let text = AcpCodec.forwardText(from: messages) else {
            showLocalError("\n\n⚠️ 这一轮没有要发给 agent 的问题。")
            return
        }

        isStreaming = true
        parser = TermParser()
        pendingSegments.removeAll()
        seenTerms.removeAll()

        let prompt = text + AcpCodec.termHint
        let command = Settings.acpCommand
        let cwd = Settings.acpWorkspacePath
        let path = AcpEnvironment.searchPath()
        let modelID = Settings.activeAgent?.modelID
        let ownerID = owner
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await AcpClient.shared.ask(text: prompt,
                                                    commandLine: command,
                                                    cwd: cwd,
                                                    path: path,
                                                    model: modelID,
                                                    thoughtLevel: Settings.activeAgent?.thoughtLevel,
                                                    permission: { ask in
                await PanelController.shared.requestPermission(ask)
            }, onAuthURL: { url in
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                }
            })
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    self.consume(chunk, owner: ownerID)
                }
                if Task.isCancelled { return }
                self.finish(owner: ownerID)
            } catch {
                if Task.isCancelled { return }
                self.fail(owner: ownerID, error: error)
            }
        }
    }

    private func showLocalError(_ message: String) {
        isStreaming = false
        answerView.clearThinkingPlaceholder()
        showError(message)
    }

    /// Agent 的 `session/request_permission`。选项原样摆出来，知枝不预先允许或拒绝。
    func requestPermission(_ ask: AcpPermissionAsk) async -> AcpPermissionOutcome {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                permissionQueue.append(PermissionWait(id: id, ask: ask) { outcome in
                    continuation.resume(returning: outcome)
                })
                pumpPermission()
            }
        } onCancel: {
            Task { @MainActor in
                PanelController.shared.cancelPermission(id)
            }
        }
    }

    private func pumpPermission() {
        guard activePermission == nil, !permissionQueue.isEmpty else { return }
        let next = permissionQueue.removeFirst()
        activePermission = next
        content.permissionBar.onPick = { [weak self] optionID in
            self?.resolvePermission(.selected(optionID))
        }
        content.showPermission(title: "需要许可 · \(next.ask.title)",
                               detail: next.ask.detail,
                               options: next.ask.options.map { ($0.id, $0.name) })
    }

    private func resolvePermission(_ outcome: AcpPermissionOutcome) {
        guard let current = activePermission else { return }
        activePermission = nil
        content.hidePermission()
        current.resume(outcome)
        pumpPermission()
    }

    private func cancelPermission(_ id: UUID) {
        if activePermission?.id == id {
            resolvePermission(.cancelled)
            return
        }
        guard let index = permissionQueue.firstIndex(where: { $0.id == id }) else { return }
        let waiting = permissionQueue.remove(at: index)
        waiting.resume(.cancelled)
    }

    private func dismissPermission() {
        resolvePermission(.cancelled)
    }

    /// 429 时切到下一个候选模型，并让输入框右侧的胶囊立刻反映出来。
    /// 只对「免费」这类有多个候选的接入有效；最后一个也没有了就返回 nil。
    private func switchToNextModel() -> ProviderConfig? {
        var configs = Settings.providerConfigs
        guard let index = configs.firstIndex(where: { $0.id == Settings.activeProviderID }) else { return nil }
        let models = configs[index].selectableModels
        guard models.count > 1,
              let position = models.firstIndex(of: configs[index].model),
              position + 1 < models.count else { return nil }

        configs[index].model = models[position + 1]
        Settings.providerConfigs = configs
        refreshModelButton()
        return configs[index]
    }

    /// 收到一段流式内容。`owner` 是产生它的那张卡：
    /// 正在面板上显示就走渲染，已经切走的只累积，避免把 A 的字画到 B 上。
    private func consume(_ chunk: String, owner: UUID) {
        // 已经在后台跑的任务就一直跑到底：parser 和渲染缓冲都是单例状态，
        // 中途切回前台再接管，会把已经显示过的部分重放一遍。
        if backgroundRaw[owner] != nil {
            backgroundRaw[owner, default: ""] += chunk
            return
        }
        guard stack.last?.card.id == owner else {
            backgroundRaw[owner, default: ""] += chunk
            return
        }
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].raw += chunk

        let segments = parser.consume(chunk)
        guard !segments.isEmpty else { return }
        pendingSegments.append(contentsOf: segments)
        scheduleFlush()
    }

    /// 切回一张仍在后台生成的卡：把累积内容铺到节点上，并把后续 chunk 接回前台渲染。
    ///
    /// 之前不做这一步，切回来看到的是卡片里存的旧内容（可能是空的），
    /// 要一直等到整个请求结束才由 finish(owner:) 补全。
    private func adoptBackgroundIfNeeded(_ cardID: UUID) {
        guard let buffered = backgroundRaw[cardID] else { return }
        backgroundRaw[cardID] = nil

        guard !stack.isEmpty else { return }
        stack[stack.count - 1].raw = buffered
        stack[stack.count - 1].card.answer = buffered

        // 重建流式解析状态：让 parser 把已有内容"吞掉"但不产出，
        // 后续 chunk 才会只吐出增量部分。渲染用的是另一套 replay 实例，互不干扰。
        parser = TermParser()
        _ = parser.consume(buffered)
        pendingSegments.removeAll()
        flushScheduled = false

        // 已有术语也要记进 seenTerms，否则同一术语的下划线会再出现一遍
        var scan = TermParser()
        for segment in scan.consume(buffered) + scan.flush() {
            if case .term(let term) = segment { seenTerms.insert(term) }
        }

        isStreaming = true
    }

    /// 把当前流式任务转到后台：不取消，只是不再往面板渲染。
    /// 任务跑完时会调用 finish(owner:)，把完整答案写进那张卡。
    private func detachCurrentStreaming() {
        guard isStreaming, let cardID = stack.last?.card.id else { return }
        backgroundRaw[cardID] = stack.last?.raw ?? ""
        streamTask = nil
        isStreaming = false
        answerView.clearThinkingPlaceholder()
    }

    /// 流式结束。
    ///
    /// 关键：判断「是不是前台」不能用 raw 是否为空——
    /// 后台跑的任务内容都在 backgroundRaw 里，stack 里的节点还是切走时的旧值。
    /// 之前这里直接走 finishStreaming()，它看到 stack.raw 为空就报「模型没有返回任何内容」。
    private func finish(owner: UUID) {
        let buffered = backgroundRaw[owner]
        backgroundRaw[owner] = nil

        guard stack.last?.card.id == owner else {
            let raw = buffered ?? ""
            Task { @MainActor in
                if var card = await CardStore.shared.card(id: owner) {
                    card.answer = raw
                    await CardStore.shared.upsert(card)
                }
                self.refreshTreeIfVisible()
                // 用户可能已经切回这张卡在等：把完整内容画出来
                self.reloadIfDisplaying(owner)
            }
            return
        }

        // 前台：如果这段内容是后台跑完才回到前台的，先把缓冲灌回节点再渲染
        if let buffered {
            stack[stack.count - 1].raw = buffered
            stack[stack.count - 1].card.answer = buffered
            isStreaming = false
            renderCurrent()
            persistCurrentCard()
            refreshTreeIfVisible()
            return
        }
        finishStreaming()
    }

    /// 后台任务跑完了，如果用户正停在这张卡上，把完整内容重画一遍。
    private func reloadIfDisplaying(_ cardID: UUID) {
        guard stack.last?.card.id == cardID else { return }
        Task { @MainActor in
            guard let card = await CardStore.shared.card(id: cardID) else { return }
            guard stack.last?.card.id == cardID else { return }
            stack[stack.count - 1].card = card
            stack[stack.count - 1].raw = card.answer
            renderCurrent()
            prepareMermaidIfNeeded(for: card)
        }
    }

    /// 流式失败。后台任务不弹提示到面板上，只记进卡片。
    private func fail(owner: UUID, error: Error) {
        guard stack.last?.card.id == owner else {
            // 和前台一样：报错不写进卡片，只把已经生成的部分存下来
            let raw = backgroundRaw[owner] ?? ""
            backgroundRaw[owner] = nil
            backgroundErrors[owner] = "\n\n⚠️ \(error.localizedDescription)"
            Task { @MainActor in
                if var card = await CardStore.shared.card(id: owner) {
                    card.answer = raw
                    await CardStore.shared.upsert(card)
                }
                self.refreshTreeIfVisible()
                self.reloadIfDisplaying(owner)
            }
            return
        }
        failStreaming(error)
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.flushScheduled = false
            self?.flushPendingSegments()
        }
    }

    private func flushPendingSegments() {
        guard !pendingSegments.isEmpty else { return }
        let segments = pendingSegments
        pendingSegments.removeAll()

        answerView.clearThinkingPlaceholder()
        // 流式期间也按 Markdown 重画全文：否则用户会先看到 ** 和 ```，收尾才变排版。
        // 每次 flush 是一次全量解析，答案量级（几千字）下开销可以忽略。
        if let raw = stack.last?.raw, !raw.isEmpty {
            answerView.renderRich(raw)
        } else {
            for segment in segments { apply(segment) }
        }

        // 流式过程中高度只增不减：换行时行数会 ±1，
        // 若每次都跟着回落，面板就会忽高忽低。内容只增不减，没有变矮的理由。
        // 收尾时（finishStreaming）再按实际测量值修正。
        let measured = measuredAnswerHeight()
        answerHeight = isStreaming ? max(measured, answerHeight) : measured
        applyHeights(animated: false)
        answerView.scrollToBottom()
    }

    /// 搜索结果展示成「标题 + 域名」，标题可点。纯文本同时写进 raw，重开卡片还在。
    /// 搜索默认折叠成一行摘要，点它弹出来源菜单——那些链接铺在正文里很吵。
    private func showSearchResults(_ report: SearchReport, query: String, owner: UUID) {
        searchResults[owner, default: []].append(report)
        let index = searchResults[owner]!.count - 1

        let plain = report.items.isEmpty
            ? "\n🔍 搜索「\(query)」，没有找到结果\n"
            : "\n🔍 搜索「\(query)」，参考了 \(report.items.count) 条来源\n"

        if backgroundRaw[owner] != nil {
            backgroundRaw[owner, default: ""] += plain
            return
        }
        guard stack.last?.card.id == owner, !stack.isEmpty else { return }

        stack[stack.count - 1].raw += plain

        // 记到卡片上，persistCurrentCard 会一起写盘，切卡后还能点开
        var card = stack[stack.count - 1].card
        var log = card.searchLog ?? []
        log.append(CardSearchRecord(query: query, items: report.items))
        card.searchLog = log
        stack[stack.count - 1].card = card

        if report.items.isEmpty {
            answerView.append(plain, term: nil)
        } else if let url = URL(string: "sprig-search://\(index)?card=\(owner.uuidString)") {
            answerView.appendSearchLine(plain, url: url)
        } else {
            answerView.append(plain, term: nil)
        }

        answerHeight = measuredAnswerHeight()
        applyHeights(animated: false)
        answerView.syncHeightToContent()
        answerView.scrollToBottom()
    }

    private func finishStreaming() {
        isStreaming = false
        // 流式期间用的是「只增不减」的高度，这里按实际值收一次
        answerHeight = measuredAnswerHeight()
        applyHeights(animated: false)
        let tail = parser.flush()
        if !tail.isEmpty {
            pendingSegments.append(contentsOf: tail)
            flushPendingSegments()
        }
        // 请求成功但一个字都没吐：模型名写错、额度耗尽、内容被过滤都会这样。
        // 不提示的话用户只能盯着空白面板猜。
        if let raw = stack.last?.raw,
           raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let hint = "\n\n⚠️ 模型没有返回任何内容。"
                + "常见原因：模型名写错、这个模型的额度用完了，或内容被服务端过滤。"
            apply(.text(hint))
            if !stack.isEmpty { stack[stack.count - 1].raw += hint }
            answerHeight = measuredAnswerHeight()
            applyHeights(animated: true)
            answerView.scrollToBottom()
        }
        // 流式期间是纯文本追加，收尾时按 Markdown 重画一遍
        if let raw = stack.last?.raw, !raw.isEmpty {
            renderCurrent()
        }
        dumpSnapshotIfRequested()
        persistCurrentCard()
        updateSelectionBar()
    }

    private func failStreaming(_ error: Error) {
        isStreaming = false
        answerView.clearThinkingPlaceholder()
        dismissPermission()
        let config = Settings.activeConfig
        let hint = Settings.usesAgent
            ? "当前由 Agent 回答（\(Settings.acpCommand)）。工作目录：\(Settings.acpWorkspacePath)。"
            : troubleshootingHint(for: config)
        showError("\n\n⚠️ \(error.localizedDescription)\n\(hint)")
    }

    /// SPRIG_SNAP_PANEL=/tmp/p.png 时把面板画成图片（调试排版用，不需要屏幕录制权限）
    func dumpSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SPRIG_SNAP_PANEL"] else { return }
        guard let view = panel.contentView else { return }
        writePNG(view, to: URL(fileURLWithPath: path))
        print("[panel] snapshot ->", path)
    }

    /// 把视图画成 PNG。先铺底色：面板/设置的内容视图是透明的，直接画会得到全黑。
    private func writePNG(_ view: NSView,
                          to url: URL,
                          fill: NSColor = .windowBackgroundColor,
                          rect: NSRect? = nil) {
        let target = rect ?? view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: target) else { return }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            fill.setFill()
            NSRect(origin: .zero, size: target.size).fill()
        }
        view.cacheDisplay(in: target, to: rep)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// README 截图：在一个临时空库里造一棵示例树，拍面板。
    /// 不走真实知识库，所以不会把你自己的卡片拍进去。
    func debugReadmeShots(into directory: URL) async {
        // 配图不跟着当前选的主题变，固定用默认那套
        let originalTheme = Settings.readingTheme
        Settings.readingTheme = MarkdownTheme.fallback.id
        defer { Settings.readingTheme = originalTheme }

        let library = directory.appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.removeItem(at: library)
        await CardStore.shared.useEmptyLibrary(at: library)

        let root = AnswerCard(title: "RAG",
                              question: "RAG 是什么？它解决了什么问题？",
                              answer: Self.demoAnswer)
        let hallucination = AnswerCard(parentID: root.id,
                                       title: "幻觉",
                                       question: "解释「幻觉」",
                                       answer: "指模型编造看似合理、实际并不存在的内容，"
                                           + "比如虚构的引用、数字和论文标题。",
                                       selectedText: "幻觉")
        let vector = AnswerCard(parentID: root.id,
                                title: "向量数据库",
                                question: "解释「向量数据库」",
                                answer: "把文本转成向量后存起来，按相似度检索。\n\n"
                                    + "RAG 里的「检索」通常就落在它身上：先找最相近的几段，再交给模型。",
                                selectedText: "检索")
        let grounded = AnswerCard(parentID: hallucination.id,
                                  title: "事实性",
                                  question: "怎么判断事实性？",
                                  answer: "看结论有没有出处：能指到原文段落，才算站得住。",
                                  selectedText: "编造")
        for card in [root, hallucination, vector, grounded] {
            await CardStore.shared.upsert(card)
        }

        show()
        if !isTreeVisible { setTreeVisible(true) }
        content.layoutSubtreeIfNeeded()

        stack = [Node(card: root, raw: root.answer, scroll: 0)]
        renderCurrent()
        content.tree.reload(currentID: root.id)
        prepareMermaidIfNeeded(for: root)
        content.layoutSubtreeIfNeeded()

        // 面板淡入 0.12s、树从库里读卡片、mermaid 渲染都是异步的
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        content.layoutSubtreeIfNeeded()

        if let view = panel.contentView {
            writePNG(view, to: directory.appendingPathComponent("panel.png"))
            print("[readme] panel ->", view.bounds.size, "px:", Int(view.bounds.width * 2))
        }
    }

    private static let demoAnswer = """
    RAG（⟦检索增强生成⟧）让模型先查资料再回答，而不是只靠参数里的记忆。

    它主要解决三个问题：

    - **知识过期**：资料更新，答案跟着更新，不用重训模型
    - **幻觉**：每条结论都能追到出处
    - **私有数据**：企业文档不必进训练集

    ```mermaid
    flowchart LR
        A[提问] -->|检索| B[相关片段]
        B --> C[模型生成]
        C --> D[带出处的回答]
    ```
    """



    /// 报错只留在面板上：写进卡片的话会被 CardStore 顺手同步进 Markdown。
    /// 卡片本身（问题）保留，答案留空，用户可以直接重试。
    private func showError(_ message: String) {
        applyError(message)
        if !stack.isEmpty {
            stack[stack.count - 1].errorText = message
        }
        answerHeight = measuredAnswerHeight()
        applyHeights(animated: true)
        answerView.scrollToBottom()
        refreshTreeIfVisible()
    }

    /// 报错时给一句能立刻照做的排查方向，而不是只有原始 HTTP 文本
    private func troubleshootingHint(for config: ProviderConfig) -> String {
        switch config.kind {
        case .ollama:
            return "本地模型没起来时，先在终端跑一次 `ollama serve`，并确认模型名（当前：\(config.modelLabel)）已 pull 到本地。"
        case .openAICompatible:
            return "检查 Base URL（当前：\(config.baseURL)）、API Key 和模型名（当前：\(config.modelLabel)）。"
        }
    }

    private func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        guard isStreaming else { return }
        isStreaming = false
        let tail = parser.flush()
        if !tail.isEmpty {
            pendingSegments.append(contentsOf: tail)
            flushPendingSegments()
        }
        persistCurrentCard()
    }

    /// 重渲染后 raw 里只剩纯文本，链接信息丢了。
    /// 按「🔍 搜索「」出现的顺序对上 card.searchLog，把每一行重新变成链接。
    private func attachSearchLinks(for card: AnswerCard) {
        guard let log = card.searchLog, !log.isEmpty,
              let storage = answerView.textStorage else { return }

        let text = storage.string as NSString
        var index = 0
        var location = 0
        while location < text.length, index < log.count {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            if text.substring(with: lineRange).contains("🔍 搜索「"),
               let url = URL(string: "sprig-search://\(index)?card=\(card.id.uuidString)") {
                storage.addAttributes([
                    .link: url,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .cursor: NSCursor.pointingHand,
                ], range: lineRange)
                index += 1
            }
            location = lineRange.upperBound
        }
    }

    private func apply(_ segment: StreamSegment) {
        switch segment {
        case .text(let text):
            answerView.append(text, term: nil)
        case .term(let term):
            // 同一术语只让第一次可点，避免答案里到处是同样的下划线
            if seenTerms.contains(term) {
                answerView.append(term, term: nil)
            } else {
                seenTerms.insert(term)
                answerView.append(term, term: term)
            }
        }
    }

    // MARK: - 卡片树导航

    private func renderCurrent(placeholder: Bool = false) {
        if let node = stack.last, node.errorText == nil, let error = backgroundErrors[node.card.id] {
            stack[stack.count - 1].errorText = error
            backgroundErrors[node.card.id] = nil
        }
        guard let node = stack.last else {
            answerView.reset()
            answerHeight = 0
            questionHeight = 0
            bottomHeight = 0
            content.questionHeader.configure(text: "")
            applyHeights(animated: false)
            updateBreadcrumb()
            return
        }
        answerView.reset()
        seenTerms.removeAll()

        // 有内容的正文按 Markdown 画（标题/列表/代码块/粗斜体/术语）
        answerView.renderRich(node.raw)
        if let error = node.errorText {
            applyError(error)
        }
        attachSearchLinks(for: node.card)

        if node.raw.isEmpty && placeholder {
            answerView.showThinkingPlaceholder()
            answerHeight = Theme.answerMinHeight
        } else {
            answerHeight = measuredAnswerHeight()
        }

        let questionText = displayQuestion(for: node.card)
        content.questionHeader.configure(text: questionText)
        questionHeight = measuredQuestionHeight(questionText)
        bottomHeight = max(bottomHeight, measuredBottomHeight())

        applyHeights(animated: false)
        updateBreadcrumb()
        restoreScroll(node.scroll)
    }

    private func displayQuestion(for card: AnswerCard) -> String {
        if !card.question.isEmpty { return card.question }
        if let selection = card.selectedText { return "关于「\(selection)」" }
        return card.title
    }

    private func updateBreadcrumb() {
        content.breadcrumb.configure(titles: stack.map(\.card.title))
    }

    private func go(to index: Int) {
        guard index >= 0, index < stack.count - 1 else { return }
        detachCurrentStreaming()
        stack[stack.count - 1].scroll = currentScroll()
        stack.removeSubrange((index + 1)...)
        // 回退到的那张可能还在后台生成
        if let id = stack.last?.card.id { adoptBackgroundIfNeeded(id) }
        renderCurrent()
        content.tree.select(id: stack.last?.card.id)
    }

    private func goParent() {
        guard stack.count > 1 else { return }
        go(to: stack.count - 2)
    }

    private func currentScroll() -> CGFloat {
        content.answerScroll.contentView.bounds.origin.y
    }

    private func restoreScroll(_ value: CGFloat) {
        guard answerHeight > 0 else { return }
        let maxOffset = max(0, answerView.frame.height - content.answerScroll.contentSize.height)
        let target = min(max(0, value), maxOffset)
        content.answerScroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        content.answerScroll.reflectScrolledClipView(content.answerScroll.contentView)
    }

    private func persistCurrentCard() {
        guard !stack.isEmpty else { return }
        let index = stack.count - 1
        stack[index].card.answer = stack[index].raw
        let card = stack[index].card
        Task { await CardStore.shared.upsert(card) }
        prepareHtmlAssets(for: card)
        prepareMermaidIfNeeded(for: card)
        refreshTreeIfVisible()
    }

    /// 这张卡里的 ```mermaid 图还没画出来时就后台画，画完重绘。
    /// 同一张卡同时只跑一个任务，避免切来切去重复渲染。
    private func prepareMermaidIfNeeded(for card: AnswerCard) {
        guard !diagramJobs.contains(card.id) else { return }
        let sources = MarkdownLite.parse(card.answer).compactMap { block -> String? in
            if case .mermaid(let source) = block.kind { return source }
            return nil
        }
        guard !sources.isEmpty,
              sources.contains(where: { MermaidSnapshot.cached($0) == nil }) else { return }

        diagramJobs.insert(card.id)
        Task { @MainActor [weak self] in
            var changed = false
            for source in sources where MermaidSnapshot.cached(source) == nil {
                if await MermaidSnapshot.image(for: source) != nil { changed = true }
            }
            guard let self else { return }
            self.diagramJobs.remove(card.id)
            guard changed, self.stack.last?.card.id == card.id else { return }
            self.renderCurrent()
        }
    }

    /// 答案里有 ```html 图块时，把它离屏渲染成 PNG 落到 `<知识库>/assets/`，
    /// 再重新导出一遍 Markdown——这样 `.md` 里留下的是图片而不是源码。
    private func prepareHtmlAssets(for card: AnswerCard) {
        let blocks = MarkdownLite.parse(card.answer).compactMap { block -> String? in
            if case .html(let html) = block.kind { return html }
            return nil
        }
        guard !blocks.isEmpty else { return }
        let assets = Settings.cardsDirectory.appendingPathComponent("assets", isDirectory: true)

        Task { @MainActor in
            try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            var changed = false
            for html in blocks {
                let url = assets.appendingPathComponent(HtmlAsset.name(for: html))
                if FileManager.default.fileExists(atPath: url.path) { continue }
                guard let image = await HtmlSnapshot.image(for: html),
                      let data = Self.pngData(image) else { continue }
                try? data.write(to: url)
                changed = true
            }
            guard changed else { return }
            // 图片有了，重新导出一遍 Markdown，并把面板重绘（HTML 块从源码变成图）
            if var stored = await CardStore.shared.card(id: card.id) {
                stored.answer = card.answer
                await CardStore.shared.upsert(stored)
            }
            if stack.last?.card.id == card.id { renderCurrent() }
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - 重命名 / 删除

    private func commitRename(_ card: AnswerCard, title: String) {
        Task { @MainActor in
            await CardStore.shared.rename(id: card.id, title: title)
            if let index = stack.firstIndex(where: { $0.card.id == card.id }) {
                stack[index].card.title = title
                if index == stack.count - 1 { renderCurrent() }
            }
            content.tree.reload(currentID: stack.last?.card.id)
            panel.makeKey()
        }
    }

    /// 删除确认走应用级 modal 对话框（自绘、无图标），面板同时压一层蒙层
    private func requestDelete(_ card: AnswerCard) {
        pendingDelete = card
        content.setDimmed(true)
        content.layoutSubtreeIfNeeded()

        let dialog = ConfirmDialog(title: "确定删除「\(card.title)」？",
                                   message: "这张卡及其所有子卡都会被删除，此操作无法撤销。")
        let result = dialog.runModal(relativeTo: panel)
        content.setDimmed(false)
        // modal 结束后把焦点还给面板，别让输入框处于「看着能用但没焦点」的状态
        panel.makeKey()
        if result == .confirm {
            confirmDelete()
        } else {
            cancelDelete()
        }
    }

    private func confirmDelete() {
        guard let card = pendingDelete else { return }
        pendingDelete = nil

        Task { @MainActor in
            let removed = await CardStore.shared.delete(id: card.id)
            if stack.contains(where: { removed.contains($0.card.id) }) {
                resetToEmpty()
            }
            content.tree.reload(currentID: stack.last?.card.id)
            panel.makeKey()
        }
    }

    private func cancelDelete() {
        pendingDelete = nil
        panel.makeKey()
    }

    private func resetToEmpty() {
        cancelStreaming()
        stack = []
        answerView.reset()
        answerHeight = 0
        questionHeight = 0
        bottomHeight = 0
        pendingParentID = nil
        pendingParentSelection = nil
        pendingDelete = nil
        content.questionHeader.configure(text: "")
        applyHeights(animated: true)
        updateBreadcrumb()
    }

    // MARK: - 选区

    /// 选区变化：有选中就浮出动作条，清空就收起
    func textViewDidChangeSelection(_ notification: Notification) {
        updateSelectionBar()
    }

    private func updateSelectionBar() {
        let range = answerView.selectedRange()
        guard range.length > 0 else {
            hideSelectionBar()
            return
        }
        let selection = normalize((answerView.string as NSString).substring(with: range))
        // 追问对长段落也有意义，上限放宽到 120 字
        guard !selection.isEmpty, selection.count <= 120 else {
            hideSelectionBar()
            return
        }
        guard let layoutManager = answerView.layoutManager,
              let container = answerView.textContainer else {
            hideSelectionBar()
            return
        }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        let origin = answerView.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        let inContent = answerView.convert(rect, to: content)

        guard content.answerScroll.frame.intersects(inContent) else {
            hideSelectionBar()
            return
        }

        pendingSelection = selection
        content.showSelectionBar(below: inContent)
    }

    private func hideSelectionBar() {
        pendingSelection = ""
        content.hideSelectionBar()
    }

    private func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func shortTitle(_ text: String, limit: Int = 16) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

    // MARK: - 术语点击

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let value = link as? URL {
            url = value
        } else if let value = link as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url else { return false }

        if let term = AnswerTextView.term(from: url) {
            guard let parent = stack.last?.card else { return false }
            createChildCard(parentID: parent.id,
                            selection: term,
                            title: shortTitle(term),
                            question: "")
            return true
        }

        if url.scheme == "sprig-search" {
            presentSearchSources(from: url)
            return true
        }

        if url.scheme == "sprig", url.host == "retry" {
            retryTurn()
            return true
        }

        // 搜索来源这类普通链接：交给系统用默认浏览器打开
        NSWorkspace.shared.open(url)
        return true
    }

    /// 点搜索提示行：在鼠标位置弹一个来源列表，标题可点直接开原文
    private func presentSearchSources(from url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let index = Int(url.host ?? ""),
              let cardID = components.queryItems?.first(where: { $0.name == "card" })?.value,
              let uuid = UUID(uuidString: cardID),
              let resolved = resolveSearchRecord(cardID: uuid, index: index),
              !resolved.items.isEmpty else { return }

        let report = resolved

        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in report.items {
            let title = item.host.map { "\(item.title)  ·  \($0)" } ?? item.title
            let entry = NSMenuItem(title: title,
                                   action: #selector(openSearchSource(_:)),
                                   keyEquivalent: "")
            entry.target = self
            if let link = URL(string: item.url) {
                entry.representedObject = link
                entry.toolTip = item.summary
            } else {
                // 没有有效链接就置灰，别让用户点了没反应
                entry.isEnabled = false
            }
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// 内存里有就用内存的，没有就从卡片里取。切卡后重渲染走的是后者。
    private func resolveSearchRecord(cardID: UUID, index: Int) -> CardSearchRecord? {
        if let reports = searchResults[cardID], index < reports.count {
            let report = reports[index]
            return CardSearchRecord(query: "", items: report.items)
        }
        if let log = stack.last?.card.searchLog, stack.last?.card.id == cardID,
           index < log.count {
            return log[index]
        }
        return nil
    }

    @objc private func openSearchSource(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private func handleEscape() {
        if !content.permissionBar.isHidden {
            dismissPermission()
            return
        }
        if !content.selectionBar.isHidden {
            hideSelectionBar()
        } else if isTreeVisible {
            setTreeVisible(false)
        } else if answerHeight > 0,
                  let responder = panel.firstResponder as? NSTextView,
                  responder === inputView || responder === bottomInput {
            // 第一下 Esc：只是把输入框的焦点拿掉，方便选词/复制
            panel.makeFirstResponder(answerView)
        } else {
            hide()
        }
    }

    // MARK: - 调试入口

    func debugAsk(_ question: String) {
        show()
        inputView.setText(question)
        submit()
    }

    /// 无截屏权限时用数值验证布局与交互
    func debugTreeDump(filter: String? = nil) {
        show()
        setTreeVisible(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            if let filter { self.content.tree.debugFilter(filter) }
            self.content.layoutSubtreeIfNeeded()
            print("panel.frame   =", self.panel.frame)
            print("tree.state    =", self.content.tree.debugState())
            print("tree.frame    =", self.content.tree.frame)
        }
    }

    func debugSelfTest() {
        defer { dumpSnapshotIfRequested() }
        show()

        let rootAnswer = "RAG（检索增强生成）是结合检索与生成的 AI 方法。它从外部知识库检索相关信息，再基于这些信息生成回答。它缓解了大语言模型的⟦幻觉⟧问题。"
        let root = AnswerCard(title: "RAG", question: "RAG 是什么？", answer: rootAnswer)
        let child = AnswerCard(parentID: root.id,
                               title: "幻觉",
                               question: "解释「幻觉」",
                               answer: "这里指模型编造看似合理但错误的事实，比如虚构引用。",
                               selectedText: "幻觉")
        stack = [
            Node(card: root, raw: rootAnswer, scroll: 0),
            Node(card: child, raw: child.answer, scroll: 0),
        ]
        renderCurrent()
        content.layoutSubtreeIfNeeded()

        print("panel.frame        =", panel.frame)
        print("breadcrumb.frame   =", content.breadcrumb.frame)
        print("questionHeader     =", content.questionHeader.frame, "| text:", content.questionHeader.debugText)
        print("bottomScroll.frame =", content.bottomScroll.frame)
        print("answerScroll.frame =", content.answerScroll.frame)
        print("inputScroll.frame  =", content.inputScroll.frame)
        print("thinking.frame     =", content.thinkingButton.frame,
              "hidden:", content.thinkingButton.isHidden,
              "title:", content.thinkingButton.title,
              "hint:", content.thinkingButton.toolTip ?? "")
        print("modelButton.frame  =", content.modelButton.frame)
        print("modelButton.label  =", content.modelButton.label)
        print("modelMenu.items    =", makeModelMenu().items.map(\.title))
        print("menus              =", NSApp.mainMenu?.items.compactMap {
            $0.submenu?.items.map(\.title)
        } ?? [])
        print("providers.count    =", Settings.providerConfigs.count)
        print("active.isLocal     =", Settings.provider.isLocal)
        print("stack.depth        =", stack.count)

        go(to: 0)
        content.layoutSubtreeIfNeeded()
        print("afterBack.depth    =", stack.count)
        print("root.questionText  =", content.questionHeader.debugText)

        let text = answerView.string as NSString
        let range = text.range(of: "幻觉")
        if range.location != NSNotFound {
            answerView.setSelectedRange(range)
            updateSelectionBar()
            content.layoutSubtreeIfNeeded()
            print("selectionBar.frame =", content.selectionBar.frame)
            print("selectionBar.hidden=", content.selectionBar.isHidden)

            panel.makeFirstResponder(answerView)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let handled = NSApp.sendAction(Selector(("copy:")), to: nil, from: nil)
            print("copy.handled       =", handled)
            print("pasteboard.string  =", pasteboard.string(forType: .string) ?? "nil")
        }

        setTreeVisible(true)
        content.layoutSubtreeIfNeeded()
        print("tree.visible       =", !content.tree.isHidden)
        print("treeToggle.visible =", !content.treeToggle.isHidden)
        print("panel.width        =", panel.frame.width)
        print("answerScroll.width =", content.answerScroll.frame.width)

        setTreeVisible(false)
        content.layoutSubtreeIfNeeded()
        print("treeToggle.afterCollapse =", !content.treeToggle.isHidden)
        print("panel.width.closed =", panel.frame.width)
        print("clip.cornerRadius  =", content.layer?.cornerRadius ?? -1)
        print("answerView.frame   =", answerView.frame, "| 视口:", content.answerScroll.contentSize)
        if let container = answerView.textContainer {
            print("textContainer.size =", container.size,
                  "| inset:", answerView.textContainerInset)
        }
        print("--- 模型菜单 ---")
        for item in makeModelMenu().items {
            if item.isSeparatorItem {
                print("        ----")
            } else if !item.isEnabled {
                print("        [\(item.title)]")
            } else {
                print("        \(item.state == .on ? "✓ " : "  ")\(item.title)")
            }
        }
    }
}
