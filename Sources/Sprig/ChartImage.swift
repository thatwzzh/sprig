import AppKit
import SprigCore

/// 把 `sprig-chart` 画成图片（柱状 / 折线），挂进答案区。
///
/// 和数据表一样走「画成图片 + NSTextAttachment」：不用引第三方图表库，
/// 也不受文本视图排版限制，高度自己说了算。
enum ChartImage {
    private static let padding: CGFloat = 14
    private static let titleHeight: CGFloat = 22
    private static let xLabelHeight: CGFloat = 18
    private static let plotHeight: CGFloat = 150
    private static let gutter: CGFloat = 42    // 左侧 y 轴刻度

    static func draw(spec: ChartSpec, maxWidth: CGFloat) -> NSImage {
        let width = max(240, min(maxWidth, 560))
        let hasTitle = !spec.title.isEmpty
        let height = padding * 2 + (hasTitle ? titleHeight : 0) + plotHeight + xLabelHeight

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

        var top = height - padding
        if hasTitle {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            (spec.title as NSString).draw(at: NSPoint(x: padding, y: top - 16), withAttributes: attributes)
            top -= titleHeight
        }

        let plot = NSRect(x: padding + gutter,
                          y: top - plotHeight,
                          width: width - padding * 2 - gutter,
                          height: plotHeight)
        let scale = niceScale(spec.values.max() ?? 1)
        let maxValue = scale.max
        let steps = scale.steps
        let accent = NSColor.controlAccentColor
        let grid = NSColor.separatorColor
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // 网格 + y 轴刻度
        for step in 0...steps {
            let ratio = CGFloat(step) / CGFloat(steps)
            let y = plot.minY + plot.height * ratio
            grid.withAlphaComponent(0.5).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = step == 0 ? 0.8 : 0.4
            line.stroke()

            let text = format(Double(maxValue) * Double(ratio))
            let size = (text as NSString).size(withAttributes: labelAttrs)
            (text as NSString).draw(at: NSPoint(x: plot.minX - size.width - 6, y: y - size.height / 2),
                                    withAttributes: labelAttrs)
        }

        let count = spec.values.count
        let slot = plot.width / CGFloat(max(count, 1))

        switch spec.kind {
        case .bar:
            let barWidth = min(38, slot * 0.55)
            for (index, value) in spec.values.enumerated() {
                let ratio = maxValue > 0 ? CGFloat(value) / CGFloat(maxValue) : 0
                let barHeight = max(1, plot.height * ratio)
                let x = plot.minX + slot * CGFloat(index) + (slot - barWidth) / 2
                let rect = NSRect(x: x, y: plot.minY, width: barWidth, height: barHeight)
                accent.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

                let text = format(value)
                let size = (text as NSString).size(withAttributes: labelAttrs)
                (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 3),
                                        withAttributes: labelAttrs)
            }
        case .line:
            let path = NSBezierPath()
            var points: [NSPoint] = []
            for (index, value) in spec.values.enumerated() {
                let ratio = maxValue > 0 ? CGFloat(value) / CGFloat(maxValue) : 0
                let x = plot.minX + slot * CGFloat(index) + slot / 2
                let y = plot.minY + plot.height * ratio
                points.append(NSPoint(x: x, y: y))
            }
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            accent.setStroke()
            path.lineWidth = 2
            path.stroke()

            for point in points {
                let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                accent.setFill()
                dot.fill()
            }
        }

        // x 轴标签
        let xAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (index, label) in spec.labels.enumerated() {
            let text = label.count > 8 ? String(label.prefix(7)) + "…" : label
            let size = (text as NSString).size(withAttributes: xAttrs)
            let x = plot.minX + slot * CGFloat(index) + slot / 2 - size.width / 2
            (text as NSString).draw(at: NSPoint(x: x, y: plot.minY - xLabelHeight + 2),
                                    withAttributes: xAttrs)
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// 挑一组「好看」的刻度：步长取 1/1.2/1.5/2/2.5/3/4/5/6/8×10ⁿ，
    /// 在 4 格和 5 格里选顶部留白更少的那个，避免出现 12.5、37.5 这种刻度。
    private static func niceScale(_ value: Double) -> (max: Double, steps: Int) {
        guard value > 0 else { return (1, 4) }
        let ladder: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        var best: (max: Double, steps: Int) = (value, 4)

        for steps in [4, 5] {
            let raw = value / Double(steps)
            let exponent = floor(log10(raw))
            let base = pow(10, exponent)
            let normalized = raw / base
            let step = (ladder.first { $0 >= normalized - 1e-9 } ?? 10) * base
            let top = step * Double(steps)
            if best.max == value || top < best.max {
                best = (top, steps)
            }
        }
        return best
    }

    private static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1_000_000 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
