// 由 assets/logo/build.py 生成，请勿手改；要改几何请改 build.py 后重新生成。
import AppKit

/// 菜单栏品牌图标：一枝两叶。18×18 画布，模板图，随菜单栏深浅自动反色。
enum BrandMark {
    /// 路径指令：M x y / L x y / C c1x c1y c2x c2y x y / Z，坐标为 64 网格
    private static let data = """
M 31.16 57.29 L 30.94 56.49 L 30.77 55.68 L 30.64 54.87 L 30.53 54.05 L 30.44 53.22 L 30.37 52.39 L 30.32 51.56 L 30.29 50.72 L 30.28 49.87 L 30.29 49.03 L 30.32 48.19 L 30.37 47.34 L 30.44 46.49 L 30.54 45.65 L 30.65 44.80 L 30.79 43.95 L 30.94 43.11 L 31.12 42.27 L 31.32 41.43 L 31.55 40.59 L 31.79 39.76 L 32.06 38.93 L 32.35 38.10 L 32.67 37.28 L 24.38 33.47 L 23.88 34.47 L 23.41 35.49 L 22.97 36.51 L 22.56 37.53 L 22.17 38.57 L 21.81 39.61 L 21.48 40.66 L 21.17 41.71 L 20.88 42.76 L 20.62 43.82 L 20.39 44.88 L 20.17 45.94 L 19.99 47.01 L 19.82 48.07 L 19.68 49.14 L 19.56 50.21 L 19.46 51.28 L 19.38 52.34 L 19.32 53.41 L 19.28 54.47 L 19.26 55.53 L 19.26 56.59 L 19.26 57.65 L 19.24 58.71 Z  M 26.48 39.76 C 39.68 41.58 40.85 33.98 44.92 23.75 C 34.25 24.66 26.99 23.67 23.71 35.84 Z  M 21.84 46.24 C 19.69 35.03 12.87 35.58 3.08 34.15 C 6.18 43.55 6.83 50.36 18.24 50.53 Z 
"""

    private static let scale: CGFloat = 0.38241
    private static let offsetX: CGFloat = -0.178
    private static let offsetY: CGFloat = -6.751

    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            for path in paths() { path.fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "知枝"
        return image
    }


    private static func paths() -> [NSBezierPath] {
        var result: [NSBezierPath] = []
        var current: NSBezierPath?
        let tokens = data.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        var i = 0

        func next() -> CGFloat {
            defer { i += 1 }
            return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0
        }
        func point() -> NSPoint {
            let x = next() * scale + offsetX
            let y = next() * scale + offsetY
            return NSPoint(x: x, y: y)
        }

        while i < tokens.count {
            switch tokens[i] {
            case "M":
                i += 1
                let path = NSBezierPath()
                path.move(to: point())
                current = path
            case "L":
                i += 1
                current?.line(to: point())
            case "C":
                i += 1
                let c1 = point(), c2 = point(), end = point()
                current?.curve(to: end, controlPoint1: c1, controlPoint2: c2)
            case "Z":
                i += 1
                current?.close()
                if let path = current { result.append(path) }
                current = nil
            default:
                i += 1
            }
        }
        return result
    }
}
