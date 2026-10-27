import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 默认 ⌥Space（Raycast 式肌肉记忆）。若与 Raycast 冲突，在设置页重新录制。
    static let togglePanel = Self("togglePanel", default: .init(.space, modifiers: [.option]))

    /// 知识树开关，默认 ⌘⇧T；可在设置页重新录制
    static let toggleTree = Self("toggleTree", default: .init(.t, modifiers: [.command, .shift]))
}
