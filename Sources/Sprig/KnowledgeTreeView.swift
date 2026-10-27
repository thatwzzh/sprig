import AppKit
import SprigCore

private final class TreeNode: NSObject {
    let card: AnswerCard
    var children: [TreeNode] = []

    init(card: AnswerCard) {
        self.card = card
    }
}

/// 树节点：hover 时标题右侧出现删除按钮；标题可原位编辑（重命名）。
final class TreeCellView: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")
    let deleteButton = PointerButton()
    private let matchDot = NSView()

    var onDelete: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleField.font = NSFont.systemFont(ofSize: 12)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.autoresizingMask = []
        addSubview(titleField)
        textField = titleField

        deleteButton.isBordered = false
        deleteButton.bezelStyle = .inline
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")
        deleteButton.imagePosition = .imageOnly
        deleteButton.contentTintColor = .tertiaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
        deleteButton.toolTip = "删除这张卡及其子卡（⌘⌫）"
        deleteButton.isHidden = true
        addSubview(deleteButton)

        // 命中搜索的节点前面点一个圆点：祖先是为了保留路径才显示的，不能和命中混淆
        matchDot.wantsLayer = true
        matchDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        matchDot.layer?.cornerRadius = 2.5
        matchDot.isHidden = true
        addSubview(matchDot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // 右边界按可视区算：cell 有时比 clip view 更宽（NSOutlineView 会把没有滚动条的
        // documentView 多撑一截），直接用 bounds 会让按钮落进被裁掉的区域。
        let rightEdge = visibleRightEdge
        let buttonX = max(0, rightEdge - Self.rightInset - Self.buttonSize)
        deleteButton.frame = NSRect(x: buttonX, y: 3, width: Self.buttonSize, height: Self.buttonSize)

        // 标题铺满按钮左侧的全部宽度，放不下时由 byTruncatingTail 打省略号，
        // 这样既不会遮挡按钮，也不会把标题限得过短。
        let titleWidth = max(0, buttonX - Self.titleButtonGap)
        titleField.frame = NSRect(x: 0, y: 3, width: titleWidth, height: 18)

        if !matchDot.isHidden {
            let measured = titleField.attributedStringValue.size().width
            let dotX = min(measured + 5, max(0, titleWidth - 8))
            matchDot.frame = NSRect(x: dotX, y: 9.5, width: 5, height: 5)
        }
    }

    /// 当前 cell 在可视区里的最右端（cell 坐标系）
    var visibleRightEdge: CGFloat {
        guard let clip = enclosingScrollView?.contentView, clip.bounds.width > 0 else {
            return bounds.width
        }
        let visible = convert(clip.bounds, from: clip)
        return min(bounds.width, max(0, visible.maxX))
    }

    func setMatch(_ isMatch: Bool) {
        matchDot.isHidden = !isMatch
        needsLayout = true
    }

    var isMatchMarked: Bool { !matchDot.isHidden }

    private static let buttonSize: CGFloat = 18
    private static let rightInset: CGFloat = 4
    private static let titleButtonGap: CGFloat = 4

    /// 整行都能点（选中 / 重命名），hover 时给手型指针
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !titleField.isEditable else { return }
        deleteButton.isHidden = false
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        deleteButton.isHidden = true
        needsLayout = true
    }

    func resetForReuse() {
        deleteButton.isHidden = true
        titleField.isEditable = false
    }

    @objc private func handleDelete() {
        onDelete?()
    }
}

/// 单击已选中的行 = 重命名；回车 = 重命名；⌘⌫ = 删除
private final class TreeOutlineView: NSOutlineView {
    var onReclickRow: ((Int) -> Void)?
    var onReturnKey: (() -> Void)?
    var onDeleteKey: (() -> Void)?

