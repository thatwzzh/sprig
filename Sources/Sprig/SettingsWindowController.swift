import AppKit
import SprigCore
import KeyboardShortcuts

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// 面板是 .floating，设置窗口必须再高一层，否则从面板里点「管理模型接入…」会被面板压住，
    /// 看起来像是点不开、或者像开了两个窗口。
    private static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    private let providerPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(string: "")
    private let kindPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseURLField = NSTextField(string: "")
    private let apiKeyField = NSSecureTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let fetchButton = PointerButton(title: "拉取", target: nil, action: nil)
    private let testButton = PointerButton(title: "测试连接", target: nil, action: nil)
    private let syncFreeButton = PointerButton(title: "同步免费", target: nil, action: nil)
    private let keyHelpButton = PointerButton(title: "去获取", target: nil, action: nil)
    private let removeButton = PointerButton(title: "－", target: nil, action: nil)
    private let webSearchToggle = NSButton(checkboxWithTitle: "让模型自己联网搜索（Tavily）",
                                           target: nil,
                                           action: nil)
    private let webSearchKeyField = NSSecureTextField(string: "")
    private let webSearchHelpButton = PointerButton(title: "去获取", target: nil, action: nil)

    /// providerPopUp 里每一项对应的配置 id，顺序与 Settings.providerConfigs 一致
    private var popupIDs: [UUID] = []

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
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
        addRowLabel("唤起面板快捷键", y: 600, to: contentView)
        let panelRecorder = KeyboardShortcuts.RecorderCocoa(for: .togglePanel)
        panelRecorder.frame = NSRect(x: 120, y: 594, width: 356, height: 26)
        contentView.addSubview(panelRecorder)

        addRowLabel("知识树快捷键", y: 566, to: contentView)
        let treeRecorder = KeyboardShortcuts.RecorderCocoa(for: .toggleTree)
        treeRecorder.frame = NSRect(x: 120, y: 560, width: 356, height: 26)
        contentView.addSubview(treeRecorder)

        addSeparator(y: 540, to: contentView)

        // 模型接入
        addSectionTitle("模型接入", y: 514, to: contentView)
        let currentNote = NSTextField(labelWithString: "选择即切换当前使用")
        currentNote.font = .systemFont(ofSize: 11)
        currentNote.textColor = .tertiaryLabelColor
        currentNote.frame = NSRect(x: 200, y: 514, width: 180, height: 16)
        contentView.addSubview(currentNote)

        providerPopUp.frame = NSRect(x: 24, y: 482, width: 330, height: 26)
        providerPopUp.target = self
        providerPopUp.action = #selector(providerSelectionChanged)
        contentView.addSubview(providerPopUp)

        let addButton = PointerButton(title: "＋", target: self, action: #selector(addProvider))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.font = .systemFont(ofSize: 13)
        addButton.frame = NSRect(x: 360, y: 482, width: 32, height: 26)
        addButton.toolTip = "新增一个接入"
        contentView.addSubview(addButton)

        removeButton.target = self
        removeButton.action = #selector(removeProvider)
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.font = .systemFont(ofSize: 13)
        removeButton.frame = NSRect(x: 396, y: 482, width: 32, height: 26)
        removeButton.toolTip = "删除当前接入（内置项不可删）"
        contentView.addSubview(removeButton)

        // 名称
        addRowLabel("名称", y: 451, to: contentView)
        configure(nameField, placeholder: "例如：公司网关、我的 Gemini")
        nameField.frame = NSRect(x: 120, y: 448, width: 356, height: 24)
        contentView.addSubview(nameField)

        // 协议
        addRowLabel("协议", y: 419, to: contentView)
        kindPopUp.frame = NSRect(x: 120, y: 416, width: 200, height: 26)
        kindPopUp.target = self
        kindPopUp.action = #selector(kindChanged)
        for kind in ProviderConfig.Kind.allCases {
            kindPopUp.addItem(withTitle: kind.title)
            kindPopUp.lastItem?.representedObject = kind.rawValue
        }
        contentView.addSubview(kindPopUp)

        // Base URL
        addRowLabel("Base URL", y: 387, to: contentView)
        configure(baseURLField, placeholder: ProviderConfig.Kind.gemini.defaultBaseURL)
        baseURLField.frame = NSRect(x: 120, y: 384, width: 356, height: 24)
        contentView.addSubview(baseURLField)

        // API Key
        addRowLabel("API Key", y: 355, to: contentView)
        apiKeyField.placeholderString = "粘贴 API Key（仅保存在本机偏好设置）"
        apiKeyField.font = .systemFont(ofSize: 12)
        apiKeyField.delegate = self
        apiKeyField.frame = NSRect(x: 120, y: 352, width: 280, height: 24)
        contentView.addSubview(apiKeyField)

        keyHelpButton.target = self
        keyHelpButton.action = #selector(openKeyHelp)
        keyHelpButton.bezelStyle = .rounded
        keyHelpButton.controlSize = .small
        keyHelpButton.font = .systemFont(ofSize: 12)
        keyHelpButton.frame = NSRect(x: 406, y: 351, width: 70, height: 26)
        keyHelpButton.isHidden = true
        contentView.addSubview(keyHelpButton)

        // 模型
        addRowLabel("模型", y: 323, to: contentView)
        configure(modelField, placeholder: ProviderConfig.Kind.gemini.defaultModel)
        modelField.frame = NSRect(x: 120, y: 320, width: 280, height: 24)
        contentView.addSubview(modelField)

        fetchButton.target = self
        fetchButton.action = #selector(fetchModels)
        fetchButton.bezelStyle = .rounded
        fetchButton.controlSize = .small
        fetchButton.font = .systemFont(ofSize: 12)
        fetchButton.frame = NSRect(x: 408, y: 318, width: 68, height: 26)
        fetchButton.toolTip = "从服务端拉取可用模型列表"
        contentView.addSubview(fetchButton)

        // 测试
        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        testButton.font = .systemFont(ofSize: 12)
        testButton.frame = NSRect(x: 120, y: 282, width: 88, height: 26)
        contentView.addSubview(testButton)

        syncFreeButton.target = self
        syncFreeButton.action = #selector(syncFreeModelsTapped)
        syncFreeButton.bezelStyle = .rounded
        syncFreeButton.controlSize = .small
        syncFreeButton.font = .systemFont(ofSize: 12)
        syncFreeButton.frame = NSRect(x: 214, y: 282, width: 104, height: 26)
        syncFreeButton.toolTip = "从 OpenRouter 拉取当前免费模型（每天自动刷新）"
        contentView.addSubview(syncFreeButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 326, y: 287, width: 150, height: 16)
        contentView.addSubview(statusLabel)

        addSeparator(y: 264, to: contentView)

        // 知识库
        addSectionTitle("知识库", y: 240, to: contentView)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: 24, y: 214, width: 330, height: 18)
        pathLabel.toolTip = "卡片存放在这个目录的 \(CardStore.fileName) 里，换目录时会把现有卡片复制过去"
        contentView.addSubview(pathLabel)

        let chooseButton = PointerButton(title: "选择…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        chooseButton.font = .systemFont(ofSize: 12)
        chooseButton.frame = NSRect(x: 396, y: 209, width: 80, height: 26)
        chooseButton.toolTip = "选择知识库文件夹"
        contentView.addSubview(chooseButton)

        addSeparator(y: 190, to: contentView)

        // 联网搜索
        addSectionTitle("联网搜索", y: 168, to: contentView)

        webSearchToggle.target = self
        webSearchToggle.action = #selector(webSearchToggled)
        webSearchToggle.font = .systemFont(ofSize: 12)
        webSearchToggle.frame = NSRect(x: 22, y: 140, width: 320, height: 20)
        webSearchToggle.state = Settings.webSearchEnabled ? .on : .off
        contentView.addSubview(webSearchToggle)

        webSearchKeyField.placeholderString = "Tavily API Key（tvly-…）"
        webSearchKeyField.font = .systemFont(ofSize: 12)
        webSearchKeyField.delegate = self
        webSearchKeyField.stringValue = Settings.webSearchAPIKey
        webSearchKeyField.frame = NSRect(x: 24, y: 110, width: 376, height: 24)
        contentView.addSubview(webSearchKeyField)

        webSearchHelpButton.target = self
        webSearchHelpButton.action = #selector(openTavily)
        webSearchHelpButton.bezelStyle = .rounded
        webSearchHelpButton.controlSize = .small
        webSearchHelpButton.font = .systemFont(ofSize: 12)
        webSearchHelpButton.frame = NSRect(x: 406, y: 109, width: 70, height: 26)
        webSearchHelpButton.toolTip = "在 tavily.com 注册后免费领一个 Key（1000 次/月）"
        contentView.addSubview(webSearchHelpButton)

        let hint = NSTextField(wrappingLabelWithString:
            "API Key 只写入本机偏好设置，不会上传；需要 Key 的接入右侧都有「去获取」。\n"
            + "「OpenAI 兼容」适用于 OpenAI / DeepSeek / Groq / 智谱 / 火山 / 百炼 等，"
            + "Base URL 填到 /v1 或只填域名都行。\n"
            + "免费模型（OpenRouter 19 个）由 app 自动导入并每天更新。\n"
            + "联网搜索用 Tavily，免费 1000 次/月；开着时模型可能为一次提问连搜多轮。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 12, width: 452, height: 88)
        contentView.addSubview(hint)

        reloadProviderPopUp(selecting: Settings.activeProviderID)
        refreshPath()
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

    private var currentIndex: Int? {
        let index = providerPopUp.indexOfSelectedItem
        guard index >= 0, index < popupIDs.count else { return nil }
        let id = popupIDs[index]
        return Settings.providerConfigs.firstIndex(where: { $0.id == id })
    }

    private func reloadProviderPopUp(selecting id: UUID?) {
        let configs = Settings.providerConfigs
        popupIDs = configs.map(\.id)

        providerPopUp.removeAllItems()
        for config in configs {
            let title = config.isConfigured
                ? "\(config.displayName) · \(config.modelLabel)"
                : "\(config.displayName) · \(config.modelLabel)（未配置）"
            providerPopUp.addItem(withTitle: title)
        }

        let target = id ?? Settings.activeProviderID
        if let index = popupIDs.firstIndex(of: target) {
            providerPopUp.selectItem(at: index)
        }
        loadFields()
    }

    private func loadFields() {
        guard let index = currentIndex else { return }
        let config = Settings.providerConfigs[index]

        nameField.stringValue = config.name
        baseURLField.stringValue = config.baseURL
        apiKeyField.stringValue = config.apiKey
        modelField.stringValue = config.model

        let kindIndex = ProviderConfig.Kind.allCases.firstIndex(of: config.kind) ?? 0
        kindPopUp.selectItem(at: kindIndex)

        nameField.placeholderString = config.kind.title
        baseURLField.placeholderString = config.kind.defaultBaseURL
        modelField.placeholderString = config.kind.defaultModel
        apiKeyField.isEnabled = config.kind.needsAPIKey
        if !config.kind.needsAPIKey {
            apiKeyField.placeholderString = "本地接入不需要 Key"
        } else if config.keyHelp != nil {
            apiKeyField.placeholderString = "粘贴 API Key，没有就点右边的「去获取」"
        } else {
            apiKeyField.placeholderString = "粘贴 API Key（仅保存在本机偏好设置）"
        }

        // 知道去哪儿领 Key 的接入，给一个可点的入口
        if let help = config.keyHelp, config.kind.needsAPIKey {
            keyHelpButton.isHidden = false
            keyHelpButton.toolTip = help.text
        } else {
            keyHelpButton.isHidden = true
        }

        removeButton.isEnabled = !config.isBuiltin
        statusLabel.stringValue = config.isConfigured ? "" : "还没配置完整"
    }

    /// 把当前表单写回配置。改名/改地址/改模型都在字段结束编辑时落盘。
    private func persistCurrentEdits() {
        guard let index = currentIndex else { return }
        var configs = Settings.providerConfigs
        let id = configs[index].id

        // 名称被清空时保留原名：输入框还没填充完就触发 endEditing 的情况不该抹掉用户起的名字。
        // 想恢复默认显示，清空后的空名本来也会回退到协议名（displayName）。
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            configs[index].name = name
        }
        configs[index].baseURL = baseURLField.stringValue
        configs[index].apiKey = apiKeyField.stringValue
        configs[index].model = modelField.stringValue

        Settings.providerConfigs = configs
        reloadProviderPopUp(selecting: id)
    }

    @objc private func providerSelectionChanged() {
        guard let index = currentIndex else { return }
        let config = Settings.providerConfigs[index]
        // 选中即切换：用户点开某条接入，通常就是要用它
        Settings.selectProvider(id: config.id)
        loadFields()
        statusLabel.stringValue = ""
    }

    @objc private func kindChanged() {
        guard let index = currentIndex,
              let raw = kindPopUp.selectedItem?.representedObject as? String,
              let kind = ProviderConfig.Kind(rawValue: raw) else { return }

        var configs = Settings.providerConfigs
        guard configs[index].kind != kind else { return }
        configs[index].kind = kind
        // 换协议时把地址和模型带成该协议的默认值，避免留下上一种协议的地址
        if configs[index].baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ProviderConfig.Kind.allCases.contains(where: { $0.defaultBaseURL == configs[index].baseURL }) {
            configs[index].baseURL = kind.defaultBaseURL
        }
        if configs[index].model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ProviderConfig.Kind.allCases.contains(where: { $0.defaultModel == configs[index].model }) {
            configs[index].model = kind.defaultModel
        }
        Settings.providerConfigs = configs
        reloadProviderPopUp(selecting: configs[index].id)
    }

    @objc private func addProvider() {
        var configs = Settings.providerConfigs
        let kind = ProviderConfig.Kind.openAICompatible
        let count = configs.filter { $0.kind == .openAICompatible }.count + 1
        let config = ProviderConfig(name: "新接入 \(count)",
                                    kind: kind,
                                    baseURL: kind.defaultBaseURL,
                                    model: kind.defaultModel)
        configs.append(config)
        Settings.providerConfigs = configs
        reloadProviderPopUp(selecting: config.id)
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    @objc private func removeProvider() {
        guard let index = currentIndex else { return }
        let config = Settings.providerConfigs[index]
        guard !config.isBuiltin else { return }

        var configs = Settings.providerConfigs
        configs.remove(at: index)
        Settings.providerConfigs = configs

        // 删掉的正好是当前使用的，就退回第一条可用的
        if Settings.activeProviderID == config.id {
            let fallback = configs.first(where: { $0.isConfigured }) ?? configs[0]
            Settings.selectProvider(id: fallback.id)
        }
        reloadProviderPopUp(selecting: Settings.activeProviderID)
    }

    // MARK: - 拉取 / 测试

    @objc private func fetchModels() {
        persistCurrentEdits()
        guard let index = currentIndex else { return }
        let config = Settings.providerConfigs[index]

        statusLabel.stringValue = "拉取中…"
        fetchButton.isEnabled = false

        Task { @MainActor in
            let base = URL(string: config.baseURL) ?? URL(string: config.kind.defaultBaseURL)!
            let models: [String]
            switch config.kind {
            case .ollama:
                models = await OllamaProvider.availableModels(baseURL: base)
            case .gemini:
                models = await GeminiProvider.availableModels(apiKey: config.apiKey)
            case .openAICompatible:
                models = await OpenAICompatibleProvider.availableModels(baseURL: base, apiKey: config.apiKey)
            }

            fetchButton.isEnabled = true
            guard !models.isEmpty else {
                statusLabel.stringValue = "没拉到模型，检查地址 / Key"
                return
            }
            statusLabel.stringValue = "\(models.count) 个可用模型"
            presentModelMenu(models)
        }
    }

    private func presentModelMenu(_ models: [String]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // 免费层模型多，菜单太长反而难找，前 40 个足够
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
        modelField.stringValue = name
        persistCurrentEdits()
        statusLabel.stringValue = "已选 \(name)"
    }

    /// 打开「去哪里领 Key」的页面
    @objc private func openKeyHelp() {
        guard let index = currentIndex,
              let help = Settings.providerConfigs[index].keyHelp else { return }
        NSWorkspace.shared.open(help.url)
    }

    @objc private func syncFreeModelsTapped() {
        syncFreeButton.isEnabled = false
        statusLabel.stringValue = "同步中…"

        Task { @MainActor in
            let previous = Settings.activeProviderID
            let ok = await Settings.syncFreeModels()
            syncFreeButton.isEnabled = true

            guard ok else {
                statusLabel.stringValue = "拉取失败，检查网络"
                return
            }
            statusLabel.stringValue = "\(Settings.freeModelsCount) 个免费模型"
            // 当前表单可能就是这条接入，同步时模型名可能被维护过，重新载入
            reloadProviderPopUp(selecting: previous)
        }
    }

    @objc private func testConnection() {
        persistCurrentEdits()
        guard let index = currentIndex else { return }
        let config = Settings.providerConfigs[index]

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
        if field === webSearchKeyField {
            Settings.webSearchAPIKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if field === nameField || field === baseURLField || field === modelField || field === apiKeyField {
            persistCurrentEdits()
        }
    }

    @objc private func webSearchToggled() {
        Settings.webSearchEnabled = webSearchToggle.state == .on
        if Settings.webSearchEnabled && Settings.webSearchAPIKey.isEmpty {
            statusLabel.stringValue = "还需填 Tavily Key"
        } else {
            statusLabel.stringValue = ""
        }
    }

    @objc private func openTavily() {
        guard let url = URL(string: "https://tavily.com/") else { return }
        NSWorkspace.shared.open(url)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        // 每次打开都从最新状态重建，避免面板里切过模型后这里还显示旧的
        reloadProviderPopUp(selecting: Settings.activeProviderID)
        refreshPath()
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
        print("popup.items        =", providerPopUp.itemTitles)
        print("popup.selected     =", providerPopUp.titleOfSelectedItem ?? "nil")
        print("name.field         =", nameField.stringValue.isEmpty ? "(空)" : nameField.stringValue,
              "| placeholder:", nameField.placeholderString ?? "")
        print("kind.popup         =", kindPopUp.titleOfSelectedItem ?? "nil")
        print("baseURL.field      =", baseURLField.stringValue.isEmpty ? "(空)" : baseURLField.stringValue)
        print("apiKey.field       =", apiKeyField.stringValue.isEmpty ? "(空)" : "(已填)")
        print("apiKey.enabled     =", apiKeyField.isEnabled)
        print("apiKey.placeholder =", apiKeyField.placeholderString ?? "")
        print("model.field        =", modelField.stringValue)
        print("remove.enabled     =", removeButton.isEnabled)
        print("keyHelp.button     =", keyHelpButton.isHidden ? "隐藏" : "显示")
        print("keyHelp.tooltip    =", keyHelpButton.toolTip ?? "")
        print("webSearch.enabled  =", Settings.webSearchEnabled)
        print("webSearch.hasKey   =", Settings.webSearchAPIKey.isEmpty ? "否" : "是")
        print("webSearch.ready    =", Settings.webSearchReady)
        print("status             =", statusLabel.stringValue)
        print("configs.isConfigured =", Settings.providerConfigs.map { "\($0.displayName):\($0.isConfigured)" })
        print("settings.level     =", window?.level.rawValue ?? -1)
        print("panel.level        =", PanelController.shared.panel.level.rawValue)
        print("settings.abovePanel=", (window?.level.rawValue ?? -1) > PanelController.shared.panel.level.rawValue)
    }
}
