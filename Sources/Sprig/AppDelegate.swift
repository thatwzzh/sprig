import AppKit
import SprigCore
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var freeModelTimer: Timer?

    func applicationWillTerminate(_ notification: Notification) {
        AcpClient.shared.killForQuit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Settings.prepareAgentWorkspace()
        // 新装的 agent 启动时并进列表，面板菜单里就能直接选
        Settings.syncDetectedAgents()
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

        // 知识库目录来自设置（默认 ~/Documents/Sprig/repository）；首次切换时 CardStore 会把旧数据搬过去
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
        if arguments.contains("--test-agents") {
            // 和设置页「测试全部」走同一条路径，只是结果打到终端
            let semaphore = DispatchSemaphore(value: 0)
            // detached：主线程马上要卡在信号量上，不能让它继承 MainActor 上下文
            Task.detached {
                let path = AcpEnvironment.searchPath()
                for config in Settings.agentConfigs {
                    let status = await AcpClient.shared.probeStatus(
                        commandLine: config.command,
                        cwd: Settings.acpWorkspacePath,
                        path: path)
                    await AcpClient.shared.shutdown()
                    print("agent[\(config.displayName)] = \(status.label)")
                    if let models = try? await AcpClient.shared.discoverModels(commandLine: config.command,
                                                                              cwd: Settings.acpWorkspacePath,
                                                                              path: path),
                       !models.isEmpty {
                        print("    · \(models.count) 个可选模型：「\(models.prefix(3).map(\.id).joined(separator: "、"))」…")
                    }
                    await AcpClient.shared.shutdown()
                }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
            return
        }
        if let index = arguments.firstIndex(of: "--md-demo"), index + 1 < arguments.count {
            // 不经过模型，直接渲染一段 Markdown，用来核对排版/主题
            let themeID = arguments.count > index + 2 ? arguments[index + 2] : "default"
            Settings.readingTheme = themeID
            let sample = """
            ## 反向代理配置

            要点有三个：

            - **多路复用**：一个连接跑多个请求
            - 头部压缩用 `HPACK`
            - 服务端推送已废弃

            ```nginx
            server {
                listen 80;
                server_name example.com;

                location / {
                    proxy_pass http://127.0.0.1:3000;
                    proxy_set_header Host $host;
                }
            }
            ```

            > 引用：配置改完记得 `nginx -s reload`。

            | 维度 | Redis | Memcached |
            | --- | --- | --- |
            | 数据结构 | 多种 | 仅 KV |
            | 持久化 | 支持 | 不支持 |
            """
            let width: CGFloat = Theme.panelWidth
            let view = AnswerTextView()
            if ProcessInfo.processInfo.environment["SPRIG_MD_DEBUG"] != nil {
                view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                view.renderRich(sample)
                let text = view.string as NSString
                print("=== 共 \(text.length) 字 ===")
                let storage = view.textStorage!
                let codeStart = text.range(of: "server {").location
                var index = codeStart
                while index < text.length {
                    let attrs = storage.attributes(at: index, effectiveRange: nil)
                    let hasBG = attrs[.backgroundColor] != nil ? "BG" : "--"
                    let para = (attrs[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? -1
                    let ch = text.substring(with: NSRange(location: index, length: 1))
                    print("\(index) \(ch == "\n" ? "⏎" : ch) \(hasBG) indent=\(para)")
                    index += 1
                }
            }
            view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            view.renderRich(sample)
            view.syncHeightToContent()
            let height = view.frame.height + 24
            // 用视图快照，别自己 lockFocus 画——坐标是翻转的，会上下颠倒
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            view.frame = NSRect(x: 0, y: height - view.frame.height, width: width, height: view.frame.height)
            container.addSubview(view)
            host.contentView = container
            host.orderBack(nil)
            container.layoutSubtreeIfNeeded()
            if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
                container.cacheDisplay(in: container.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: arguments[index + 1]))
                print("md demo ->", arguments[index + 1], "theme:", themeID)
            }
            host.orderOut(nil)
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--html-demo"), index + 1 < arguments.count {
            // 核对 HTML 离屏渲染：画一张简单的流程图，落成 PNG 后退出
            let html = """
            <div style="font-family:-apple-system;padding:8px">
            <svg width="520" height="150" xmlns="http://www.w3.org/2000/svg">
              <rect x="10" y="50" width="120" height="46" rx="8" fill="#eef" stroke="#69c"/>
              <text x="70" y="78" text-anchor="middle" font-size="14">用户请求</text>
              <line x1="130" y1="73" x2="210" y2="73" stroke="#69c" stroke-width="2"/>
              <polygon points="210,68 220,73 210,78" fill="#69c"/>
              <rect x="220" y="50" width="120" height="46" rx="8" fill="#efe" stroke="#6c9"/>
              <text x="280" y="78" text-anchor="middle" font-size="14">网关鉴权</text>
              <line x1="340" y1="73" x2="410" y2="73" stroke="#6c9" stroke-width="2"/>
              <polygon points="410,68 420,73 410,78" fill="#6c9"/>
              <rect x="420" y="50" width="90" height="46" rx="8" fill="#fee" stroke="#c96"/>
              <text x="465" y="78" text-anchor="middle" font-size="14">业务服务</text>
            </svg></div>
            """
            Task { @MainActor in
                if let image = await HtmlSnapshot.image(for: html),
                   let data = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                    .representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
                    print("html demo ->", arguments[index + 1])
                } else {
                    print("html demo 渲染失败")
                }
                exit(0)
            }
            return
        }
        if let index = arguments.firstIndex(of: "--chart-demo"), index + 1 < arguments.count {
            // 只用于核对图表排版：画一组示例，直接落成 PNG 后退出
            let bar = ChartSpec(kind: .bar, title: "季度营收（万元）",
                                labels: ["Q1", "Q2", "Q3", "Q4"], values: [12, 30, 22, 41])
            let line = ChartSpec(kind: .line, title: "响应延迟（ms）",
                                 labels: ["1月", "2月", "3月", "4月", "5月"], values: [120, 96, 88, 92, 75])
            let images = [ChartImage.draw(spec: bar, maxWidth: 520),
                          ChartImage.draw(spec: line, maxWidth: 520)]
            let width = images.map(\.size.width).max() ?? 520
            let height = images.map(\.size.height).reduce(0, +) + 12
            let canvas = NSImage(size: NSSize(width: width, height: height))
            canvas.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            var y = height
            for image in images {
                y -= image.size.height
                image.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                y -= 12
            }
            canvas.unlockFocus()
            if let tiff = canvas.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
                print("chart demo ->", arguments[index + 1])
            }
            exit(0)
        }
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