    /// 知识树不允许横向滚动：NSScrollView 会把 documentView 撑得比可视区更宽（实测多 32pt），
    /// 行尾的 hover 删除按钮也会跟着落进被裁掉的区域。
    /// 宽度钉死在可视宽度上，frame 与 setFrameSize 两条路径都要拦（AppKit 内部走后者）。
    override var frame: NSRect {
        get { super.frame }
        set { super.frame = clampedToClip(newValue) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(clampedToClip(NSRect(origin: .zero, size: newSize)).size)
    }

    private func clampedToClip(_ rect: NSRect) -> NSRect {
        guard let clipWidth = enclosingScrollView?.contentView.bounds.width, clipWidth > 0 else {
            return rect
        }
        var value = rect
        value.size.width = min(value.size.width, clipWidth)
        return value
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, row == selectedRow, event.clickCount == 1 {
            onReclickRow?(row)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, selectedRow >= 0 {
            onReturnKey?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if event.modifierFlags.contains(.command) {
                onDeleteKey?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// 右侧知识树：搜索过滤 + 原位重命名 + hover 删除。
final class KnowledgeTreeView: NSView {
    var onSelect: ((AnswerCard) -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((AnswerCard, String) -> Void)?
    var onDelete: ((AnswerCard) -> Void)?

    private let headerLabel = NSTextField(labelWithString: "知识树")
    private let countLabel = NSTextField(labelWithString: "")
    private let closeButton = PointerButton(title: "×", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let outline = TreeOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "还没有卡片")

    private var roots: [TreeNode] = []
    private var allCards: [AnswerCard] = []
    private var matchedIDs: Set<UUID> = []
    private var matchedCount = 0
    private var currentID: UUID?
    private var isSyncingSelection = false

    private var renamingCardID: UUID?
    private var renamingRow: Int = -1
    private var isCancellingRename = false

    private var isFiltering: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        headerLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor

        countLabel.font = NSFont.systemFont(ofSize: 10.5)
        countLabel.textColor = .tertiaryLabelColor

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.toolTip = "收起知识树（⌘⇧T）"

        searchField.placeholderString = "搜索标题或正文…"
        searchField.font = NSFont.systemFont(ofSize: 11)
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.onReclickRow = { [weak self] row in self?.beginRename(row: row) }
        outline.onReturnKey = { [weak self] in
            guard let self, self.outline.selectedRow >= 0 else { return }
            self.beginRename(row: self.outline.selectedRow)
        }
        outline.onDeleteKey = { [weak self] in
            guard let self, let card = self.selectedCard() else { return }
            self.onDelete?(card)
        }

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false

        emptyLabel.font = NSFont.systemFont(ofSize: 11.5)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        addSubview(headerLabel)
        addSubview(countLabel)
        addSubview(closeButton)
        addSubview(searchField)
        addSubview(scroll)
        addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var headerHeight: CGFloat { 64 }

    override func layout() {
        super.layout()
        let width = bounds.width
        headerLabel.frame = NSRect(x: Theme.horizontalInset, y: bounds.height - 26, width: 100, height: 16)
        countLabel.frame = NSRect(x: Theme.horizontalInset + 58, y: bounds.height - 25, width: 80, height: 14)
        closeButton.frame = NSRect(x: width - 30, y: bounds.height - 28, width: 20, height: 20)
        searchField.frame = NSRect(x: 10, y: bounds.height - 54, width: max(0, width - 20), height: 22)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: max(0, bounds.height - headerHeight))

        // NSOutlineView 作为 documentView 不会自动撑满，必须手动给尺寸
        let contentWidth = scroll.frame.width
        let contentHeight = scroll.frame.height
        if let column = outline.tableColumns.first, abs(column.width - contentWidth) > 0.5 {
            column.width = contentWidth
        }
        let rowsHeight = CGFloat(outline.numberOfRows) * (outline.rowHeight + outline.intercellSpacing.height)
        outline.frame = NSRect(x: 0, y: 0,
                               width: contentWidth,
                               height: max(contentHeight, rowsHeight))

        emptyLabel.frame = NSRect(x: 0, y: bounds.height / 2 - 8, width: width, height: 16)
    }

    // MARK: - 数据

    func reload(currentID: UUID? = nil) {
        if let currentID { self.currentID = currentID }
        Task { @MainActor in
            let cards = await CardStore.shared.all()
            self.allCards = cards
            self.applyFilter()
        }
    }

    func select(id: UUID?) {
        guard let id else { return }
        currentID = id
        guard let node = allNodes().first(where: { $0.card.id == id }) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        isSyncingSelection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        isSyncingSelection = false
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        var visibleIDs = Set(allCards.map(\.id))
        if !query.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: allCards.map { ($0.id, $0) })
            let matched = allCards.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.answer.localizedCaseInsensitiveContains(query)
            }
            matchedCount = matched.count
            matchedIDs = Set(matched.map(\.id))
            var needed = matchedIDs
            for card in matched {
                var parent = card.parentID
                var depth = 0
                while let pid = parent, let parentCard = byID[pid], depth < 64 {
                    needed.insert(pid)
                    parent = parentCard.parentID
                    depth += 1
                }
            }
            visibleIDs = needed
        } else {
            matchedCount = allCards.count
            matchedIDs = []
        }

        let cards = allCards.filter { visibleIDs.contains($0.id) }
        buildTree(cards)
        countLabel.stringValue = allCards.isEmpty ? "" : (isFiltering ? "\(matchedCount)/\(allCards.count)" : "\(allCards.count)")
        emptyLabel.stringValue = isFiltering && matchedCount == 0 ? "没有匹配的卡片" : "还没有卡片"
        emptyLabel.isHidden = !(cards.isEmpty)
        needsLayout = true

        if let currentID { select(id: currentID) }
    }

    private func buildTree(_ cards: [AnswerCard]) {
        let grouped = Dictionary(grouping: cards, by: { $0.parentID })
        var map: [UUID: TreeNode] = [:]
        for card in cards {
            map[card.id] = TreeNode(card: card)
        }
        for card in cards {
            guard let node = map[card.id] else { continue }
            let ordered = (grouped[card.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            node.children = ordered.compactMap { map[$0.id] }
        }
        roots = (grouped[nil] ?? [])
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { map[$0.id] }

        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    private func allNodes() -> [TreeNode] {
        var result: [TreeNode] = []
        func walk(_ nodes: [TreeNode]) {
            for node in nodes {
                result.append(node)
                walk(node.children)
            }
        }
        walk(roots)
        return result
    }

    private func selectedCard() -> AnswerCard? {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? TreeNode else { return nil }
        return node.card
    }

    /// 调试用：确认树真的有行、尺寸正常
    func debugState() -> String {
        var cellInfo = "no-cell"
        if outline.numberOfRows > 0,
           let cell = outline.view(atColumn: 0, row: 0, makeIfNecessary: false) as? TreeCellView {
            cellInfo = "cellBounds=\(cell.bounds) rightEdge=\(cell.visibleRightEdge) title=\(cell.titleField.frame) button=\(cell.deleteButton.frame)"
        }
        var matchInfo = "no-match-row"
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? TreeNode,
                  matchedIDs.contains(node.card.id) else { continue }
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TreeCellView
            matchInfo = "row=\(row) title=\(node.card.title) marked=\(cell?.isMatchMarked ?? false)"
            break
        }
        return "rows=\(outline.numberOfRows) roots=\(roots.count) cards=\(allCards.count) matched=\(matchedCount) matchedIDs=\(matchedIDs.count) outlineFrame=\(outline.frame) scrollFrame=\(scroll.frame) contentSize=\(scroll.contentSize) columnWidth=\(outline.tableColumns.first?.width ?? -1) \(cellInfo) \(matchInfo)"
    }

    func debugFilter(_ text: String) {
        searchField.stringValue = text
        applyFilter()
    }

    // MARK: - 重命名

    private func beginRename(row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? TreeNode else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TreeCellView else { return }

        renamingCardID = node.card.id
        renamingRow = row
        isCancellingRename = false

        cell.titleField.isEditable = true
        cell.titleField.isSelectable = true
        cell.titleField.delegate = self
        cell.titleField.stringValue = node.card.title
        window?.makeFirstResponder(cell.titleField)
        cell.titleField.currentEditor()?.selectAll(nil)
    }

    private func finishRename(commit: Bool) {
        let row = renamingRow
        let id = renamingCardID
        renamingRow = -1
        renamingCardID = nil

        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TreeCellView else {
            return
        }
        let value = cell.titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cell.titleField.isEditable = false
        cell.titleField.delegate = nil

        guard commit, let id, !value.isEmpty,
              let card = allCards.first(where: { $0.id == id }), card.title != value else {
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
            if let currentID { select(id: currentID) }
            return
        }
        onRename?(card, value)
    }

    @objc private func handleClose() {
        onClose?()
    }
}

extension KnowledgeTreeView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}

extension KnowledgeTreeView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isCancellingRename else {
            isCancellingRename = false
            return
        }
        finishRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            isCancellingRename = true
            control.abortEditing()
            finishRename(commit: false)
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
            if let currentID { select(id: currentID) }
            return true
        }
        return false
    }
}

extension KnowledgeTreeView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? TreeNode { return node.children.count }
        return roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? TreeNode { return node.children[index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TreeNode else { return false }
        return !node.children.isEmpty
    }
}

extension KnowledgeTreeView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("TreeNodeCell")

