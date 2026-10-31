import AppKit

/// 把 Markdown 表格画成一张图片，挂进答案区（`NSTextAttachment`）。
///
/// 为什么不用 `NSTextTable`：那套 API 的边框/内边距单位不直观，行高也不受控；
/// 画成图片则完全可控，还顺手为以后的图表组件留了同一条路。
enum TableImage {
    private static let headerFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let bodyFont = NSFont.systemFont(ofSize: 12.5)
    private static let cellPadding: CGFloat = 10
    private static let minColumnWidth: CGFloat = 72
    private static let rowHeight: CGFloat = 28
    private static let headerHeight: CGFloat = 30
    private static let cornerRadius: CGFloat = 6

    /// 按字符折行（中文没有空格，按字符最稳；英文单词偶尔会被拆开，可接受）
    private static func wrap(_ text: String, font: NSFont, maxWidth: CGFloat) -> [String] {
        guard maxWidth > 0 else { return [text] }
        var lines: [String] = []
        var current = ""
        for character in text {
            let candidate = current + String(character)
            let width = (candidate as NSString).size(withAttributes: [.font: font]).width
            if width > maxWidth, !current.isEmpty {
                lines.append(current)
                current = String(character)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    static func draw(header: [String], rows: [[String]], columns: Int, maxWidth: CGFloat,
                     palette: MarkdownTheme.Palette = MarkdownTheme.current.palette) -> NSImage {
        var widths = [CGFloat](repeating: 0, count: columns)

        func measure(_ text: String, font: NSFont, column: Int) {
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            widths[column] = max(widths[column], ceil(width) + cellPadding * 2)
        }
        for column in 0..<columns {
            measure(column < header.count ? header[column] : "", font: headerFont, column: column)
        }
        for row in rows {
            for column in 0..<columns {
                measure(column < row.count ? row[column] : "", font: bodyFont, column: column)
            }
        }
        widths = widths.map { max($0, minColumnWidth) }
        let total = widths.reduce(0, +)
        if total > maxWidth {
            // 超宽按比例压，但不低于最小列宽
            let scale = maxWidth / total
            widths = widths.map { max(minColumnWidth, $0 * scale) }
        }

        let width = widths.reduce(0, +)

        // 按列宽折行，行高取该行最多行数
        let headerLines = (0..<columns).map { column in
            wrap(column < header.count ? header[column] : "", font: headerFont,
                 maxWidth: widths[column] - cellPadding * 2)
        }
        let bodyLines = rows.map { row in
            (0..<columns).map { column in
                wrap(column < row.count ? row[column] : "", font: bodyFont,
                     maxWidth: widths[column] - cellPadding * 2)
            }
        }
        let lineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
        func rowHeight(_ lines: [[String]], _ font: NSFont) -> CGFloat {
            let maxLines = lines.map(\.count).max() ?? 1
            return max(self.rowHeight, CGFloat(maxLines) * lineHeight + cellPadding)
        }
        let headerRowHeight = rowHeight(headerLines, headerFont)
        let heights = bodyLines.map { rowHeight($0, bodyFont) }
        let height = headerRowHeight + heights.reduce(0, +) + 1
        let pixelScale: CGFloat = 2

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: max(1, Int(width * pixelScale)),
                                         pixelsHigh: max(1, Int(height * pixelScale)),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: cornerRadius, yRadius: cornerRadius)
        palette.tableBackground.setFill()
        outline.fill()

        // 表头底色：必须裁进圆角，否则上方两个角会被方形铺色盖成尖角
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        palette.tableHeader.setFill()
        NSRect(x: 0, y: height - headerRowHeight, width: width, height: headerRowHeight).fill()
        NSGraphicsContext.restoreGraphicsState()

        // 描边，边界更清楚
        palette.rule.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let separator = palette.rule
        separator.setStroke()
        func drawLine(at y: CGFloat) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: width, y: y))
            path.lineWidth = 0.5
            path.stroke()
        }
        drawLine(at: height - headerRowHeight)
        var lineY = height - headerRowHeight
        for rowHeightValue in heights {
            lineY -= rowHeightValue
            drawLine(at: lineY)
        }

        func drawCell(_ lines: [String], font: NSFont, color: NSColor,
                      x: CGFloat, y: CGFloat, rowHeight rowH: CGFloat, columnWidth: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let blockHeight = CGFloat(lines.count) * lineHeight
            var lineY = y + (rowH - blockHeight) / 2 + blockHeight - lineHeight
            for line in lines {
                let rect = NSRect(x: x + cellPadding, y: lineY,
                                  width: max(0, columnWidth - cellPadding * 2), height: lineHeight)
                (line as NSString).draw(in: rect, withAttributes: attributes)
                lineY -= lineHeight
            }
        }

        var x: CGFloat = 0
        for column in 0..<columns {
            drawCell(headerLines[column], font: headerFont, color: palette.heading,
                     x: x, y: height - headerRowHeight, rowHeight: headerRowHeight,
                     columnWidth: widths[column])
            x += widths[column]
        }

        var rowY = height - headerRowHeight
        for (index, lines) in bodyLines.enumerated() {
            rowY -= heights[index]
            var cellX: CGFloat = 0
            for column in 0..<columns {
                drawCell(lines[column], font: bodyFont, color: palette.text,
                         x: cellX, y: rowY, rowHeight: heights[index],
                         columnWidth: widths[column])
                cellX += widths[column]
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
