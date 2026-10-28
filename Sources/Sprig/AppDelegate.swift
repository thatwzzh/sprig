import AppKit
import SprigCore
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var freeModelTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 包名换到 com.catking.sprig 之前，先把旧域里的设置/快捷键搬过来
        Settings.migrateLegacyDefaultsIfNeeded()
        // 默认知识库目录改成 ~/Documents/Sprig，把老默认位置的数据带过来
        Settings.prepareCardsDirectory()
        // 老配置没有 contextLength 字段，按 kind 补一次；Ollama/OpenRouter 的真实值靠后面的探测和同步
        Settings.backfillContextLengths()
        // 内置 Ollama 被改成别的协议后，本地区域会空掉，补一条回来
        Settings.ensureLocalConfig()
        // Gemini 旧模型下线后要换名字，否则一直 404
        Settings.migrateRetiredGeminiModels()
        // 智谱是后加的内置免费项，老用户升级后补上
        Settings.ensureZhipuConfig()
        // 自定义代理要在任何请求之前生效
        HTTPClient.proxy = Settings.customProxy

        setupMainMenu()
        setupStatusItem()
        PanelController.shared.prewarm()

        KeyboardShortcuts.onKeyUp(for: .togglePanel) {
            PanelController.shared.toggle()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleTree) {
            PanelController.shared.toggleTreeShortcut()
        }

        // 知识库目录来自设置（默认 ~/Documents/Sprig）；首次切换时 CardStore 会把旧数据搬过去
        Task.detached(priority: .userInitiated) {
            await CardStore.shared.useDirectory(Settings.cardsDirectory)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            // 切到别的 App：面板沉底但不隐藏（由 PanelController 统一处理）
            DispatchQueue.main.async {
                PanelController.shared.hideIfUnfocused()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            // 过滤器放到主队列闭包里：这里不是 MainActor 上下文，直接读 panel 会告警
            DispatchQueue.main.async {
                guard let window = note.object as? NSWindow,
                      window === PanelController.shared.panel else { return }
                PanelController.shared.hideIfUnfocused()
            }
        }

        // 本机装了 Ollama 就顺手把模型名对齐，省得用户手填。
        // 只碰内置 Ollama 那一项，用户自己加的接入不碰。
        Task.detached {
            guard let ollama = Settings.providerConfigs.first(where: { $0.kind == .ollama }),
                  let base = URL(string: ollama.baseURL) else { return }
            // 顺带拿模型的真实上下文窗口，上下文预算按它算比用固定值准
            async let names = OllamaProvider.availableModels(baseURL: base)
            async let lengths = OllamaProvider.contextLengths(baseURL: base)
            let (models, contexts) = await (names, lengths)
            guard !models.isEmpty else { return }
            await MainActor.run {
                Settings.adoptDetectedOllamaModels(models, contextLengths: contexts)
            }
        }

        setupFreeModelRefresh()

        handleDebugArguments()
    }

    /// 仅用于本机冒烟测试：`Sprig --show` / `--ask "问题"` / `--selftest`
    private func handleDebugArguments() {
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PanelController.shared.debugSelfTest()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if arguments.contains("--probe-free") {
            Task { @MainActor in
                let synced = await Settings.syncModels(in: .free)
                print("[probe-free] 拉取 \(synced.total) 个，可用 \(synced.usable) 个")
                for config in Settings.providerConfigs where config.resolvedCategory == .free {
                    let models = config.cachedModels ?? []
                    guard !models.isEmpty else { continue }
                    print("=== \(config.displayName)：剩 \(models.count) 个 ===")
                    for model in models { print("  ✓ \(model)") }
                }
                NSApp.terminate(nil)
            }
            return
        }
        if arguments.contains("--tree-dump") {
            let filterIndex = arguments.firstIndex(of: "--tree-filter")
            let filter = filterIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                PanelController.shared.debugTreeDump(filter: filter)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                // 同时带 --show 时先弹面板，用来对照「设置是否压在面板上面」
                if arguments.contains("--show") {
                    PanelController.shared.show()
                }
                SettingsWindowController.shared.present()
                if arguments.contains("--dump") {
                    SettingsWindowController.shared.debugDump()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NSApp.terminate(nil)
                    }
                }
            }
            return
        }
        if let index = arguments.firstIndex(of: "--ask"), index + 1 < arguments.count {
            let question = arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                PanelController.shared.debugAsk(question)
                if arguments.contains("--tree") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        PanelController.shared.toggleTree()
                    }
                }
            }
        } else if arguments.contains("--tree") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                PanelController.shared.show()
                PanelController.shared.toggleTree()
            }
        } else if arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                PanelController.shared.show()
            }
        }
    }

    /// LSUIElement 应用平时不显示菜单栏，但设置窗口激活时仍需要标准编辑动作，
    /// 而且菜单项的快捷键等价物是 ⌘C/⌘V 在 App 激活状态下的兜底通道。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 \(AppInfo.name)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    /// 免费模型：首次启动自动导入，之后每小时看一眼，超过一天就重新拉。
    /// 拉不到就静默跳过——不能因为网络问题影响 app 启动。
    private func setupFreeModelRefresh() {
        Task {
            guard Settings.needsFreeModelSync else { return }
            let ok = await Settings.syncAllModels()
            print("[models] 同步\(ok ? "成功" : "失败")，可用 \(Settings.freeModelsCount) 个")
        }

        let timer = Timer(timeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in
                guard Settings.needsFreeModelSync else { return }
                await Settings.syncAllModels()
            }
        }
        // .common 模式：菜单跟踪、窗口拖动期间也能触发
        RunLoop.main.add(timer, forMode: .common)
        freeModelTimer = timer
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // 矢量绘制，深浅菜单栏由 isTemplate 自动反色
            button.image = BrandMark.image()
            button.imagePosition = .imageOnly
            button.toolTip = AppInfo.name
        }

        // 菜单只留三件事：打开面板 / 设置 / 退出
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开\(AppInfo.name)", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item

    }

    @objc private func openPanel() {
        NSApp.activate(ignoringOtherApps: true)
        PanelController.shared.show()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.present()
    }
}
