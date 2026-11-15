import AppKit
import ApplicationServices
import SprigCore

/// 一次 AX 取词的结果。
struct CapturedSelection {
    var selection: String
    var source: SelectionSource
    var surroundingText: String?
}

/// 从其他 App 的辅助功能树里读取当前选区 + 来源线索。
///
/// 设计取舍：
/// - 只在用户按热键时读一次，不做后台监听/轮询；
/// - 所有 AX 调用都在后台线程，并设置 messaging timeout，避免卡住主线程；
/// - Chromium/WebView 第一次被查询时才开无障碍树，读不到选区要等一下重试一次；
/// - 选区文本是硬约束，来源/周边文字拿不到就降级，不让整条链路失败。
enum SelectionCapture {
    /// 读不到选区时的等待重试间隔（Chromium 冷启动）
    private static let retryDelay: TimeInterval = 0.12
    private static let messagingTimeout: Float = 0.8

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 本进程是否已经主动请求过授权。
    /// 注意：adhoc 签名每次重建都会让 TCC 记的 cdhash 对不上，所以「授权过」不能跨构建复用；
    /// 用进程内标记，每次启动最多弹一次，避免用户点一次热键弹一次。
    private static var requestedThisLaunch = false

    /// 弹系统授权提示（每次启动最多一次）；返回当前是否已授权。
    @discardableResult
    static func requestAccess() -> Bool {
        requestedThisLaunch = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 本次启动是否已经请求过授权（提示框只弹一次）。
    static var hasRequestedThisLaunch: Bool { requestedThisLaunch }

    /// 未授权时请求一次（同一进程内不重复弹）；已授权时直接返回 true。
    @discardableResult
    static func requestAccessOncePerLaunch() -> Bool {
        if isTrusted { return true }
        if requestedThisLaunch { return false }
        return requestAccess()
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 取前台 App 的当前选区。调用前应先记录前台 pid（面板显示后前台可能变成 Sprig）。
    /// - Parameter allowClipboardFallback: AX 读不到时是否用「模拟 ⌘C + 剪贴板」兜底。
    ///   Electron 应用（如 DSH）常常不暴露 AX 选区，只能用这条路。
    @MainActor
    static func captureFrontmost(maxLength: Int,
                                 allowClipboardFallback: Bool = false) async -> CapturedSelection? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            NSLog("[Sprig] capture: no frontmost application")
            return nil
        }
        let pid = app.processIdentifier
        NSLog("[Sprig] capture: frontmost=%@ pid=%d trusted=%d",
              app.localizedName ?? "?", pid, isTrusted ? 1 : 0)
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            NSLog("[Sprig] capture: frontmost is Sprig itself")
            return nil
        }

