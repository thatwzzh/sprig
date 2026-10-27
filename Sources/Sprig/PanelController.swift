import AppKit
import SprigCore

@MainActor
final class PanelController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let shared = PanelController()

    private struct Node {
        var card: AnswerCard
        var raw: String
        var scroll: CGFloat
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
    /// 「追问」时记住要挂到哪张卡下面
    private var pendingParentID: UUID?
    private var pendingParentSelection: String?

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
        content.selectionBar.onAsk = { [weak self] in self?.followupSelection() }

        content.tree.onSelect = { [weak self] card in self?.navigate(to: card) }
        content.tree.onClose = { [weak self] in self?.setTreeVisible(false) }
        content.tree.onRename = { [weak self] card, title in self?.commitRename(card, title: title) }
        content.tree.onDelete = { [weak self] card in self?.requestDelete(card) }

        content.onTreeToggle = { [weak self] in self?.toggleTree() }

        content.modelButton.target = self
        content.modelButton.action = #selector(showModelMenu)
        refreshModelButton()

        // 设置页改了接入配置 / 在其他地方切了模型，按钮跟着更新
        NotificationCenter.default.addObserver(
            forName: .sprigProvidersDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshModelButton() }
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

    private func measuredInputHeight() -> CGFloat {
        measuredHeight(for: inputView,
                       width: Theme.inputTextWidth,
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
                                 width: max(1, Theme.inputTextWidth),
                                 height: max(inputHeight, 24))
        bottomInput.frame = NSRect(x: 0, y: 0,
                                   width: max(1, Theme.panelWidth - Theme.horizontalInset * 2),
                                   height: max(bottomHeight, 24))
        answerView.frame = NSRect(x: 0, y: 0,
                                  width: Theme.panelWidth,
                                  height: max(answerHeight, Theme.answerMinHeight))

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
        cancelStreaming()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let path = await CardStore.shared.path(to: card.id)
            guard !path.isEmpty else { return }
            self.stack = path.map { Node(card: $0, raw: $0.answer, scroll: 0) }
            self.renderCurrent()
            self.content.tree.select(id: card.id)
        }
    }

    // MARK: - 模型切换

    private func refreshModelButton() {
        let config = Settings.activeConfig
        content.modelButton.label = config.modelLabel
        content.modelButton.toolTip = "\(config.displayName) · \(config.modelLabel)"
    }

    @objc private func showModelMenu() {
        // 菜单从按钮下沿展开
        makeModelMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: content.modelButton)
    }

    /// 所有接入排成一列，当前使用的打勾；底部入口进设置页
    private func makeModelMenu() -> NSMenu {
        let configs = Settings.providerConfigs
        let activeID = Settings.activeProviderID
        let menu = NSMenu()
        menu.autoenablesItems = false

        for config in configs {
            let title = config.isConfigured
                ? "\(config.displayName) · \(config.modelLabel)"
                : "\(config.displayName) · \(config.modelLabel)（未配置）"
            let item = NSMenuItem(title: title, action: #selector(selectProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = config.id.uuidString
            item.state = config.id == activeID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let manage = NSMenuItem(title: "管理模型接入…", action: #selector(openModelSettings), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        return menu
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
        cancelStreaming()
        let card = AnswerCard(title: shortTitle(question), question: question)
        stack = [Node(card: card, raw: "", scroll: 0)]
        renderCurrent(placeholder: true)
        persistCurrentCard()

        startStreaming(messages: [
            ChatMessage.system(Prompt.answer),
            .user(question),
        ])
    }

    /// 从某张卡里选中片段后生成子卡
    private func createChildCard(parentID: UUID, selection: String?, title: String, question: String) {
        guard let parentIndex = stack.firstIndex(where: { $0.card.id == parentID }) else { return }
        cancelStreaming()

        // 回退到父卡位置再挂子卡，避免在祖先链之外分叉
        stack.removeSubrange((parentIndex + 1)...)
        let context = ContextAssembler.context(path: contextPath(upTo: parentIndex),
                                               policy: .forLocal(Settings.provider.isLocal))

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
        ])
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

    private func followupSelection() {
        let selection = pendingSelection
        guard let parent = stack.last?.card, !selection.isEmpty else { return }
        hideSelectionBar()

        pendingParentID = parent.id
        pendingParentSelection = selection
        let quoted = selection.count > 80 ? String(selection.prefix(80)) + "…" : selection
        panel.makeFirstResponder(inputView)
        inputView.setText("关于「\(quoted)」：")
    }

    // MARK: - 流式

    private func startStreaming(messages: [ChatMessage]) {
        // 没填 key 就不发请求了，否则用户只能看到一条 401，比直接说清楚难懂得多
        let config = Settings.activeConfig
        guard config.isConfigured else {
            isStreaming = false
            answerView.clearThinkingPlaceholder()
            let message = "\n\n⚠️ 「\(config.displayName)」还没配好："
                + (config.kind.needsAPIKey ? "缺 API Key。" : "模型名是空的。")
                + "\n点右上角的模型按钮切一个能用的，或进「设置…」补上后重试。"
            apply(.text(message))
            if !stack.isEmpty { stack[stack.count - 1].raw += message }
            answerHeight = measuredAnswerHeight()
            applyHeights(animated: true)
            answerView.scrollToBottom()
            persistCurrentCard()
            return
        }

        isStreaming = true
        parser = TermParser()
        pendingSegments.removeAll()
        seenTerms.removeAll()

        let provider = Settings.provider
        // 没配搜索就传空数组，provider 走纯文本快路径，行为跟之前一致
        let tools: [ToolDefinition] = Settings.webSearchReady ? [WebSearchTool.definition] : []
        let searchKey = Settings.webSearchAPIKey
        let maxRounds = 3

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var conversation = messages

            do {
                // 一轮 = 一次请求 +（可能的）工具执行。模型不需要工具就提前收尾。
                for round in 0...maxRounds {
                    var requested: [ToolCall] = []

                    for try await event in provider.streamEvents(messages: conversation, tools: tools) {
                        if Task.isCancelled { return }
                        switch event {
                        case .text(let chunk):
                            self.consume(chunk)
                        case .toolCalls(let calls):
                            requested = calls
                        }
                    }
                    if Task.isCancelled { return }

                    guard !requested.isEmpty else {
                        self.finishStreaming()
                        return
                    }
                    guard round < maxRounds else {
                        self.consume("\n\n（已连续搜索 \(maxRounds) 轮，先按现有资料回答）")
                        self.finishStreaming()
                        return
                    }

                    conversation.append(.assistantToolCalls(requested))

                    for call in requested {
                        let query: String
                        if let parsed = try? WebSearchTool.parseQuery(call.arguments) {
                            query = parsed
                        } else {
                            query = String(call.arguments.prefix(40))
                        }
                        // 把搜索动作写进答案，用户才知道这些内容是哪来的
                        self.consume("\n\n🔍 搜索「\(query)」\n\n")

                        do {
                            let result = try await WebSearchTool.execute(argumentsJSON: call.arguments,
                                                                        apiKey: searchKey)
                            conversation.append(.toolResult(result, for: call.id))
                        } catch {
                            conversation.append(.toolResult("搜索失败：\(error.localizedDescription)",
                                                            for: call.id))
                        }
                    }
                }
                self.finishStreaming()
            } catch {
                if Task.isCancelled { return }
                self.failStreaming(error)
            }
        }
    }

    private func consume(_ chunk: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].raw += chunk

        let segments = parser.consume(chunk)
        guard !segments.isEmpty else { return }
        pendingSegments.append(contentsOf: segments)
        scheduleFlush()
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
        for segment in segments { apply(segment) }

        answerHeight = measuredAnswerHeight()
        applyHeights(animated: false)
        answerView.scrollToBottom()
    }

    private func finishStreaming() {
        isStreaming = false
        let tail = parser.flush()
        if !tail.isEmpty {
            pendingSegments.append(contentsOf: tail)
            flushPendingSegments()
        }
        persistCurrentCard()
        updateSelectionBar()
    }

    private func failStreaming(_ error: Error) {
        isStreaming = false
        answerView.clearThinkingPlaceholder()
        let config = Settings.activeConfig
        let message = "\n\n⚠️ \(error.localizedDescription)\n\(troubleshootingHint(for: config))"
        apply(.text(message))
        if !stack.isEmpty { stack[stack.count - 1].raw += message }
        answerHeight = measuredAnswerHeight()
        applyHeights(animated: true)
        answerView.scrollToBottom()
        persistCurrentCard()
    }

    /// 报错时给一句能立刻照做的排查方向，而不是只有原始 HTTP 文本
    private func troubleshootingHint(for config: ProviderConfig) -> String {
        switch config.kind {
        case .ollama:
            return "本地模型没起来时，先在终端跑一次 `ollama serve`，并确认模型名（当前：\(config.modelLabel)）已 pull 到本地。"
        case .gemini:
            return "当前接入：\(config.displayName) · \(config.modelLabel)。"
                + "若提示 429，是免费额度用完了（约 10–15 次/分钟），等一会儿再试；"
                + "若提示 400/403，多半是 API Key 无效或该模型不在免费层。"
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

        var replay = TermParser()
        for segment in replay.consume(node.raw) + replay.flush() {
            apply(segment)
        }

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
        cancelStreaming()
        stack[stack.count - 1].scroll = currentScroll()
        stack.removeSubrange((index + 1)...)
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
        refreshTreeIfVisible()
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
        guard let url, let term = AnswerTextView.term(from: url) else { return false }
        guard let parent = stack.last?.card else { return false }
        createChildCard(parentID: parent.id,
                        selection: term,
                        title: shortTitle(term),
                        question: "")
        return true
    }

    private func handleEscape() {
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
        print("modelButton.frame  =", content.modelButton.frame)
        print("modelButton.label  =", content.modelButton.label)
        print("modelMenu.items    =", makeModelMenu().items.map(\.title))
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
    }
}
