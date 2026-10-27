import AppKit

/// AppKit 的普通按钮 hover 时是箭头光标；可点击的控件统一换成手型指针。
final class PointerButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