        let cell: TreeCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? TreeCellView {
            cell = reused
            cell.resetForReuse()
        } else {
            cell = TreeCellView()
            cell.identifier = identifier
        }

        let isMatch = matchedIDs.contains(node.card.id)
        cell.setMatch(isMatch)
        cell.titleField.attributedStringValue = attributedTitle(for: node, isMatch: isMatch)
        cell.toolTip = isMatch ? snippet(for: node.card) : nil
        cell.onDelete = { [weak self] in self?.onDelete?(node.card) }
        return cell
    }

    private func attributedTitle(for node: TreeNode, isMatch: Bool) -> NSAttributedString {
        let title = node.card.title
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDimmed = !query.isEmpty && !isMatch

        // 标题被删除按钮挤窄时用省略号收尾，而不是硬裁掉半个字
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: isMatch ? .semibold : .regular),
                .foregroundColor: isDimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )

        if !query.isEmpty {
            let ns = title as NSString
            var searchRange = NSRange(location: 0, length: ns.length)
            while searchRange.length > 0 {
                let found = ns.range(of: query, options: [.caseInsensitive], range: searchRange)
                if found.location == NSNotFound { break }
                text.addAttribute(.backgroundColor,
                                  value: NSColor.systemYellow.withAlphaComponent(0.45),
                                  range: found)
                let next = found.location + found.length
                guard found.length > 0, next <= ns.length else { break }
                searchRange = NSRange(location: next, length: ns.length - next)
            }
        }

        if !node.children.isEmpty {
            text.append(NSAttributedString(
                string: "  \(node.children.count)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
        }
        return text
    }

    /// 命中在正文里时，标题上看不出原因，用 tooltip 给一段命中摘要
    private func snippet(for card: AnswerCard) -> String? {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let text = card.plainAnswer
        guard let range = text.range(of: query, options: .caseInsensitive) else {
            return nil
        }
        let start = text.index(range.lowerBound, offsetBy: -18, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 28, limitedBy: text.endIndex) ?? text.endIndex
        let fragment = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        return "命中：…\(fragment)…"
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? TreeNode else { return }
        guard node.card.id != currentID else { return }
        currentID = node.card.id
        onSelect?(node.card)
    }
}
