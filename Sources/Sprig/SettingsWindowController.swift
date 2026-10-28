import AppKit
import SprigCore
import KeyboardShortcuts

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// 面板是 .floating，设置窗口必须再高一层，否则从面板里点「管理模型接入…」会被面板压住，
    /// 看起来像是点不开、或者像开了两个窗口。
    private static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    // 本地：只有一条 Ollama，模型名手填
    private let localURLField = NSTextField(string: "")
    private let localModelField = NSTextField(string: "")
    // 免费：Gemini / OpenRouter，模型清单从接口拉
    private let freePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let freeKeyField = NSSecureTextField(string: "")
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
    private let keyHelpButton = PointerButton(title: "去获取", target: nil, action: nil)
    private let removeButton = PointerButton(title: "－", target: nil, action: nil)
    private let webSearchToggle = NSButton(checkboxWithTitle: "让模型自己联网搜索",
                                           target: nil,
                                           action: nil)
    private let thinkingToggle = NSButton(checkboxWithTitle: "关闭思考链", target: nil, action: nil)
    private let searchBackendPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let webSearchKeyField = NSSecureTextField(string: "")
    private let webSearchHelpButton = PointerButton(title: "去获取", target: nil, action: nil)

    /// 免费/自定义两个下拉里每一项对应的配置 id
    private var freeIDs: [UUID] = []
    private var customIDs: [UUID] = []

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 780),
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

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        // 快捷键
        addRowLabel("唤起面板快捷键", y: 740, to: contentView)
        let panelRecorder = KeyboardShortcuts.RecorderCocoa(for: .togglePanel)
        panelRecorder.frame = NSRect(x: 120, y: 734, width: 356, height: 26)
        contentView.addSubview(panelRecorder)

        addRowLabel("知识树快捷键", y: 706, to: contentView)
        let treeRecorder = KeyboardShortcuts.RecorderCocoa(for: .toggleTree)
        treeRecorder.frame = NSRect(x: 120, y: 700, width: 356, height: 26)
        contentView.addSubview(treeRecorder)

        addSeparator(y: 680, to: contentView)

        addSectionTitle("模型接入", y: 654, to: contentView)

        // ── 本地 ──
        addGroupTitle("本地 · Ollama 跑在本机，模型名手填", y: 628, to: contentView)
        configure(localURLField, placeholder: ProviderConfig.Kind.ollama.defaultBaseURL)
        localURLField.frame = NSRect(x: 120, y: 596, width: 356, height: 24)
        contentView.addSubview(localURLField)

        configure(localModelField, placeholder: ProviderConfig.Kind.ollama.defaultModel)
        localModelField.frame = NSRect(x: 120, y: 568, width: 280, height: 24)
        contentView.addSubview(localModelField)

        fetchButton.target = self
        fetchButton.action = #selector(fetchModels)
        fetchButton.bezelStyle = .rounded
        fetchButton.controlSize = .small
        fetchButton.font = .systemFont(ofSize: 12)
        fetchButton.frame = NSRect(x: 408, y: 567, width: 68, height: 26)
        fetchButton.toolTip = "列出本机 Ollama 已 pull 的模型"
        contentView.addSubview(fetchButton)

        // ── 免费 ──
        addGroupTitle("免费 · 模型清单从接口拉，可切换", y: 540, to: contentView)
        freePopUp.frame = NSRect(x: 120, y: 508, width: 180, height: 26)
        freePopUp.target = self
        freePopUp.action = #selector(freeSelectionChanged)
        contentView.addSubview(freePopUp)

        freeKeyField.font = .systemFont(ofSize: 12)
        freeKeyField.delegate = self
        freeKeyField.frame = NSRect(x: 120, y: 480, width: 280, height: 24)
        contentView.addSubview(freeKeyField)

        keyHelpButton.target = self
        keyHelpButton.action = #selector(openKeyHelp)
        keyHelpButton.bezelStyle = .rounded
        keyHelpButton.controlSize = .small
        keyHelpButton.font = .systemFont(ofSize: 12)
        keyHelpButton.frame = NSRect(x: 406, y: 479, width: 70, height: 26)
        keyHelpButton.isHidden = true
        contentView.addSubview(keyHelpButton)

        syncFreeButton.target = self
        syncFreeButton.action = #selector(syncFreeModelsTapped)
        syncFreeButton.bezelStyle = .rounded
        syncFreeButton.controlSize = .small
        syncFreeButton.font = .systemFont(ofSize: 12)
        syncFreeButton.frame = NSRect(x: 120, y: 450, width: 104, height: 26)
        syncFreeButton.toolTip = "从接口拉取当前可用的免费模型（每天自动刷新）"
        contentView.addSubview(syncFreeButton)

        freeModelsLabel.font = .systemFont(ofSize: 11)
        freeModelsLabel.textColor = .secondaryLabelColor
        freeModelsLabel.lineBreakMode = .byTruncatingTail
        freeModelsLabel.frame = NSRect(x: 232, y: 455, width: 244, height: 16)
        contentView.addSubview(freeModelsLabel)

        // ── 自定义 ──
        addGroupTitle("自定义 · 填 Base URL 和 Key，给配置起个名", y: 424, to: contentView)
        customPopUp.frame = NSRect(x: 120, y: 392, width: 200, height: 26)
        customPopUp.target = self
        customPopUp.action = #selector(customSelectionChanged)
        contentView.addSubview(customPopUp)

        addButton.target = self
        addButton.action = #selector(addCustomProvider)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.font = .systemFont(ofSize: 13)
        addButton.frame = NSRect(x: 326, y: 392, width: 32, height: 26)
        addButton.toolTip = "新增一个自定义接入"
        contentView.addSubview(addButton)

        removeButton.target = self
        removeButton.action = #selector(removeProvider)
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.font = .systemFont(ofSize: 13)
        removeButton.frame = NSRect(x: 362, y: 392, width: 32, height: 26)
        removeButton.toolTip = "删除当前自定义接入"
        contentView.addSubview(removeButton)

        configure(customNameField, placeholder: "名称，例如「公司网关」")
        customNameField.frame = NSRect(x: 120, y: 364, width: 120, height: 24)
        contentView.addSubview(customNameField)

        configure(customURLField, placeholder: "Base URL，填到 /v1 或只填域名")
        customURLField.frame = NSRect(x: 248, y: 364, width: 228, height: 24)
        contentView.addSubview(customURLField)

        customKeyField.placeholderString = "API Key"
        customKeyField.font = .systemFont(ofSize: 12)
        customKeyField.delegate = self
        customKeyField.frame = NSRect(x: 120, y: 336, width: 140, height: 24)
        contentView.addSubview(customKeyField)

        configure(customModelField, placeholder: "模型名")
        customModelField.frame = NSRect(x: 268, y: 336, width: 208, height: 24)
        contentView.addSubview(customModelField)

        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        testButton.font = .systemFont(ofSize: 12)
        testButton.frame = NSRect(x: 120, y: 306, width: 88, height: 26)
        contentView.addSubview(testButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 214, y: 311, width: 262, height: 16)
        contentView.addSubview(statusLabel)

        addSeparator(y: 280, to: contentView)

        // 知识库
        addSectionTitle("知识库", y: 256, to: contentView)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: 24, y: 230, width: 330, height: 18)
        pathLabel.toolTip = "卡片存放在这个目录的 \(CardStore.fileName) 里，换目录时会把现有卡片复制过去"
        contentView.addSubview(pathLabel)

        let chooseButton = PointerButton(title: "选择…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        chooseButton.font = .systemFont(ofSize: 12)
        chooseButton.frame = NSRect(x: 396, y: 225, width: 80, height: 26)
        chooseButton.toolTip = "选择知识库文件夹"
        contentView.addSubview(chooseButton)

        addSeparator(y: 206, to: contentView)

        // 联网搜索
        addSectionTitle("联网搜索", y: 182, to: contentView)

        webSearchToggle.target = self
        webSearchToggle.action = #selector(webSearchToggled)
        webSearchToggle.font = .systemFont(ofSize: 12)
        webSearchToggle.frame = NSRect(x: 22, y: 154, width: 200, height: 20)
        webSearchToggle.state = Settings.webSearchEnabled ? .on : .off
        contentView.addSubview(webSearchToggle)

        thinkingToggle.target = self
        thinkingToggle.action = #selector(thinkingToggled)
        thinkingToggle.font = .systemFont(ofSize: 12)
        thinkingToggle.frame = NSRect(x: 236, y: 154, width: 120, height: 20)
        thinkingToggle.state = Settings.disableThinking ? .on : .off
        thinkingToggle.toolTip = "推理模型会先输出思考过程。知识问答用不上，关掉更快、更省 token。"
        contentView.addSubview(thinkingToggle)

        searchBackendPopUp.frame = NSRect(x: 24, y: 126, width: 110, height: 24)
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
        webSearchKeyField.frame = NSRect(x: 140, y: 126, width: 260, height: 24)
        contentView.addSubview(webSearchKeyField)

        webSearchHelpButton.target = self
        webSearchHelpButton.action = #selector(openSearchKeyPage)
        webSearchHelpButton.bezelStyle = .rounded
        webSearchHelpButton.controlSize = .small
        webSearchHelpButton.font = .systemFont(ofSize: 12)
        webSearchHelpButton.frame = NSRect(x: 406, y: 125, width: 70, height: 26)
        webSearchHelpButton.toolTip = searchHelpTooltip()
        contentView.addSubview(webSearchHelpButton)

        let hint = NSTextField(wrappingLabelWithString:
            "API Key 只写入本机偏好设置，不会上传；需要 Key 的接入右侧都有「去获取」。\n"
            + "「OpenAI 兼容」适用于 OpenAI / DeepSeek / Groq / 智谱 / 火山 / 百炼 等，"
            + "Base URL 填到 /v1 或只填域名都行。\n"
            + "免费模型从接口拉取、每天自动更新，面板右侧可逐个切换。\n"
            + "联网搜索可切 Tavily（1000 次/月免费）或 DeepSeek（5 元/1000 次，中文更强）。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 12, width: 452, height: 108)
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

    private var freeConfigs: [ProviderConfig] {
        Settings.providerConfigs.filter { $0.resolvedCategory == .free }
    }

    private var customConfigs: [ProviderConfig] {
        Settings.providerConfigs.filter { $0.resolvedCategory == .custom }
    }

    private var editingFree: ProviderConfig? {
        let index = freePopUp.indexOfSelectedItem
        guard index >= 0, index < freeIDs.count else { return freeConfigs.first }
        return Settings.providerConfigs.first { $0.id == freeIDs[index] }
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
        statusLabel.stringValue = ""
    }

    // MARK: 本地

    private func loadLocalFields() {
        guard let config = localConfig else { return }
        localURLField.stringValue = config.baseURL
        localModelField.stringValue = config.model
    }

    private func persistLocal() {
        var configs = Settings.providerConfigs
        guard let index = configs.firstIndex(where: { $0.resolvedCategory == .local }) else { return }
        configs[index].category = .local
        configs[index].baseURL = localURLField.stringValue
        configs[index].model = localModelField.stringValue
        Settings.providerConfigs = configs
    }

    // MARK: 免费

    private func loadFreeFields() {
        // popup 还没填充时 editingFree 会回退到第一条，会把"有清单的那条"顶掉
        let keeping = freePopUp.numberOfItems > 0 ? editingFree?.id : nil
        let configs = freeConfigs
        freeIDs = configs.map(\.id)
        freePopUp.removeAllItems()
        for config in configs {
            let title = config.isConfigured
                ? config.displayName
                : config.displayName + "（未配置）"
            freePopUp.addItem(withTitle: title)
        }
        if let keeping, let index = freeIDs.firstIndex(of: keeping) {
            freePopUp.selectItem(at: index)
        } else if let equipped = configs.firstIndex(where: { !($0.cachedModels?.isEmpty ?? true) }) {
            // 默认落在有清单的那条，否则用户看到的是"还没拉过"
            freePopUp.selectItem(at: equipped)
        }
        freePopUp.isEnabled = configs.count > 1

        guard let config = editingFree else {
            freeKeyField.stringValue = ""
            freeModelsLabel.stringValue = "没有免费接入"
            keyHelpButton.isHidden = true
            return
        }
        freeKeyField.stringValue = config.apiKey
        freeKeyField.placeholderString = config.keyHelp != nil
            ? "粘贴 API Key，没有就点右边的「去获取」"
            : "粘贴 API Key"
        keyHelpButton.isHidden = config.keyHelp == nil
        keyHelpButton.toolTip = config.keyHelp?.text

        let count = config.cachedModels?.count ?? 0
        if count > 0 {
            freeModelsLabel.stringValue = "\(count) 个模型 · 当前 \(config.modelLabel)"
        } else {
            freeModelsLabel.stringValue = "点「同步模型」拉取免费模型"
        }
    }

    private func persistFree() {
        guard let config = editingFree else { return }
        var configs = Settings.providerConfigs
        guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        configs[index].category = .free
        configs[index].apiKey = freeKeyField.stringValue
        Settings.providerConfigs = configs
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

    @objc private func freeSelectionChanged() {
        guard let config = editingFree else { return }
        Settings.selectProvider(id: config.id)
        loadFreeFields()
        statusLabel.stringValue = ""
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
        statusLabel.stringValue = "已删除「\(config.displayName)」"
    }

    // MARK: - 拉取 / 测试

    /// 「拉取」只服务于本地区域——列出本机 Ollama 已 pull 的模型。
    /// 免费类的清单靠「同步模型」自动维护，自定义类的模型名用户自己填。
    @objc private func fetchModels() {
        persistLocal()
        guard let config = localConfig else { return }

        statusLabel.stringValue = "读取本机模型…"
        fetchButton.isEnabled = false

        Task { @MainActor in
            let base = URL(string: config.baseURL) ?? URL(string: ProviderConfig.Kind.ollama.defaultBaseURL)!
            let models = await OllamaProvider.availableModels(baseURL: base)
            fetchButton.isEnabled = true

            guard !models.isEmpty else {
                statusLabel.stringValue = "没读到模型，确认 ollama serve 在跑"
                return
            }
            statusLabel.stringValue = "\(models.count) 个本地模型"
            presentModelMenu(models)
        }
    }

    private func presentModelMenu(_ models: [String]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for name in models.prefix(40) {
            let item = NSMenuItem(title: name, action: #selector(pickModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: fetchButton.bounds.height), in: fetchButton)
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        localModelField.stringValue = name
        persistLocal()
        statusLabel.stringValue = "已选 \(name)"
    }

    /// 打开「去哪里领 Key」的页面
    @objc private func openKeyHelp() {
        guard let help = editingFree?.keyHelp else { return }
        NSWorkspace.shared.open(help.url)
    }

    @objc private func syncFreeModelsTapped() {
        syncFreeButton.isEnabled = false
        statusLabel.stringValue = "同步中…"

        Task { @MainActor in
            let ok = await Settings.syncFreeModels()
            syncFreeButton.isEnabled = true

            guard ok else {
                statusLabel.stringValue = "拉取失败，检查网络"
                return
            }
            // 同步可能改了当前模型名，整块重载一次
            loadFreeFields()
            // 清单里混着下架、无权限、限流的模型，拉完立刻探一遍，
            // 否则用户第一次提问才会发现某个模型用不了
            await probeFreeModels()
        }
    }

    /// 这个按钮在「自定义」区域里，测的就是当前编辑的那条自定义配置。
    /// 之前测的是 Settings.activeConfig（当前正在用的接入），和按钮位置对不上——
    /// 用户改了半天自定义配置，点测试却在测免费模型。
    /// 逐个探活拉回来的免费模型
    private func probeFreeModels() async {
        guard let config = editingFree,
              let models = config.cachedModels, !models.isEmpty else { return }

        statusLabel.stringValue = "测试 \(models.count) 个模型…"
        let results = await ModelProbe.probe(models: models, config: config)

        let usable = results.filter(\.ok).count
        let quota = results.filter(\.isQuotaIssue).count
        let broken = results.count - usable - quota

        var summary = "\(models.count) 个模型：\(usable) 可用"
        if broken > 0 { summary += "、\(broken) 不通" }
        if quota > 0 { summary += "、\(quota) 限流" }
        statusLabel.stringValue = summary

        for result in results where !result.ok {
            print("[probe] \(result.model) → \(result.summary)")
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
        pathLabel.toolTip = url.path
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
        case localURLField, localModelField:
            persistLocal()
        case freeKeyField:
            persistFree()
        case customNameField, customURLField, customKeyField, customModelField:
            persistCustom()
        default:
            break
        }
    }

    @objc private func webSearchToggled() {
        Settings.webSearchEnabled = webSearchToggle.state == .on
        if Settings.webSearchEnabled && Settings.webSearchAPIKey.isEmpty {
            statusLabel.stringValue = "还需填 \(Settings.searchBackend.title) Key"
        } else {
            statusLabel.stringValue = ""
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
        statusLabel.stringValue = backend.quotaNote
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
        // 没做过别的操作时，这里显示免费模型的同步情况
        statusLabel.stringValue = Settings.freeModelsLastSync == nil
            ? ""
            : "免费模型 \(Settings.freeModelsCount) 个"
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
    func debugDump() {
        print("local.url          =", localURLField.stringValue.isEmpty ? "(空)" : localURLField.stringValue)
        print("local.model        =", localModelField.stringValue.isEmpty ? "(空)" : localModelField.stringValue)
        print("free.popup.items   =", freePopUp.itemTitles)
        print("free.popup.selected=", freePopUp.titleOfSelectedItem ?? "nil")
        print("free.hasKey        =", freeKeyField.stringValue.isEmpty ? "否" : "是")
        print("free.modelsLabel   =", freeModelsLabel.stringValue)
        print("keyHelp.button     =", keyHelpButton.isHidden ? "隐藏" : "显示")
        print("custom.popup.items =", customPopUp.itemTitles)
        print("custom.selected    =", customPopUp.titleOfSelectedItem ?? "nil")
        print("custom.url         =", customURLField.stringValue.isEmpty ? "(空)" : customURLField.stringValue)
        print("custom.model       =", customModelField.stringValue.isEmpty ? "(空)" : customModelField.stringValue)
        print("remove.enabled     =", removeButton.isEnabled)
        print("thinking.disabled  =", Settings.disableThinking)
        print("webSearch.enabled  =", Settings.webSearchEnabled)
        print("webSearch.backend  =", Settings.searchBackend.title)
        print("webSearch.hasKey   =", Settings.webSearchAPIKey.isEmpty ? "否" : "是")
        print("webSearch.ready    =", Settings.webSearchReady)
        print("status             =", statusLabel.stringValue)
        print("configs.isConfigured =", Settings.providerConfigs.map { "\($0.displayName):\($0.isConfigured)" })
        print("settings.level     =", window?.level.rawValue ?? -1)
        print("panel.level        =", PanelController.shared.panel.level.rawValue)
        print("settings.abovePanel=", (window?.level.rawValue ?? -1) > PanelController.shared.panel.level.rawValue)
    }
}
