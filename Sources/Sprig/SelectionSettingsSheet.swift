import AppKit
import SprigCore
import KeyboardShortcuts

/// 跨应用划词设置。内容嵌入「知枝设置」的标签页；保留独立窗口能力用于调试/兼容。
@MainActor
final class SelectionSettingsSheet: NSWindowController, NSWindowDelegate {
    static let shared = SelectionSettingsSheet()
    private var embeddedView: NSView?

    private static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)

    private let enabledToggle = NSButton(checkboxWithTitle: "启用跨应用划词", target: nil, action: nil)
    private let webToggle = NSButton(checkboxWithTitle: "解释时抓取网页上下文", target: nil, action: nil)
    private let permissionStatus = NSTextField(labelWithString: "")
    private let permissionButton = PointerButton(title: "打开系统设置", target: nil, action: nil)
    private let recheckButton = PointerButton(title: "重新检测", target: nil, action: nil)
    private let lengthPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lengthValues = [200, 500, 800, 1000, 1500, 2000]
    private let foldersSummary = NSTextField(labelWithString: "")
    private let vaultsSummary = NSTextField(labelWithString: "")
    private var recorder: KeyboardShortcuts.RecorderCocoa?

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 930),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "跨应用划词"
        window.isReleasedWhenClosed = false
        window.level = Self.windowLevel
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    /// 给「知枝设置」标签页复用的内容视图（不再单独弹窗）。
    func embeddedContentView() -> NSView {
        if let embeddedView { return embeddedView }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 930))
        buildContent(in: view)
        embeddedView = view
        return view
    }

    func refreshForDisplay() {
        reloadControls()
        refreshPermission()
    }

    func present() {
        window?.contentView = embeddedContentView()
        refreshForDisplay()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 构建

    private let left: CGFloat = 24
    private let right: CGFloat = 436

    private func buildContent(in contentView: NSView) {
        let left: CGFloat = 24
        let right = max(320, contentView.bounds.width - 24)
        let width = right - left
        var y: CGFloat = 884

        let title = NSTextField(labelWithString: "跨应用选词")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: left, y: y, width: width, height: 20)
        contentView.addSubview(title)
        y -= 30

        let subtitle = NSTextField(wrappingLabelWithString:
            "在任何 App 里选中文字，按快捷键生成一张带来源的解释卡；只在你主动触发时读取选区。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: left, y: y - 32, width: width, height: 32)
        contentView.addSubview(subtitle)
        y -= 44

        enabledToggle.target = self
        enabledToggle.action = #selector(enabledChanged)
        enabledToggle.font = .systemFont(ofSize: 12)
        enabledToggle.frame = NSRect(x: left - 4, y: y, width: width, height: 20)
        contentView.addSubview(enabledToggle)
        y -= 26

        addSeparator(y: y, to: contentView, left: left, width: width)
        y -= 24

        addSectionLabel("取词与权限", y: y, to: contentView, left: left, width: width)
        y -= 28

        addRowLabel("解释选区快捷键", y: y, to: contentView, left: left)
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .explainSelection)
        recorder.frame = NSRect(x: 150, y: y - 2, width: right - 150, height: 26)
        contentView.addSubview(recorder)
        self.recorder = recorder
        y -= 40

        addRowLabel("辅助功能权限", y: y, to: contentView, left: left)
        permissionStatus.font = .systemFont(ofSize: 11)
        permissionStatus.textColor = .secondaryLabelColor
        permissionStatus.frame = NSRect(x: 150, y: y + 2, width: right - 150 - 112, height: 18)
        contentView.addSubview(permissionStatus)

        permissionButton.target = self
        permissionButton.action = #selector(openAccessibilitySettings)
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.font = .systemFont(ofSize: 11)
        permissionButton.frame = NSRect(x: right - 104, y: y - 2, width: 104, height: 24)
        contentView.addSubview(permissionButton)
        y -= 30

        recheckButton.target = self
        recheckButton.action = #selector(recheckPermission)
        recheckButton.bezelStyle = .rounded
        recheckButton.controlSize = .small
        recheckButton.font = .systemFont(ofSize: 11)
        recheckButton.frame = NSRect(x: 150, y: y, width: 84, height: 22)
        contentView.addSubview(recheckButton)
        y -= 30

        addSeparator(y: y, to: contentView, left: left, width: width)
        y -= 24

        addSectionLabel("选区与上下文", y: y, to: contentView, left: left, width: width)
        y -= 30

        addRowLabel("选区字符上限", y: y, to: contentView, left: left)
        lengthPopUp.frame = NSRect(x: 150, y: y - 2, width: 120, height: 24)
        lengthPopUp.controlSize = .small
        lengthPopUp.font = .systemFont(ofSize: 12)
        lengthPopUp.target = self
        lengthPopUp.action = #selector(lengthChanged)
        if lengthPopUp.numberOfItems == 0 {
            for value in lengthValues {
                lengthPopUp.addItem(withTitle: "\(value) 字")
                lengthPopUp.lastItem?.representedObject = value
            }
        }
        contentView.addSubview(lengthPopUp)
        y -= 38

        webToggle.target = self
        webToggle.action = #selector(webContextChanged)
        webToggle.font = .systemFont(ofSize: 12)
        webToggle.frame = NSRect(x: left - 4, y: y, width: width, height: 20)
        contentView.addSubview(webToggle)
        y -= 32

        let webNote = NSTextField(wrappingLabelWithString:
            "网页上下文只请求公网 http(s)，拒绝内网/本机；抓不到时只使用选区本身。")
        webNote.font = .systemFont(ofSize: 11)
        webNote.textColor = .secondaryLabelColor
        webNote.frame = NSRect(x: left, y: y - 30, width: width, height: 30)
        contentView.addSubview(webNote)
        y -= 44

        addSeparator(y: y, to: contentView, left: left, width: width)
        y -= 24

        addSectionLabel("文档反查（可选）", y: y, to: contentView, left: left, width: width)
        y -= 26

        let docHint = NSTextField(wrappingLabelWithString:
            "不配置也能正常解释：只有目标 App 不提供文件路径、需要按窗口标题反查本地文档时才用。"
            + "支持 Markdown / PDF / Office / Obsidian。")
        docHint.font = .systemFont(ofSize: 11)
        docHint.textColor = .secondaryLabelColor
        // 说明文字可能折成两行；留足高度和下方间距，避免和「文档文件夹」行重叠
        docHint.frame = NSRect(x: left, y: y - 40, width: width, height: 40)
        contentView.addSubview(docHint)
        y -= 68

        addRowLabel("文档文件夹", y: y, to: contentView, left: left)
        foldersSummary.font = .systemFont(ofSize: 11)
        foldersSummary.textColor = .secondaryLabelColor
        foldersSummary.lineBreakMode = .byTruncatingMiddle
        foldersSummary.frame = NSRect(x: 150, y: y + 4, width: right - 150 - 146, height: 18)
        contentView.addSubview(foldersSummary)

        let clearFolder = makeSmallButton(title: "清空", action: #selector(clearDocumentFolders))
        clearFolder.frame = NSRect(x: right - 136, y: y - 1, width: 60, height: 24)
        contentView.addSubview(clearFolder)
        let addFolder = makeSmallButton(title: "添加…", action: #selector(addDocumentFolder))
        addFolder.frame = NSRect(x: right - 68, y: y - 1, width: 68, height: 24)
        contentView.addSubview(addFolder)
        y -= 38

        addRowLabel("Obsidian 库", y: y, to: contentView, left: left)
        vaultsSummary.font = .systemFont(ofSize: 11)
        vaultsSummary.textColor = .secondaryLabelColor
        vaultsSummary.lineBreakMode = .byTruncatingMiddle
        vaultsSummary.frame = NSRect(x: 150, y: y + 4, width: right - 150 - 146, height: 18)
        contentView.addSubview(vaultsSummary)

        let clearVault = makeSmallButton(title: "清空", action: #selector(clearObsidianVaults))
        clearVault.frame = NSRect(x: right - 136, y: y - 1, width: 60, height: 24)
        contentView.addSubview(clearVault)
        let addVault = makeSmallButton(title: "添加…", action: #selector(addObsidianVault))
        addVault.frame = NSRect(x: right - 68, y: y - 1, width: 68, height: 24)
        contentView.addSubview(addVault)
        y -= 38

        let note = NSTextField(wrappingLabelWithString:
            "文件内容只在本机读取；解释结果与上下文快照只存在本机知识库。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: left, y: max(y - 30, 20), width: width, height: 30)
        contentView.addSubview(note)

        reloadControls()
        refreshPermission()
    }

    private func addSectionLabel(_ text: String, y: CGFloat, to view: NSView, left: CGFloat, width: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.frame = NSRect(x: left, y: y, width: width, height: 18)
        view.addSubview(label)
    }

    private func addSeparator(y: CGFloat, to view: NSView, left: CGFloat, width: CGFloat) {
        let line = NSView(frame: NSRect(x: left, y: y, width: width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        view.addSubview(line)
    }

    private func makeSmallButton(title: String, action: Selector) -> PointerButton {
        let button = PointerButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func addTitle(_ text: String, y: CGFloat, to view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.frame = NSRect(x: left, y: y, width: 240, height: 20)
        view.addSubview(label)
    }

    private func addRowLabel(_ text: String, y: CGFloat, to view: NSView, left: CGFloat = 24) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: left, y: y + 2, width: 120, height: 18)
        view.addSubview(label)
    }

    // MARK: - 状态

    private func reloadControls() {
        enabledToggle.state = Settings.externalSelectionEnabled ? .on : .off
        webToggle.state = Settings.fetchWebContext ? .on : .off
        let current = Settings.externalSelectionMaxLength
        if let index = lengthValues.firstIndex(where: { $0 >= current }) {
            lengthPopUp.selectItem(at: index)
        } else {
            lengthPopUp.selectItem(at: lengthValues.count - 1)
        }

        let folders = Settings.documentFolders
        foldersSummary.stringValue = folders.isEmpty ? "未配置" : "已添加 \(folders.count) 个目录"
        foldersSummary.toolTip = folders.isEmpty ? nil : folders.joined(separator: "\n")

        let vaults = Settings.obsidianVaults
        vaultsSummary.stringValue = vaults.isEmpty ? "未配置" : vaults.map(\.name).joined(separator: "、")
        vaultsSummary.toolTip = vaults.isEmpty ? nil : vaults.map { "\($0.name)：\($0.path)" }.joined(separator: "\n")
    }

    private func refreshPermission() {
        let trusted = SelectionCapture.isTrusted
        permissionStatus.stringValue = trusted ? "已授权，可以读取选区" : "未授权：按热键会先引导授权"
        permissionStatus.textColor = trusted ? .secondaryLabelColor : .systemOrange
        permissionButton.title = trusted ? "系统设置" : "去授权"
    }

    // MARK: - 动作

    @objc private func enabledChanged() {
        Settings.externalSelectionEnabled = enabledToggle.state == .on
    }

    @objc private func webContextChanged() {
        Settings.fetchWebContext = webToggle.state == .on
    }

    @objc private func lengthChanged() {
        let value = lengthPopUp.selectedItem?.representedObject as? Int ?? 500
        Settings.externalSelectionMaxLength = value
    }

    @objc private func openAccessibilitySettings() {
        if !SelectionCapture.isTrusted {
            Settings.hasRequestedAccessibility = true
            _ = SelectionCapture.requestAccess()
        }
        SelectionCapture.openAccessibilitySettings()
        // 系统设置切回来后再刷新一次状态；窗口不强制常驻前台
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refreshPermission()
        }
    }

    @objc private func recheckPermission() {
        if !SelectionCapture.isTrusted {
            Settings.hasRequestedAccessibility = true
            _ = SelectionCapture.requestAccess()
        }
        refreshPermission()
    }

    @objc private func addDocumentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择用于反查本地 Markdown / PDF / Office 文档的文件夹"
        guard panel.runModal() == .OK else { return }
        var folders = Settings.documentFolders
        for url in panel.urls where !folders.contains(url.path) {
            folders.append(url.path)
        }
        Settings.documentFolders = folders
        reloadControls()
    }

    @objc private func clearDocumentFolders() {
        Settings.documentFolders = []
        reloadControls()
    }

    @objc private func addObsidianVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "选择 Obsidian vault 根目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var vaults = Settings.obsidianVaults
        let name = url.lastPathComponent
        guard !vaults.contains(where: { $0.path == url.path }) else { return }
        vaults.append(ObsidianVault(name: name, path: url.path))
        Settings.obsidianVaults = vaults
        reloadControls()
    }

    @objc private func clearObsidianVaults() {
        Settings.obsidianVaults = []
        reloadControls()
    }
}
