import AppKit
import SprigCore
import KeyboardShortcuts

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// 面板是 .floating，设置窗口必须再高一层，否则从面板里点「管理模型接入…」会被面板压住，
    /// 看起来像是点不开、或者像开了两个窗口。
    private static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    // 本地：只填地址，模型清单靠同步
    private let localURLField = NSTextField(string: "")
    private let localSyncButton = PointerButton(title: "同步模型", target: nil, action: nil)
    private let localModelsLabel = NSTextField(labelWithString: "")
    // 免费：只留智谱一条 Key
    private let zhipuKeyField = NSSecureTextField(string: "")
    private let freeModelsLabel = NSTextField(labelWithString: "")
    // 自定义：用户自填，可多条
    private let customPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customNameField = NSTextField(string: "")
    private let customURLField = NSTextField(string: "")
    private let customKeyField = NSSecureTextField(string: "")
    private let customModelField = NSTextField(string: "")
    private let addButton = PointerButton(title: "＋", target: nil, action: nil)
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let fetchButton = PointerButton(title: "拉取", target: nil, action: nil)
    private let testButton = PointerButton(title: "测试连接", target: nil, action: nil)
    private let syncFreeButton = PointerButton(title: "同步模型", target: nil, action: nil)
    private let removeButton = PointerButton(title: "－", target: nil, action: nil)
    private let webSearchToggle = NSButton(checkboxWithTitle: "让模型自己联网搜索",
                                           target: nil,
                                           action: nil)
    private let thinkingToggle = NSButton(checkboxWithTitle: "关闭思考链", target: nil, action: nil)
    private let readingThemePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchBackendPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let webSearchKeyField = NSSecureTextField(string: "")
    private let proxyField = NSTextField(string: "")
    private let webSearchHelpButton = PointerButton(title: "去获取", target: nil, action: nil)
    private let agentChips = AgentChipsView(frame: .zero)
    private let agentWorkspaceLabel = NSTextField(labelWithString: "")
    private let agentRescanButton = PointerButton(title: "重新检测", target: nil, action: nil)
    private let agentTestAllButton = PointerButton(title: "测试全部", target: nil, action: nil)
    private var agentStatuses: [UUID: AcpProbeStatus] = [:]

    /// 自定义下拉里每一项对应的配置 id
    private var customIDs: [UUID] = []

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 890),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "\(AppInfo.name)设置"
        window.isReleasedWhenClosed = false
        window.level = Self.windowLevel
        // 跟面板一样只待在自己的 Space；全屏应用上也能浮出来
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        window.center()
        self.init(window: window)
        window.delegate = self
        buildContent()
    }

    // MARK: - 布局

    // MARK: - 布局参数（所有间距只从这里取，保证节奏一致）

    private enum Layout {
        static let left: CGFloat = 24
        static let right: CGFloat = 476
        static let width = right - left
        static let control: CGFloat = 24      // 输入框 / 下拉
        static let button: CGFloat = 26       // 普通按钮
        static let rowGap: CGFloat = 8        // 同一块内的行距
        static let blockGap: CGFloat = 14     // 内容 → 分隔线 / 分隔线 → 标题
        static let titleGap: CGFloat = 8      // 标题 → 第一个控件
        static let groupGap: CGFloat = 18     // 子组之间
        static let groupTitleGap: CGFloat = 6 // 子标题 → 它的那一行
        static let buttonMin: CGFloat = 76    // 按钮最小宽度
        static let iconButton: CGFloat = 32   // 只有图标的按钮（＋/－）
        static let padding: CGFloat = 12      // 按钮左右内边距（单边）
    }

    /// 所有按钮都过一遍这里：字号、圆角、内边距统一，宽度 = 文字宽 + 两侧 padding，且不低于最小值。
    @discardableResult
    private func sizeButton(_ button: PointerButton,
                            min minWidth: CGFloat = Layout.buttonMin,
                            font: CGFloat = 12) -> CGFloat {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: font)
        let text = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: font)]).width
        let width = max(minWidth, ceil(text) + Layout.padding * 2)
        button.frame = NSRect(x: button.frame.origin.x, y: button.frame.origin.y,
                              width: width, height: Layout.button)
        return width
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        // 从上往下一路排下来：y 记录当前块的下沿
        var y: CGFloat = 866

        // ── 快捷键 ──
        y -= Layout.button
        addRowLabel("唤起面板快捷键", y: y + 4, to: contentView)
        let panelRecorder = KeyboardShortcuts.RecorderCocoa(for: .togglePanel)
        panelRecorder.frame = NSRect(x: 120, y: y, width: Layout.right - 120, height: Layout.button)
        contentView.addSubview(panelRecorder)

        y -= Layout.rowGap + Layout.button
        addRowLabel("知识树快捷键", y: y + 4, to: contentView)
        let treeRecorder = KeyboardShortcuts.RecorderCocoa(for: .toggleTree)
        treeRecorder.frame = NSRect(x: 120, y: y, width: Layout.right - 120, height: Layout.button)
        contentView.addSubview(treeRecorder)

        // ── 阅读主题 ──
        y -= Layout.blockGap
        addSeparator(y: y, to: contentView)
        y -= Layout.blockGap + 18
        addSectionTitle("阅读主题", y: y, to: contentView)

        y -= Layout.titleGap + Layout.control
        readingThemePopUp.frame = NSRect(x: Layout.left, y: y, width: 200, height: Layout.control)
        readingThemePopUp.controlSize = .small
        readingThemePopUp.font = .systemFont(ofSize: 12)
        readingThemePopUp.target = self
        readingThemePopUp.action = #selector(readingThemeChanged)
        contentView.addSubview(readingThemePopUp)
        reloadReadingThemePopUp()

        let themeHint = NSTextField(labelWithString: "只影响答案区的排版和配色，已有卡片会跟着变")
        themeHint.font = .systemFont(ofSize: 11)
        themeHint.textColor = .secondaryLabelColor
        themeHint.frame = NSRect(x: 236, y: y + 4, width: Layout.right - 236, height: 16)
        contentView.addSubview(themeHint)

        // ── 模型接入 ──
        y -= Layout.blockGap
        addSeparator(y: y, to: contentView)
        y -= Layout.blockGap + 18
        addSectionTitle("模型接入", y: y, to: contentView)

        // 本地
        y -= Layout.titleGap + 16
        addGroupTitle("本地 · Ollama 跑在本机，模型靠同步拉取", y: y, to: contentView)
        y -= Layout.groupTitleGap + Layout.button
        configure(localURLField, placeholder: "Ollama 地址")
        localURLField.frame = NSRect(x: Layout.left, y: y + 1, width: 190, height: Layout.control)
        contentView.addSubview(localURLField)

        localSyncButton.target = self
        localSyncButton.action = #selector(syncLocalModels)
        localSyncButton.toolTip = "列出本机 Ollama 已 pull 的模型"
        let localSyncWidth = sizeButton(localSyncButton)
        localSyncButton.frame.origin = NSPoint(x: 218, y: y)
        contentView.addSubview(localSyncButton)

        localModelsLabel.font = .systemFont(ofSize: 11)
        localModelsLabel.textColor = .secondaryLabelColor
        localModelsLabel.lineBreakMode = .byTruncatingTail
        localModelsLabel.frame = NSRect(x: 218 + localSyncWidth + Layout.rowGap, y: y + 5,
                                        width: Layout.right - 218 - localSyncWidth - Layout.rowGap,
                                        height: 16)
        contentView.addSubview(localModelsLabel)

        // 免费
        y -= Layout.groupGap + 16
        addGroupTitle("免费 · 智谱 GLM，模型名固定为免费型号", y: y, to: contentView)
        y -= Layout.groupTitleGap + Layout.button
        let zhipuLabel = NSTextField(labelWithString: "智谱 GLM")
        zhipuLabel.font = .systemFont(ofSize: 12)
        zhipuLabel.textColor = .secondaryLabelColor
        zhipuLabel.frame = NSRect(x: Layout.left, y: y + 4, width: 64, height: 18)
        contentView.addSubview(zhipuLabel)

        zhipuKeyField.placeholderString = "智谱 API Key（免费，推荐）"
        zhipuKeyField.font = .systemFont(ofSize: 12)
        zhipuKeyField.delegate = self
        zhipuKeyField.frame = NSRect(x: 92, y: y + 1, width: 140, height: Layout.control)
        contentView.addSubview(zhipuKeyField)

        let zhipuHelp = PointerButton(title: "去获取", target: self, action: #selector(openZhipuKeyPage))
        zhipuHelp.toolTip = "bigmodel.cn 注册 + 实名认证后创建 Key；GLM-4.7-Flash 免费不限量，不用买套餐"
        let helpWidth = sizeButton(zhipuHelp)
        zhipuHelp.frame.origin = NSPoint(x: 236, y: y)
        contentView.addSubview(zhipuHelp)

        syncFreeButton.target = self
        syncFreeButton.action = #selector(syncFreeModels)
        syncFreeButton.toolTip = "确认智谱这条免费型号还在"
        let freeSyncWidth = sizeButton(syncFreeButton)
        syncFreeButton.frame.origin = NSPoint(x: 236 + helpWidth + Layout.rowGap, y: y)
        contentView.addSubview(syncFreeButton)

        freeModelsLabel.font = .systemFont(ofSize: 11)
        freeModelsLabel.textColor = .secondaryLabelColor
        freeModelsLabel.lineBreakMode = .byTruncatingTail
        freeModelsLabel.frame = NSRect(x: 236 + helpWidth + freeSyncWidth + Layout.rowGap * 2,
                                       y: y + 5, width: 60, height: 16)
        contentView.addSubview(freeModelsLabel)

        // 自定义
        y -= Layout.groupGap + 16
        addGroupTitle("自定义 · 填 Base URL 和 Key，给配置起个名", y: y, to: contentView)
        y -= Layout.groupTitleGap + Layout.button
        let iconTotal = Layout.iconButton * 2 + Layout.rowGap * 2
        customPopUp.frame = NSRect(x: Layout.left, y: y, width: Layout.width - iconTotal, height: Layout.button)
        customPopUp.target = self
        customPopUp.action = #selector(customSelectionChanged)
        contentView.addSubview(customPopUp)

        addButton.target = self
        addButton.action = #selector(addCustomProvider)
        addButton.toolTip = "新增一个自定义接入"
        sizeButton(addButton, min: Layout.iconButton, font: 13)
        addButton.frame.origin = NSPoint(x: Layout.right - iconTotal + Layout.rowGap, y: y)
        contentView.addSubview(addButton)

        removeButton.target = self
        removeButton.action = #selector(removeProvider)
        removeButton.toolTip = "删除当前自定义接入"
        sizeButton(removeButton, min: Layout.iconButton, font: 13)
        removeButton.frame.origin = NSPoint(x: Layout.right - Layout.iconButton, y: y)
        contentView.addSubview(removeButton)

        y -= Layout.rowGap + Layout.control
        configure(customNameField, placeholder: "名称，例如「公司网关」")
        customNameField.frame = NSRect(x: Layout.left, y: y, width: 76, height: Layout.control)
        contentView.addSubview(customNameField)

        configure(customURLField, placeholder: "Base URL，填到 /v1 或只填域名")
        customURLField.frame = NSRect(x: 104, y: y, width: 156, height: Layout.control)
        contentView.addSubview(customURLField)

        customKeyField.placeholderString = "API Key"
        customKeyField.font = .systemFont(ofSize: 12)
        customKeyField.delegate = self
        customKeyField.frame = NSRect(x: 264, y: y, width: 90, height: Layout.control)
        contentView.addSubview(customKeyField)

        configure(customModelField, placeholder: "模型名")
        customModelField.frame = NSRect(x: 358, y: y, width: Layout.right - 358, height: Layout.control)
        contentView.addSubview(customModelField)

        y -= Layout.rowGap + Layout.button
        testButton.target = self
        testButton.action = #selector(testConnection)
        let testWidth = sizeButton(testButton)
        testButton.frame.origin = NSPoint(x: Layout.left, y: y)
        contentView.addSubview(testButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: Layout.left + testWidth + Layout.rowGap, y: y + 5,
                                   width: Layout.right - Layout.left - testWidth - Layout.rowGap,
                                   height: 16)
        contentView.addSubview(statusLabel)

        // ── Agent ──
        y -= Layout.blockGap
        addSeparator(y: y, to: contentView)
        y -= Layout.blockGap + 18
        addSectionTitle("Agent", y: y, to: contentView)

        let rescanWidth = sizeButton(agentRescanButton)
        agentRescanButton.target = self
        agentRescanButton.action = #selector(rescanAgents)
        agentRescanButton.toolTip = "重新扫本机已装的 agent；卸载过的会从忽略名单里放出来"
        agentRescanButton.frame.origin = NSPoint(x: Layout.right - rescanWidth * 2 - Layout.rowGap,
                                                 y: y)
        contentView.addSubview(agentRescanButton)

        let testAllWidth = sizeButton(agentTestAllButton)
        agentTestAllButton.target = self
        agentTestAllButton.action = #selector(testAllAgents)
        agentTestAllButton.toolTip = "逐条握手：✓ 成功 / ! 未登录 / ✕ 失败 / ◌ 测试中"
        agentTestAllButton.frame.origin = NSPoint(x: Layout.right - testAllWidth, y: y)
        contentView.addSubview(agentTestAllButton)

        y -= Layout.groupTitleGap + 16
        let agentHint = NSTextField(labelWithString: "单击标签可设置默认模型、修改命令")
        agentHint.font = .systemFont(ofSize: 11)
        agentHint.textColor = .secondaryLabelColor
        agentHint.frame = NSRect(x: Layout.left, y: y, width: 300, height: 16)
        contentView.addSubview(agentHint)

        y -= Layout.groupTitleGap + 54
        agentChips.frame = NSRect(x: Layout.left, y: y, width: Layout.width, height: 54)
        agentChips.onAdd = { [weak self] in self?.addAgent() }
        agentChips.onEdit = { [weak self] id in self?.editAgent(id: id) }
        contentView.addSubview(agentChips)

        y -= Layout.groupTitleGap + Layout.button
        // 工作目录只展示、不手填：路径靠「选择…」改，避免手打错路径
        agentWorkspaceLabel.font = .systemFont(ofSize: 12)
        agentWorkspaceLabel.textColor = .secondaryLabelColor
        agentWorkspaceLabel.lineBreakMode = .byTruncatingMiddle
        agentWorkspaceLabel.frame = NSRect(x: Layout.left, y: y + 4, width: 372, height: 18)
        contentView.addSubview(agentWorkspaceLabel)

        let agentChoose = PointerButton(title: "选择…", target: self, action: #selector(chooseAgentWorkspace))
        sizeButton(agentChoose)
        agentChoose.frame.origin = NSPoint(x: Layout.right - agentChoose.frame.width, y: y)
        contentView.addSubview(agentChoose)

        // ── 知识库 ──
        y -= Layout.blockGap
        addSeparator(y: y, to: contentView)
        y -= Layout.blockGap + 18
        addSectionTitle("知识库", y: y, to: contentView)

        y -= Layout.titleGap + Layout.button
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: Layout.left, y: y + 4, width: 368, height: 18)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        contentView.addSubview(pathLabel)

        let chooseButton = PointerButton(title: "选择…", target: self, action: #selector(chooseFolder))
        chooseButton.toolTip = "选择知识库文件夹"
        sizeButton(chooseButton)
        chooseButton.frame.origin = NSPoint(x: Layout.right - chooseButton.frame.width, y: y)
        contentView.addSubview(chooseButton)

        // ── 联网搜索 ──
        y -= Layout.blockGap
        addSeparator(y: y, to: contentView)
        y -= Layout.blockGap + 18
        addSectionTitle("联网搜索", y: y, to: contentView)

        y -= Layout.titleGap + 20
        webSearchToggle.target = self
        webSearchToggle.action = #selector(webSearchToggled)
        webSearchToggle.font = .systemFont(ofSize: 12)
        webSearchToggle.frame = NSRect(x: 22, y: y, width: 200, height: 20)
        webSearchToggle.state = Settings.webSearchEnabled ? .on : .off
        contentView.addSubview(webSearchToggle)

        thinkingToggle.target = self
        thinkingToggle.action = #selector(thinkingToggled)
        thinkingToggle.font = .systemFont(ofSize: 12)
        thinkingToggle.frame = NSRect(x: 236, y: y, width: 200, height: 20)
        thinkingToggle.state = Settings.disableThinking ? .on : .off
        thinkingToggle.toolTip = "推理模型会先输出思考过程。知识问答用不上，关掉更快、更省 token。"
        contentView.addSubview(thinkingToggle)

        y -= Layout.rowGap + Layout.button
        searchBackendPopUp.frame = NSRect(x: Layout.left, y: y + 1, width: 110, height: Layout.control)
        searchBackendPopUp.controlSize = .small
        searchBackendPopUp.font = .systemFont(ofSize: 12)
        searchBackendPopUp.target = self
        searchBackendPopUp.action = #selector(searchBackendChanged)
        contentView.addSubview(searchBackendPopUp)
        reloadSearchBackendPopUp()

        webSearchKeyField.placeholderString = Settings.searchBackend.keyPlaceholder
        webSearchKeyField.font = .systemFont(ofSize: 12)
        webSearchKeyField.delegate = self
        webSearchKeyField.stringValue = Settings.webSearchAPIKey
        contentView.addSubview(webSearchKeyField)

        webSearchHelpButton.target = self
        webSearchHelpButton.action = #selector(openSearchKeyPage)
        webSearchHelpButton.toolTip = searchHelpTooltip()
        let searchHelpWidth = sizeButton(webSearchHelpButton)
        webSearchHelpButton.frame.origin = NSPoint(x: Layout.right - searchHelpWidth, y: y)
        contentView.addSubview(webSearchHelpButton)
        webSearchKeyField.frame = NSRect(x: 138, y: y + 1,
                                         width: Layout.right - 138 - searchHelpWidth - Layout.rowGap,
                                         height: Layout.control)

        y -= Layout.rowGap + Layout.control
        let proxyLabel = NSTextField(labelWithString: "代理")
        proxyLabel.font = .systemFont(ofSize: 12)
        proxyLabel.textColor = .secondaryLabelColor
        proxyLabel.frame = NSRect(x: Layout.left, y: y + 3, width: 40, height: 18)
        contentView.addSubview(proxyLabel)

        proxyField.placeholderString = "http://127.0.0.1:7890（留空则跟随系统）"
        proxyField.font = .systemFont(ofSize: 12)
        proxyField.delegate = self
        proxyField.stringValue = Settings.customProxy
        proxyField.toolTip = "所有模型和搜索请求都走这个代理；改了立刻生效"
        proxyField.frame = NSRect(x: 68, y: y, width: Layout.right - 68, height: Layout.control)
        contentView.addSubview(proxyField)



        y -= Layout.rowGap + 104
        let hint = NSTextField(wrappingLabelWithString:
            "API Key 只写入本机偏好设置，不会上传；联网搜索可切 Tavily（1000 次/月免费）或 DeepSeek（5 元/1000 次，中文更强）。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: Layout.left, y: max(y + 84, 10), width: Layout.width, height: 34)
        if ProcessInfo.processInfo.environment["SPRIG_LAYOUT_TRACE"] != nil {
            FileHandle.standardError.write(Data("hint y=\(Int(hint.frame.minY))\n".utf8))
        }
        contentView.addSubview(hint)

        reloadAll()
    }

    private func configure(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
    }

    private func addRowLabel(_ title: String, y: CGFloat, to contentView: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.frame = NSRect(x: 24, y: y, width: 92, height: 18)
        contentView.addSubview(label)
    }

    /// 三段式里的子标题：比 addSectionTitle 小一号、颜色浅，用来区分「本地/免费/自定义」
    private func addGroupTitle(_ title: String, y: CGFloat, to view: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 24, y: y, width: 420, height: 16)
        view.addSubview(label)
    }

    private func addSectionTitle(_ title: String, y: CGFloat, to contentView: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: 24, y: y, width: 160, height: 18)
        contentView.addSubview(label)
    }

    private func addSeparator(y: CGFloat, to contentView: NSView) {
        let line = NSView(frame: NSRect(x: 24, y: y, width: 452, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        contentView.addSubview(line)
    }

    // MARK: - 数据流转

    private var localConfig: ProviderConfig? {
        Settings.providerConfigs.first { $0.resolvedCategory == .local }
    }

    /// 免费组排序：目前只有智谱，留着顺序位以便以后加
    private var freeConfigs: [ProviderConfig] {
        Settings.providerConfigs
            .filter { $0.resolvedCategory == .free }
            .sorted { (a: ProviderConfig, b: ProviderConfig) in a.freeSortRank < b.freeSortRank }
    }

    private var zhipuConfig: ProviderConfig? {
        Settings.providerConfigs.first { $0.baseURL.lowercased().contains("bigmodel") }
    }

    private var customConfigs: [ProviderConfig] {
        Settings.providerConfigs.filter { $0.resolvedCategory == .custom }
    }

    private var editingCustom: ProviderConfig? {
        let index = customPopUp.indexOfSelectedItem
        guard index >= 0, index < customIDs.count else { return customConfigs.first }
        return Settings.providerConfigs.first { $0.id == customIDs[index] }
    }

    private func reloadAll() {
        loadLocalFields()
        loadFreeFields()
        loadCustomFields()
        refreshPath()
        Settings.syncDetectedAgents()
        reloadAgentChips()
        let agentMode = Settings.usesAgent
        webSearchToggle.isEnabled = !agentMode
        webSearchToggle.toolTip = agentMode
            ? "当前由 agent 回答，联不联网由它自己决定，这个开关不生效"
            : ""
        statusLabel.stringValue = ""
    }

    // MARK: Agent

    private func reloadAgentChips() {
        agentChips.reload(Settings.agentConfigs,
                          active: Settings.activeAgentID,
                          statuses: agentStatuses)
        let workspacePath = Settings.acpWorkspacePath
        agentWorkspaceLabel.stringValue = (workspacePath as NSString).abbreviatingWithTildeInPath
        agentWorkspaceLabel.toolTip = """
        agent 进程的当前目录：它读写文件、跑命令的相对路径都落在这里。
        纯问答不会产生文件，所以空着是正常的；想让它读某个项目，就点「选择…」指向那个项目目录。
        所有 agent 共用一个。
        \(workspacePath)
        """
        if Settings.usesAgent, !Settings.acpReady {
            Settings.usesAgent = false
        }
    }

    private enum AgentSheetResult {
        case saved(AgentConfig)
        case deleted
        case cancelled
    }

    @objc private func addAgent() {
        let blank = AgentConfig(name: "", command: "")
        guard case .saved(let config) = presentAgentSheet(title: "添加 Agent",
                                                          config: blank,
                                                          allowsDelete: false) else { return }
        Settings.upsertAgent(config)
        Settings.activeAgentID = config.id
        reloadAgentChips()
    }

    private func editAgent(id: UUID) {
        guard let existing = Settings.agentConfigs.first(where: { $0.id == id }) else { return }
        switch presentAgentSheet(title: existing.presetID == nil ? "编辑 Agent" : "Agent 设置",
                                 config: existing,
                                 allowsDelete: existing.presetID == nil) {
        case .saved(let edited):
            Settings.upsertAgent(edited)
        case .deleted:
            Settings.removeAgent(id: id)
            agentStatuses[id] = nil
        case .cancelled:
            return
        }
        reloadAgentChips()
    }

    @objc private func rescanAgents() {
        Settings.syncDetectedAgents()
        // 重新检测等于「重来一遍」，旧的测试结果不再可信
        agentStatuses.removeAll()
        reloadAgentChips()
    }

    @objc private func chooseAgentWorkspace() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "用作工作目录"
        panel.directoryURL = URL(fileURLWithPath: Settings.acpWorkspacePath, isDirectory: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.agentWorkspace = url.path
            self?.reloadAgentChips()
        }
    }

    /// 逐条握手。一次只跑一个，跑完就收进程 —— 多个 agent 进程同时挂着没必要。
    @objc private func testAllAgents() {
        let configs = Settings.agentConfigs
        guard !configs.isEmpty else { return }
        agentTestAllButton.isEnabled = false
        let path = AcpEnvironment.searchPath()
        Task { @MainActor in
            defer { self.agentTestAllButton.isEnabled = true }
            for config in configs {
                self.agentStatuses[config.id] = nil
                self.agentChips.setStatus(.running, for: config.id)
                let status = await AcpClient.shared.probeStatus(commandLine: config.command,
                                                                cwd: Settings.acpWorkspacePath,
                                                                path: path)
                await AcpClient.shared.shutdown()
                self.agentStatuses[config.id] = status
                self.agentChips.setStatus(status, for: config.id)
            }
        }
    }

    /// 一条 agent 的表单：名称 / 启动命令 / 工作目录。确定返回配置，取消返回 nil。
    private func presentAgentSheet(title: String,
                                   config: AgentConfig,
                                   allowsDelete: Bool) -> AgentSheetResult {
        guard let window else { return .cancelled }
        let width: CGFloat = 420
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 104))

        let nameField = NSTextField(string: config.name)
        let commandField = NSTextField(string: config.command)
        nameField.placeholderString = "显示名，例如 WorkBuddy"
        commandField.placeholderString = "启动命令，例如 agent acp"
        // 本机检测出来的条目只是「装了什么」的反映，名字和命令不允许改
        let isDetected = config.presetID != nil
        if isDetected {
            for field in [nameField, commandField] {
                field.isEditable = false
                field.isSelectable = true
                field.textColor = .secondaryLabelColor
            }
        }

        // 工作目录是所有 agent 共用的，配置在列表下面，不放进这个弹窗
        let rows: [(String, NSTextField, CGFloat)] = [
            ("名称", nameField, 72), ("命令", commandField, 40),
        ]
        for (label, field, y) in rows {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 12)
            caption.textColor = .secondaryLabelColor
            caption.frame = NSRect(x: 0, y: y + 4, width: 60, height: 18)
            accessory.addSubview(caption)
            field.frame = NSRect(x: 64, y: y, width: width - 64, height: 24)
            field.font = .systemFont(ofSize: 12)
            accessory.addSubview(field)
        }

        // 模型行：默认跟随 agent，也可以从它自己的清单里固定一个
        let modelCaption = NSTextField(labelWithString: "模型")
        modelCaption.font = .systemFont(ofSize: 12)
        modelCaption.textColor = .secondaryLabelColor
        modelCaption.frame = NSRect(x: 0, y: 12, width: 60, height: 18)
        accessory.addSubview(modelCaption)

        let picker = AgentModelPicker(agentID: config.id, selectedID: config.modelID)
        picker.commandProvider = { commandField.stringValue }
        picker.popUp.frame = NSRect(x: 64, y: 8, width: width - 64 - 76, height: 24)
        accessory.addSubview(picker.popUp)
        picker.reloadButton.frame = NSRect(x: width - 68, y: 8, width: 68, height: 24)
        accessory.addSubview(picker.reloadButton)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = isDetected
            ? "这条是从本机检测到的，名称和命令不可改；可以给它固定一个默认模型。"
            : "命令会原样交给系统执行，知枝只负责提问和展示回答。"
        alert.accessoryView = accessory
        alert.addButton(withTitle: "保存")
        if allowsDelete {
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
        } else {
            alert.addButton(withTitle: "取消")
        }
        defer { picker.stop() }
        let response = alert.runModal()
        if allowsDelete, response == .alertSecondButtonReturn { return .deleted }
        guard response == .alertFirstButtonReturn else { return .cancelled }

        var updated = config
        if !isDetected {
            updated.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !updated.command.isEmpty else { return .cancelled }
            if updated.name.isEmpty {
                updated.name = AcpCodec.programName(commandLine: updated.command)
            }
        }
        updated.modelID = picker.selectedID
        updated.modelLabel = picker.selectedLabel
        updated.modelMaxInput = picker.selectedMaxInput
        return .saved(updated)
    }

    // MARK: 本地

    private func loadLocalFields() {
        guard let config = localConfig else { return }
        localURLField.stringValue = config.baseURL
        let count = config.cachedModels?.count ?? 0
        localModelsLabel.stringValue = count > 0 ? "\(count) 个模型" : "点同步拉取"
    }

    private func persistLocal() {
        var configs = Settings.providerConfigs
        guard let index = configs.firstIndex(where: { $0.resolvedCategory == .local }) else { return }
        configs[index].category = .local
        configs[index].baseURL = localURLField.stringValue
        Settings.providerConfigs = configs
    }

    // MARK: 免费

    private func loadFreeFields() {
        zhipuKeyField.stringValue = zhipuConfig?.apiKey ?? ""
        let count = zhipuConfig?.cachedModels?.count ?? 0
        freeModelsLabel.stringValue = count > 0 ? "智谱 \(count) 个" : "点「同步模型」确认"
    }

    private func persistFree() {
        var configs = Settings.providerConfigs
        guard let index = configs.firstIndex(where: { $0.baseURL.lowercased().contains("bigmodel") }) else { return }
        configs[index].apiKey = zhipuKeyField.stringValue
        configs[index].category = .free
        Settings.providerConfigs = configs
    }

    @objc private func openZhipuKeyPage() {
        // 官方文档（docs.bigmodel.cn/cn/guide/develop）给的是这个路径，
        // 旧的 open.bigmodel.cn/usercenter/apikeys 在 SPA 路由里会 404
        guard let url = URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 自定义

    private func loadCustomFields() {
        let keeping = customPopUp.numberOfItems > 0 ? editingCustom?.id : nil
        let configs = customConfigs
        customIDs = configs.map(\.id)
        customPopUp.removeAllItems()
        for config in configs {
            customPopUp.addItem(withTitle: config.displayName)
        }
        if let keeping, let index = customIDs.firstIndex(of: keeping) {
            customPopUp.selectItem(at: index)
        }

        let hasAny = !configs.isEmpty
        customPopUp.isEnabled = hasAny
        removeButton.isEnabled = hasAny
        for field in [customNameField, customURLField, customKeyField, customModelField] {
            field.isEnabled = hasAny
        }

        guard let config = editingCustom else {
            customNameField.stringValue = ""
            customURLField.stringValue = ""
            customKeyField.stringValue = ""
            customModelField.stringValue = ""
            return
        }
        customNameField.stringValue = config.name
        customURLField.stringValue = config.baseURL
        customURLField.toolTip = config.baseURL
        customKeyField.stringValue = config.apiKey
        customModelField.stringValue = config.model
    }

    private func persistCustom() {
        guard let config = editingCustom else { return }
        var configs = Settings.providerConfigs
        guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        let name = customNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { configs[index].name = name }
        configs[index].category = .custom
        configs[index].baseURL = customURLField.stringValue
        configs[index].apiKey = customKeyField.stringValue
        configs[index].model = customModelField.stringValue
        Settings.providerConfigs = configs
    }

    @objc private func customSelectionChanged() {
        loadCustomFields()
        guard let config = editingCustom else { return }
        Settings.selectProvider(id: config.id)
        statusLabel.stringValue = ""
    }

    @objc private func addCustomProvider() {
        var configs = Settings.providerConfigs
        let config = ProviderConfig(name: "自定义 \(customConfigs.count + 1)",
                                    kind: .openAICompatible,
                                    baseURL: "https://api.openai.com/v1",
                                    model: "gpt-4o-mini",
                                    category: .custom)
        configs.append(config)
        Settings.providerConfigs = configs
        loadCustomFields()
        if let index = customIDs.firstIndex(of: config.id) {
            customPopUp.selectItem(at: index)
        }
        loadCustomFields()
        customNameField.becomeFirstResponder()
    }

    @objc private func removeProvider() {
        guard let config = editingCustom else { return }

        var configs = Settings.providerConfigs
        configs.removeAll { $0.id == config.id }
        Settings.providerConfigs = configs

        // 删掉的正好是当前使用的，就退回第一条能用的（本地优先，它不需要 Key）
        if Settings.activeProviderID == config.id {
            let fallback = configs.first(where: { $0.isConfigured })
                ?? configs.first(where: { $0.resolvedCategory == .local })
                ?? configs.first
            if let fallback { Settings.selectProvider(id: fallback.id) }
        }
        loadCustomFields()
    }

    // MARK: - 拉取 / 测试

    /// 打开「去哪里领 Key」的页面
    /// 本地按钮：只刷本地清单，不碰免费
    @objc private func syncLocalModels() {
        // 点按钮时输入框可能还是编辑态，先落盘再同步，否则读到的还是旧值
        persistLocal()
        localSyncButton.isEnabled = false
        localModelsLabel.stringValue = "同步中…"
        Task { @MainActor in
            let result = await Settings.syncModels(in: .local)
            localSyncButton.isEnabled = true
            guard result.total > 0 else {
                localModelsLabel.stringValue = "失败，确认 ollama 在跑"
                return
            }
            loadLocalFields()
        }
    }

    /// 免费按钮：只刷免费组，不碰本地
    @objc private func syncFreeModels() {
        persistFree()
        syncFreeButton.isEnabled = false
        freeModelsLabel.stringValue = "同步中…"
        Task { @MainActor in
            let result = await Settings.syncModels(in: .free)
            syncFreeButton.isEnabled = true
            guard result.total > 0 else {
                freeModelsLabel.stringValue = "失败，检查网络 / Key"
                return
            }
            loadFreeFields()
            freeModelsLabel.stringValue = "\(result.usable)/\(result.total) 可用"
        }
    }

    @objc private func testConnection() {
        persistCustom()
        guard let config = editingCustom else {
            statusLabel.stringValue = "没有自定义配置可测，点 ＋ 新建一条"
            return
        }

        guard config.isConfigured else {
            statusLabel.stringValue = config.kind.needsAPIKey ? "先填 API Key" : "先填模型名"
            return
        }

        testButton.isEnabled = false
        statusLabel.stringValue = "测试中…"

        let provider = config.makeProvider()
        Task { @MainActor in
            defer { testButton.isEnabled = true }
            do {
                var received = false
                for try await chunk in provider.stream(messages: [.user("回复 ok")]) {
                    if !chunk.isEmpty { received = true }
                    break
                }
                statusLabel.stringValue = received ? "✓ 连接正常" : "响应为空，检查模型名"
            } catch {
                statusLabel.stringValue = "✗ \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 知识库

    private func refreshPath() {
        let url = Settings.cardsDirectory
        pathLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        pathLabel.toolTip = """
        这是知识库所在的目录：卡片全部存在这里的隐藏文件里，每棵知识树另外导出一份 Markdown 方便阅读和搜索。
        换目录时会把现有卡片一起复制过去，原来的地方不受影响。
        \(url.path)
        """
    }

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "使用此文件夹"
        panel.directoryURL = Settings.cardsDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.cardsDirectory = url
            self?.refreshPath()
            Task { @MainActor in
                await CardStore.shared.useDirectory(url)
                PanelController.shared.storageLocationDidChange()
            }
        }
    }

    // MARK: - 编辑结束

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case webSearchKeyField:
            Settings.webSearchAPIKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case localURLField:
            persistLocal()
        case zhipuKeyField:
            persistFree()
        case proxyField:
            Settings.customProxy = field.stringValue
        case customNameField, customURLField, customKeyField, customModelField:
            persistCustom()
        default:
            break
        }
    }

    private func reloadReadingThemePopUp() {
        readingThemePopUp.removeAllItems()
        for theme in MarkdownTheme.all {
            readingThemePopUp.addItem(withTitle: theme.name)
            readingThemePopUp.lastItem?.representedObject = theme.id
            readingThemePopUp.lastItem?.toolTip = theme.note.isEmpty ? nil : theme.note
        }
        if let index = MarkdownTheme.all.firstIndex(where: { $0.id == MarkdownTheme.current.id }) {
            readingThemePopUp.selectItem(at: index)
        }
    }

    @objc private func readingThemeChanged() {
        let id = readingThemePopUp.selectedItem?.representedObject as? String ?? MarkdownTheme.fallback.id
        Settings.readingTheme = id
        // 让面板立刻按新主题重排
        NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
    }

    @objc private func webSearchToggled() {
        Settings.webSearchEnabled = webSearchToggle.state == .on
        if Settings.webSearchEnabled && Settings.webSearchAPIKey.isEmpty {
            webSearchKeyField.placeholderString = "还需填 \(Settings.searchBackend.title) Key"
        }
    }

    @objc private func thinkingToggled() {
        Settings.disableThinking = thinkingToggle.state == .on
    }

    @objc private func openSearchKeyPage() {
        guard let url = Settings.searchBackend.keyURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func searchBackendChanged() {
        guard let title = searchBackendPopUp.titleOfSelectedItem,
              let backend = SearchBackend.allCases.first(where: { $0.title == title }) else { return }
        Settings.searchBackend = backend
        // 换后端：Key 内容、占位提示、引导链接都要跟着换，否则会拿 A 家的 Key 去调 B 家
        webSearchKeyField.stringValue = Settings.webSearchAPIKey
        webSearchKeyField.placeholderString = backend.keyPlaceholder
        webSearchHelpButton.toolTip = searchHelpTooltip()
        webSearchKeyField.toolTip = backend.quotaNote
    }

    private func reloadSearchBackendPopUp() {
        searchBackendPopUp.removeAllItems()
        for backend in SearchBackend.allCases {
            searchBackendPopUp.addItem(withTitle: backend.title)
        }
        searchBackendPopUp.selectItem(withTitle: Settings.searchBackend.title)
    }

    private func searchHelpTooltip() -> String {
        let backend = Settings.searchBackend
        let host = backend.keyURL?.host ?? backend.title
        return "\(backend.quotaNote)；在 \(host) 领 Key"
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        // 每次打开都从最新状态重建，避免面板里切过模型后这里还显示旧的
        reloadAll()
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        // 面板长期处于 .floating，这里再抬一次，确保任何情况下设置都压在它上面
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// 设置关掉后把焦点还给面板，免得面板看着还在、却接不到键盘输入
    func windowWillClose(_ notification: Notification) {
        let panel = PanelController.shared.panel
        if panel.isVisible {
            panel.makeKey()
        }
    }

    /// 无界面校验：`Sprig --settings --dump` 打印表单状态后退出
    /// 把设置页画成 PNG（`rect` 为空时整页）。
    func snapshot(to url: URL, rect: NSRect? = nil) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let target = rect ?? view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: target) else { return }
        // 先铺白底：contentView 本身透明，直接画出来会是全黑
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(origin: .zero, size: target.size).fill()
        }
        view.cacheDisplay(in: target, to: rep)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("[readme] settings ->", url.lastPathComponent, rep.pixelsWide, "x", rep.pixelsHigh)
    }

    /// 只截 Agent 那一块：标题行进到工作目录行。
    func snapshotAgentSection(to url: URL) {
        guard let view = window?.contentView else { return }
        // 截图用：统一显示成「握手通过」，否则一排空心圆看着像还没配好
        for config in Settings.agentConfigs {
            agentChips.setStatus(.ok(config.displayName), for: config.id)
        }
        view.layoutSubtreeIfNeeded()
        let title = view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Agent" }
        let top = max(title?.frame.maxY ?? agentRescanButton.frame.maxY,
                      agentRescanButton.frame.maxY)
        let bottom = min(agentWorkspaceLabel.frame.minY, agentChooseButtonFrame().minY)
        let rect = NSRect(x: 8,
                          y: bottom - 12,
                          width: view.bounds.width - 16,
                          height: top - bottom + 24)
        snapshot(to: url, rect: rect)
    }

    /// 「选择…」是布局里就地建的按钮，按文案找它，拿不到就退回工作目录标签
    private func agentChooseButtonFrame() -> NSRect {
        let buttons = window?.contentView?.subviews.compactMap { $0 as? NSButton } ?? []
        return buttons.first { $0.title == "选择…" && $0.frame.minY < agentWorkspaceLabel.frame.maxY }?.frame
            ?? agentWorkspaceLabel.frame
    }

    func debugDump() {
        // 先把布局跑一遍，不然量到的都是还没排过的 frame
        window?.contentView?.layoutSubtreeIfNeeded()
        // SPRIG_SNAP=/tmp/x.png 时把窗口内容画成图片，不用屏幕录制权限也能看效果
        if let path = ProcessInfo.processInfo.environment["SPRIG_SNAP"],
           let view = window?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            // 先铺白底：contentView 本身透明，直接画出来会是全黑
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                NSColor.white.setFill()
                NSRect(origin: .zero, size: view.bounds.size).fill()
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("snapshot           =", path)
        }
        print("local.url          =", localURLField.stringValue.isEmpty ? "(空)" : localURLField.stringValue)
        print("local.modelsLabel  =", localModelsLabel.stringValue)
        print("zhipu.hasKey       =", zhipuKeyField.stringValue.isEmpty ? "否" : "是")
        print("free.modelsLabel   =", freeModelsLabel.stringValue)
        print("custom.popup.items =", customPopUp.itemTitles)
        print("custom.selected    =", customPopUp.titleOfSelectedItem ?? "nil")
        print("custom.url         =", customURLField.stringValue.isEmpty ? "(空)" : customURLField.stringValue)
        print("custom.model       =", customModelField.stringValue.isEmpty ? "(空)" : customModelField.stringValue)
        print("remove.enabled     =", removeButton.isEnabled)
        print("thinking.disabled  =", Settings.disableThinking)
        print("webSearch.enabled  =", Settings.webSearchEnabled)
        print("webSearch.toggle   =", webSearchToggle.isEnabled, "state=", webSearchToggle.state.rawValue)
        print("webSearch.backend  =", Settings.searchBackend.title)
        print("webSearch.hasKey   =", Settings.webSearchAPIKey.isEmpty ? "否" : "是")
        print("webSearch.ready    =", Settings.webSearchReady)
        print("agent.count        =", Settings.agentConfigs.count)
        print("agent.active       =", Settings.activeAgent?.displayName ?? "(无)")
        print("agent.command      =", Settings.acpCommand.isEmpty ? "(空)" : Settings.acpCommand)
        print("agent.program      =", AcpEnvironment.resolveProgram(in: Settings.acpCommand) ?? "(找不到)")
        print("agent.list         =", Settings.agentConfigs.map { "\($0.displayName)[\($0.command)]" })
        print("agent.custom       =", Settings.agentConfigs.filter { $0.presetID == nil }.count)
        print("agent.model        =", Settings.activeAgent?.modelID ?? "(跟随默认)",
              Settings.activeAgent?.modelLabel ?? "")
        print("agent.model.cache  =", Settings.activeAgent.map { Settings.cachedModels(for: $0.id).count } ?? 0)
        print("agent.thought      =", Settings.activeAgent?.thoughtLevel ?? "(跟随默认)",
              "options:", Settings.activeAgent.map {
                  Settings.cachedOptions(for: $0.id).filter { $0.isThoughtLevel }.first?.choices.count ?? 0
              } ?? 0)
        print("agent.dismissed    =", UserDefaults.standard.stringArray(forKey: "dismissedAgentPresets") ?? [])
        print("agent.status       =", agentStatuses.mapValues(\.label))
        print("themes             =", MarkdownTheme.all.count, MarkdownTheme.all.map(\.name))
        print("buttons            =", ["测试连接": testButton, "同步模型": localSyncButton,
                                          "去获取": webSearchHelpButton, "测试全部": agentTestAllButton]
                .map { "\($0.key):\(Int($0.value.frame.width))" }
                .sorted())
        print("agent.chips.frame  =", agentChips.frame)
        print("agent.chips        =", agentChips.debugChips())
        print("agent.workspace    =", agentWorkspaceLabel.stringValue, "→", Settings.acpWorkspacePath)
        print("agent.selected     =", Settings.usesAgent)
        print("status             =", statusLabel.stringValue)
        print("configs.isConfigured =", Settings.providerConfigs.map { "\($0.displayName):\($0.isConfigured)" })
        print("settings.level     =", window?.level.rawValue ?? -1)
        print("panel.level        =", PanelController.shared.panel.level.rawValue)
        print("settings.abovePanel=", (window?.level.rawValue ?? -1) > PanelController.shared.panel.level.rawValue)
    }
}

