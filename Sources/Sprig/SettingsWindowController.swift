import AppKit
import SprigCore
import KeyboardShortcuts

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

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
    private let removeButton = PointerButton(title: "－", target: nil, action: nil)

    /// providerPopUp 里每一项对应的配置 id，顺序与 Settings.providerConfigs 一致
    private var popupIDs: [UUID] = []

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "\(AppInfo.name)设置"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
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
        apiKeyField.frame = NSRect(x: 120, y: 352, width: 356, height: 24)
        contentView.addSubview(apiKeyField)

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

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 216, y: 287, width: 260, height: 16)
        contentView.addSubview(statusLabel)

        addSeparator(y: 264, to: contentView)

        // 知识库
        addSectionTitle("知识库", y: 238, to: contentView)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: 24, y: 210, width: 330, height: 18)
        contentView.addSubview(pathLabel)

        let chooseButton = PointerButton(title: "选择…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        chooseButton.font = .systemFont(ofSize: 12)
        chooseButton.frame = NSRect(x: 396, y: 205, width: 80, height: 26)
        chooseButton.toolTip = "选择知识库文件夹"
        contentView.addSubview(chooseButton)

        let hint = NSTextField(wrappingLabelWithString:
            "API Key 只写入本机偏好设置，不会上传到任何第三方；面板里点模型按钮可以随时切换接入。\n\n"
            + "Gemini 免费层默认 gemini-2.5-flash，额度约为 10–15 次/分钟；被限流时歇一会儿再问。\n\n"
            + "OpenAI 兼容协议适用于 OpenAI、DeepSeek、Moonshot、Groq、OpenRouter、LM Studio 等；"
            + "Base URL 填到 /v1 或只填域名都行。\n\n"
            + "知识库是一个 JSON 文件（\(CardStore.fileName)），保存在上面的目录里；"
            + "首次切换到新目录时会把现有卡片复制过去，原目录不会被删除。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 32, width: 452, height: 162)
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
        apiKeyField.placeholderString = config.kind.needsAPIKey
            ? "粘贴 API Key（仅保存在本机偏好设置）"
            : "本地接入不需要 Key"

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
        if field === nameField || field === baseURLField || field === modelField || field === apiKeyField {
            persistCurrentEdits()
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        // 每次打开都从最新状态重建，避免面板里切过模型后这里还显示旧的
        reloadProviderPopUp(selecting: Settings.activeProviderID)
        refreshPath()
        statusLabel.stringValue = ""
        window?.makeKeyAndOrderFront(nil)
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
        print("status             =", statusLabel.stringValue)
        print("configs.isConfigured =", Settings.providerConfigs.map { "\($0.displayName):\($0.isConfigured)" })
    }
}