        if let captured = await capture(pid: pid, maxLength: maxLength) {
            return captured
        }
        guard allowClipboardFallback else { return nil }
        NSLog("[Sprig] capture: AX failed, trying clipboard fallback")
        let selected = await Task.detached(priority: .userInitiated) {
            copySelectionViaClipboard()
        }.value
        if let selected {
            let normalized = SelectionEnvelope.normalizeSelection(selected, limit: maxLength)
            guard !normalized.text.isEmpty else { return nil }
            let source = await Task.detached(priority: .userInitiated) {
                sourceHints(pid: pid,
                            appName: app.localizedName,
                            bundleID: app.bundleIdentifier)
            }.value
            NSLog("[Sprig] capture: clipboard fallback succeeded, length=%d", normalized.text.count)
            return CapturedSelection(selection: normalized.text,
                                     source: source,
                                     surroundingText: nil)
        }
        return nil
    }

    /// 没有 AX 选区时的兜底：模拟 ⌘C → 读剪贴板 → 还原剪贴板。
    ///
    /// 只在用户按热键时触发；需要辅助功能权限（发合成按键）。
    /// 只在「剪贴板确实被写入」时采用，避免把上一次复制的内容当选区。
    static func copySelectionViaClipboard() -> String? {
        guard CGPreflightPostEventAccess() else {
            NSLog("[Sprig] clipboard fallback: no permission to post keyboard events")
            return nil
        }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            return nil
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        var copied: String?
        for _ in 0..<40 {
            usleep(10_000)
            if pasteboard.changeCount != changeCount {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        // 还原用户原来的剪贴板（只在这次确实写入过时；没写入就什么都不用做）
        if pasteboard.changeCount != changeCount {
            pasteboard.clearContents()
            if !savedItems.isEmpty {
                pasteboard.writeObjects(savedItems)
            }
        }
        let value = copied?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// 读不到选区时也尽量把窗口标题/URL 作为来源线索。
    private static func sourceHints(pid: pid_t,
                                    appName: String?,
                                    bundleID: String?) -> SelectionSource {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let window = elementAttribute(app, kAXFocusedWindowAttribute)
        let title = window.flatMap { stringAttribute($0, kAXTitleAttribute) }
        var document = window.flatMap { stringAttribute($0, kAXDocumentAttribute) }
        if document == nil {
            document = stringAttribute(app, kAXDocumentAttribute)
        }
        return makeSource(appName: appName,
                          bundleID: bundleID,
                          windowTitle: title,
                          document: document)
    }

    /// 按 pid 取选区（调试命令/已知目标 App 时用）。
    static func capture(pid: pid_t, maxLength: Int) async -> CapturedSelection? {
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName
        let bundleID = app?.bundleIdentifier
        let limit = min(max(maxLength, 1), SelectionEnvelope.absoluteMaxSelectionLength)
        return await Task.detached(priority: .userInitiated) {
            capture(pid: pid,
                    appName: appName,
                    bundleID: bundleID,
                    maxLength: limit)
        }.value
    }

    // MARK: - AX 读取（后台线程）

    private static func capture(pid: pid_t,
                                appName: String?,
                                bundleID: String?,
                                maxLength: Int) -> CapturedSelection? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        guard var focused = elementAttribute(appElement, kAXFocusedUIElementAttribute) else {
            NSLog("[Sprig] ax: no focused element for pid=%d", pid)
            return nil
        }

        var selected: String?
        var attempt = 0
        while attempt < 3 {
            if let text = readSelectedText(focused) {
                selected = text
                break
            }
            attempt += 1
            guard attempt < 3 else { break }
            // Chromium/WebView2：被 AX 问到才构建无障碍树，前几次可能为空
            Thread.sleep(forTimeInterval: retryDelay)
            if let refreshed = elementAttribute(appElement, kAXFocusedUIElementAttribute) {
                focused = refreshed
            }
        }

        // 有些 App 把选区挂在窗口上、焦点元素只是子容器；再试窗口
        if selected == nil,
           let window = elementAttribute(appElement, kAXFocusedWindowAttribute),
           let text = readSelectedText(window) {
            selected = text
            focused = window
        }

        // 最后试系统级焦点元素（部分 Electron/浏览器外壳走这条路）
        if selected == nil {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, messagingTimeout)
            if let element = elementAttribute(system, kAXFocusedUIElementAttribute),
               let text = readSelectedText(element) {
                selected = text
                focused = element
            }
        }

        guard let rawSelection = selected else {
            NSLog("[Sprig] ax: no selected text for pid=%d", pid)
            return nil
        }

        let normalized = SelectionEnvelope.normalizeSelection(rawSelection, limit: maxLength)
        guard !normalized.text.isEmpty else { return nil }

        let window = elementAttribute(appElement, kAXFocusedWindowAttribute)
            ?? elementAttribute(focused, kAXWindowAttribute)
        let windowTitle = window.flatMap { stringAttribute($0, kAXTitleAttribute) }
            ?? selfTitle(appElement)

        // 文档地址：先看焦点元素，再看窗口。浏览器通常把 URL 挂在 window/web area 上。
        var document = stringAttribute(focused, kAXDocumentAttribute)
        if document == nil, let window {
            document = stringAttribute(window, kAXDocumentAttribute)
        }
        if document == nil {
            document = stringAttribute(appElement, kAXDocumentAttribute)
        }

        // AX 的周边文字先定位选区再按段落裁，样式表/无关聊天记录都会被过滤
        let surrounding = surroundingText(of: focused, selection: normalized.text)
        if surrounding == nil {
            NSLog("[Sprig] ax: no usable surrounding context")
        }

        let source = makeSource(appName: appName,
                                bundleID: bundleID,
                                windowTitle: windowTitle,
                                document: document)
        return CapturedSelection(selection: normalized.text,
                                 source: source,
                                 surroundingText: surrounding)
    }

    private static func readSelectedText(_ element: AXUIElement, depth: Int = 0) -> String? {
        if let text = stringAttribute(element, kAXSelectedTextAttribute),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard depth < 3,
              let parent = elementAttribute(element, kAXParentAttribute) else { return nil }
        return readSelectedText(parent, depth: depth + 1)
    }

    /// 选区附近的段落文字。拿不到不是错误，调用方会降级。
    private static func surroundingText(of element: AXUIElement, selection: String) -> String? {
        guard let range = selectedRange(of: element) else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let padding = 400
        var expanded = CFRange(location: max(0, range.location - padding),
                               length: range.length + padding * 2)
        guard let axRange = AXValueCreate(.cfRange, &expanded) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value)
        guard result == .success, let text = value as? String else { return nil }
        return SelectionTextExcerpt.excerpt(from: text, selection: selection, limit: 1_200)
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.length > 0 else { return nil }
        return range
    }

    // MARK: - 来源推断

    private static func makeSource(appName: String?,
                                   bundleID: String?,
                                   windowTitle: String?,
                                   document: String?) -> SelectionSource {
        let webURL = document.flatMap { value -> String? in
            (value.hasPrefix("http://") || value.hasPrefix("https://")) ? value : nil
        }
        let filePath = document.flatMap(filePath(from:))

        let kind: SelectionSource.Kind
        if webURL != nil {
            kind = .web
        } else if bundleID == "md.obsidian" {
            kind = .note
        } else if let filePath,
                  ["md", "markdown", "txt"].contains((filePath as NSString).pathExtension.lowercased()) {
            kind = .markdown
        } else if let bundleID, bundleID.lowercased().contains("deepseek"),
                  appName?.lowercased().contains("harness") == true {
            kind = .agent
        } else if let appName, appName.lowercased().contains("deepseek harness") {
            kind = .agent
        } else {
            kind = .app
        }

        return SelectionSource(kind: kind,
                               appName: appName,
                               bundleID: bundleID,
                               title: windowTitle,
                               url: webURL,
                               filePath: filePath)
    }

    private static func filePath(from document: String) -> String? {
        if document.hasPrefix("/") { return document }
        guard let url = URL(string: document), url.isFileURL else { return nil }
        return url.path
    }

    // MARK: - AX 基础

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(element, name) else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func selfTitle(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXTitleAttribute)
    }
}