/// 编辑 agent 时的「模型」下拉 + 「读取」按钮。
///
/// 模型清单只能靠真开一个会话拿到，所以读取是显式动作；结果按 agent 缓存，
/// 下次打开弹窗直接用缓存，不必再握手。
@MainActor
private final class AgentModelPicker: NSObject {
    let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let reloadButton = PointerButton(title: "读取", target: nil, action: nil)

    /// 点「读取」时回头读命令栏的最新值（用户可能刚改过）
    var commandProvider: () -> String = { "" }

    private let agentID: UUID
    private var models: [AcpModel] = []
    private var selected: String?
    private var task: Task<Void, Never>?

    init(agentID: UUID, selectedID: String?) {
        self.agentID = agentID
        self.selected = selectedID
        super.init()

        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: 12)
        reloadButton.bezelStyle = .rounded
        reloadButton.controlSize = .small
        reloadButton.font = .systemFont(ofSize: 11)
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.toolTip = "开一个会话读一次模型清单（需要几秒）"

        populate(Settings.cachedModels(for: agentID))
    }

    /// 必须读下拉**当前**选中的那一项：`selected` 只是打开弹窗时的初始值，
    /// 用它会导致「选了别的模型、保存后又回到 agent 默认」
    var selectedID: String? {
        let index = popUp.indexOfSelectedItem
        guard index > 0, index - 1 < models.count else { return nil }
        return models[index - 1].id
    }

    var selectedLabel: String? {
        let index = popUp.indexOfSelectedItem
        guard index > 0, index - 1 < models.count else { return nil }
        return models[index - 1].name
    }

    /// 选中模型的输入窗口（token），存进配置供上下文装配使用
    var selectedMaxInput: Int? {
        let index = popUp.indexOfSelectedItem
        guard index > 0, index - 1 < models.count else { return nil }
        return models[index - 1].maxInputTokens
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func populate(_ list: [AcpModel]) {
        models = list
        popUp.removeAllItems()
        popUp.addItem(withTitle: list.isEmpty ? "跟随 agent 默认（点「读取」拉清单）" : "跟随 agent 默认")
        for model in list {
            popUp.addItem(withTitle: model.label)
            popUp.lastItem?.toolTip = model.id
        }
        if let selected, let index = list.firstIndex(where: { $0.id == selected }) {
            popUp.selectItem(at: index + 1)
        } else {
            popUp.selectItem(at: 0)
        }
    }

    @objc private func reload() {
        let command = commandProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, task == nil else { return }
        // 重新拉清单前先记住当前选择，拉完再按 id 还原
        selected = selectedID
        reloadButton.isEnabled = false
        popUp.isEnabled = false
        reloadButton.title = "读取中…"
        let cwd = Settings.acpWorkspacePath
        let path = AcpEnvironment.searchPath()
        task = Task { @MainActor [weak self] in
            // 用独立的客户端：不能把面板正在用的那个进程关掉
            let client = AcpClient()
            var failure: String?
            var list: [AcpModel] = []
            var options: [AcpConfigOption] = []
            do {
                let start = try await client.discover(commandLine: command, cwd: cwd, path: path)
                list = start.models
                options = start.options
            } catch {
                failure = error.localizedDescription
            }
            await client.shutdown()
            guard let self else { return }
            self.task = nil
            self.reloadButton.isEnabled = true
            self.popUp.isEnabled = true
            self.reloadButton.title = "读取"
            if let failure {
                self.reloadButton.toolTip = failure
                self.popUp.removeAllItems()
                self.popUp.addItem(withTitle: "读取失败：\(failure)")
                self.popUp.selectItem(at: 0)
                return
            }
            Settings.setCachedModels(list, for: self.agentID)
            Settings.setCachedOptions(options, for: self.agentID)
            self.populate(list)
        }
    }
}
