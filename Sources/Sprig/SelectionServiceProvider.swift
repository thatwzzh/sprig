import AppKit
import SprigCore

/// Services 菜单入口：任意 App 选中文字 → 右键「服务」→「用知枝解释」。
///
/// 只从 pasteboard 取纯文本，不读其他 App 的无障碍树（P1 才会补来源线索）。
/// 服务回调可能发生在 App 刚被系统拉起时，所以这里只做轻量解析，真正建卡走主线程。
@MainActor
final class SelectionServiceProvider: NSObject {
    static let shared = SelectionServiceProvider()

    @objc func explainSelection(_ pboard: NSPasteboard,
                                userData: String,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard Settings.externalSelectionEnabled else { return }
        let raw = pboard.string(forType: .string) ?? ""
        let parsed = SelectionEnvelope.normalizeSelection(raw, limit: Settings.externalSelectionMaxLength)
        guard !parsed.text.isEmpty else { return }

        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app?.localizedName
        var envelope = SelectionEnvelope(source: SelectionSource(kind: .app, appName: appName),
                                         selection: parsed.text,
                                         selectionTruncated: parsed.truncated ? true : nil)

        // 如果已经授权辅助功能，顺手补来源（网页标题/URL、窗口标题）和选区上下文；
        // 没授权就保持 Services 的零权限路径，只用选中的文字。
        guard SelectionCapture.isTrusted else {
            PanelController.shared.handleExternalSelection(envelope)
            return
        }
        Task { @MainActor in
            var fallback: String?
            if let captured = await SelectionCapture.captureFrontmost(
                maxLength: Settings.externalSelectionMaxLength),
               captured.selection.contains(parsed.text) || parsed.text.contains(captured.selection) {
                envelope.source = captured.source
                fallback = captured.surroundingText
            }
            PanelController.shared.handleExternalSelection(envelope, fallbackContext: fallback)
        }
    }
}
