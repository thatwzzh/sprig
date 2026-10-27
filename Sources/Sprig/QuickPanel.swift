import AppKit

/// 面板窗口：非激活、可输入、浮在所有窗口之上但不抢 App 焦点。
final class QuickPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        // 需求：面板绑定在打开它的那个桌面，切桌面时不跟随、也不出现在别的桌面。
        // 所以：
        //   .managed            → 归属当前 Space，切走就看不到（回来还在）
        //   .fullScreenAuxiliary → 允许浮在同 Space 的全屏应用上
        // 明确不要 .canJoinAllSpaces（所有桌面可见）
        // 明确不要 .moveToActiveSpace（跟着当前桌面跑）
        collectionBehavior = [.managed, .fullScreenAuxiliary]
        // 无边框：.titled 的 28pt 标题栏会吞掉输入框的点击（变成拖窗口）
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
