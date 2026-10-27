import AppKit
import SprigCore
import KeyboardShortcuts

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private let modelField = NSTextField(string: "")
    private let pathLabel = NSTextField(labelWithString: "")

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "\(AppInfo.name)设置"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        // 唤起面板
        addRowLabel("唤起面板快捷键", y: 350, to: contentView)
        let panelRecorder = KeyboardShortcuts.RecorderCocoa(for: .togglePanel)
        panelRecorder.frame = NSRect(x: 150, y: 344, width: 286, height: 26)
        contentView.addSubview(panelRecorder)

        // 知识树
        addRowLabel("知识树快捷键", y: 312, to: contentView)
        let treeRecorder = KeyboardShortcuts.RecorderCocoa(for: .toggleTree)
        treeRecorder.frame = NSRect(x: 150, y: 306, width: 286, height: 26)
        contentView.addSubview(treeRecorder)

        // 模型
        addRowLabel("本地模型", y: 274, to: contentView)
        modelField.stringValue = Settings.model
        modelField.font = .systemFont(ofSize: 12)
        modelField.placeholderString = Settings.defaultModel
        modelField.frame = NSRect(x: 150, y: 270, width: 286, height: 24)
        modelField.delegate = self
        modelField.target = self
        modelField.action = #selector(commitModel)
        contentView.addSubview(modelField)

        // 知识库位置
        addRowLabel("知识库位置", y: 234, to: contentView)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: 150, y: 234, width: 190, height: 18)
        contentView.addSubview(pathLabel)

        let chooseButton = PointerButton(title: "选择…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        chooseButton.font = .systemFont(ofSize: 12)
        chooseButton.frame = NSRect(x: 348, y: 228, width: 88, height: 24)
        chooseButton.toolTip = "选择知识库文件夹"
        contentView.addSubview(chooseButton)

        let hint = NSTextField(wrappingLabelWithString:
            "两个快捷键都可以点上面重新录制（默认 ⌥Space / ⌘⇧T）。\n\n"
            + "模型需已在本地 ollama pull；改完回车生效，下次提问使用新模型。\n\n"
            + "知识库是一个 JSON 文件（\(CardStore.fileName)），保存在上面的目录里；"
            + "首次切换到新目录时会把现有卡片复制过去，原目录不会被删除。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 40, width: 412, height: 160)
        contentView.addSubview(hint)

        refreshPath()
    }

    private func addRowLabel(_ title: String, y: CGFloat, to contentView: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 24, y: y, width: 120, height: 18)
        contentView.addSubview(label)
    }

    private func refreshPath() {
        let url = Settings.cardsDirectory
        pathLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        pathLabel.toolTip = url.path
    }

    @objc private func commitModel() {
        let value = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.model = value.isEmpty ? Settings.defaultModel : value
        modelField.stringValue = Settings.model
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

    func controlTextDidEndEditing(_ obj: Notification) {
        commitModel()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        refreshPath()
        window?.makeKeyAndOrderFront(nil)
    }
}
