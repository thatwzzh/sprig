import AppKit

/// 回答区顶部的问题条：显示当前这张卡对应的问题原文（子卡显示「关于「片段」」）。
/// 面包屑回答的是「我在树的哪里」，这里回答的是「我在看什么问题的答案」。
final class QuestionHeaderView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        label.font = Theme.questionFont
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String) {
        label.stringValue = text
    }

    var debugText: String { label.stringValue }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: Theme.horizontalInset,
                             y: 3,
                             width: max(0, bounds.width - Theme.horizontalInset * 2),
                             height: max(0, bounds.height - 6))
    }
}
