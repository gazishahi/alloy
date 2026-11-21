import Foundation

/// Characters drawn to the cell rather than taken from the font, as Ghostty's sprite font draws
/// them: box drawing (light and heavy lines, dashes, rounded corners, half lines), block elements
/// and shades, braille, powerline's triangles, chevrons and half circles, and most of the
/// legacy computing symbols (LegacyComputing.swift). A font's glyphs for
/// these leave hairline gaps between rows and sit off the cell grid; drawn, they join exactly.
/// Double lines and diagonals still come from the font.
extension TerminalRenderer {
    /// The quads for `scalar` filling the cell at `left`, `top` (`width` × `height` pixels), or
    /// nil when the font draws it. `line` is a light line's thickness in pixels.
    func sprite(_ scalar: UInt32, left: Float, top: Float, width: Float, height: Float, line: Float, color: SIMD4<Float>) -> [Quad]? {
        var quads: [Quad] = []
        func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, alpha: Float = 1) {
            let x = x0.rounded(), y = y0.rounded(), w = x1.rounded() - x, h = y1.rounded() - y
            guard w > 0, h > 0 else { return }
            quads.append(Quad(rect: SIMD4(x, y, w, h), uv: .zero, color: SIMD4(color.x, color.y, color.z, color.w * alpha), kind: 0))
        }
        let right = left + width, bottom = top + height
        switch scalar {
        case 0x2500...0x254B, 0x2574...0x257F:
            if let arms = Self.boxArms(scalar) { lines(arms, left: left, top: top, width: width, height: height, line: line, rect: rect) }
            else if let dashes = Self.boxDashes(scalar) {
                // ┄ ┅ ┆ ┇ ┈ ┉ ┊ ┋: segments with gaps, one less gap than dashes, centered.
                let thickness = dashes.heavy ? line * 2 : line
                let length = dashes.vertical ? height : width
                let gap = max(1, (length / Float(dashes.count * 4)).rounded())
                let dash = (length - gap * Float(dashes.count)) / Float(dashes.count)
                for i in 0..<dashes.count {
                    let start = Float(i) * (dash + gap) + gap / 2
                    if dashes.vertical {
                        let x = (left + (width - thickness) / 2).rounded()
                        rect(x, top + start, x + thickness, top + start + dash)
                    } else {
                        let y = (top + (height - thickness) / 2).rounded()
                        rect(left + start, y, left + start + dash, y + thickness)
                    }
                }
            } else { return nil }
        case 0x254C...0x254F:
            // ╌ ╍ ╎ ╏: two dashes.
            let vertical = scalar >= 0x254E, thickness = scalar % 2 == 1 ? line * 2 : line
            let length = vertical ? height : width, gap = max(1, (length / 8).rounded())
            let dash = (length - gap * 2) / 2
            for i in 0..<2 {
                let start = Float(i) * (dash + gap) + gap / 2
                if vertical {
                    let x = (left + (width - thickness) / 2).rounded()
                    rect(x, top + start, x + thickness, top + start + dash)
                } else {
                    let y = (top + (height - thickness) / 2).rounded()
                    rect(left + start, y, left + start + dash, y + thickness)
                }
            }
        case 0x256D...0x2570:
            roundedCorner(scalar, left: left, top: top, width: width, height: height, line: line, rect: rect)
        case 0x2580...0x259F:
            block(scalar, left: left, top: top, right: right, bottom: bottom, rect: rect)
        case 0x1FB00...0x1FB9B:
            guard let pieces = LegacyComputing.shapes[scalar] else { return nil }
            legacy(pieces, left: left, top: top, width: width, height: height) { rect($0, $1, $2, $3, alpha: $4) }
        case 0x2800...0x28FF:
            // Braille: eight dots, two columns of four; bit n is dot n+1.
            let bits = scalar - 0x2800
            guard bits != 0 else { return [] }
            let dot = max(1, (width / 4).rounded())
            let columns: [Float] = [left + width / 4 - dot / 2, left + width * 3 / 4 - dot / 2]
            // Typed a step at a time: as one expression, CI's compiler gave up on it (Alloy 0.9.0).
            let rows: [Float] = (0..<4).map { (index: Int) -> Float in
                let center: Float = top + height * (Float(index) * 2 + 1) / 8
                return center - dot / 2
            }
            let positions: [(Int, Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
            for (bit, (column, row)) in positions.enumerated() where bits & (1 << bit) != 0 {
                rect(columns[column], rows[row], columns[column] + dot, rows[row] + dot)
            }
        case 0xE0B0, 0xE0B2, 0xE0B4, 0xE0B6:
            // Powerline's solid triangles and half circles, a pixel row at a time.
            let middle = top + height / 2, half = height / 2
            var y = top.rounded()
            while y < bottom.rounded() {
                let distance = min(1, abs(y + 0.5 - middle) / half)
                let reach = scalar == 0xE0B0 || scalar == 0xE0B2 ? width * (1 - distance) : width * (1 - distance * distance).squareRoot()
                if scalar == 0xE0B0 || scalar == 0xE0B4 { rect(left, y, left + reach, y + 1) } else { rect(right - reach, y, right, y + 1) }
                y += 1
            }
        case 0xE0B1, 0xE0B3:
            // Powerline's thin chevrons: a line from the corners to the middle of the far edge.
            let middle = top + height / 2, half = height / 2
            var y = top.rounded()
            while y < bottom.rounded() {
                let distance = min(1, abs(y + 0.5 - middle) / half)
                let x = scalar == 0xE0B1 ? left + width * (1 - distance) - line : right - width * (1 - distance)
                rect(x, y, x + line, y + 1)
                y += 1
            }
        default:
            return nil
        }
        return quads
    }

    /// Up, right, down, left: 0 none, 1 light, 2 heavy.
    private static func boxArms(_ scalar: UInt32) -> (UInt8, UInt8, UInt8, UInt8)? {
        switch scalar {
        case 0x2500...0x2503: return [(0, 1, 0, 1), (0, 2, 0, 2), (1, 0, 1, 0), (2, 0, 2, 0)][Int(scalar - 0x2500)]
        case 0x250C...0x254B: return boxTable[Int(scalar - 0x250C)]
        case 0x2574...0x257F:
            return [(0, 0, 0, 1), (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 2), (2, 0, 0, 0), (0, 2, 0, 0), (0, 0, 2, 0),
                    (0, 2, 0, 1), (1, 0, 2, 0), (0, 1, 0, 2), (2, 0, 1, 0)][Int(scalar - 0x2574)]
        default: return nil
        }
    }

    /// U+250C ┌ through U+254B ╋, in order.
    private static let boxTable: [(UInt8, UInt8, UInt8, UInt8)] = [
        (0, 1, 1, 0), (0, 2, 1, 0), (0, 1, 2, 0), (0, 2, 2, 0), // ┌ ┍ ┎ ┏
        (0, 0, 1, 1), (0, 0, 1, 2), (0, 0, 2, 1), (0, 0, 2, 2), // ┐ ┑ ┒ ┓
        (1, 1, 0, 0), (1, 2, 0, 0), (2, 1, 0, 0), (2, 2, 0, 0), // └ ┕ ┖ ┗
        (1, 0, 0, 1), (1, 0, 0, 2), (2, 0, 0, 1), (2, 0, 0, 2), // ┘ ┙ ┚ ┛
        (1, 1, 1, 0), (1, 2, 1, 0), (2, 1, 1, 0), (1, 1, 2, 0), (2, 1, 2, 0), (2, 2, 1, 0), (1, 2, 2, 0), (2, 2, 2, 0), // ├ … ┣
        (1, 0, 1, 1), (1, 0, 1, 2), (2, 0, 1, 1), (1, 0, 2, 1), (2, 0, 2, 1), (2, 0, 1, 2), (1, 0, 2, 2), (2, 0, 2, 2), // ┤ … ┫
        (0, 1, 1, 1), (0, 1, 1, 2), (0, 2, 1, 1), (0, 2, 1, 2), (0, 1, 2, 1), (0, 1, 2, 2), (0, 2, 2, 1), (0, 2, 2, 2), // ┬ … ┳
        (1, 1, 0, 1), (1, 1, 0, 2), (1, 2, 0, 1), (1, 2, 0, 2), (2, 1, 0, 1), (2, 1, 0, 2), (2, 2, 0, 1), (2, 2, 0, 2), // ┴ … ┻
        (1, 1, 1, 1), (1, 1, 1, 2), (1, 2, 1, 1), (1, 2, 1, 2), (2, 1, 1, 1), (1, 1, 2, 1), (2, 1, 2, 1), (2, 1, 1, 2), // ┼ … ╃
        (2, 2, 1, 1), (1, 1, 2, 2), (1, 2, 2, 1), (2, 2, 1, 2), (1, 2, 2, 2), (2, 1, 2, 2), (2, 2, 2, 1), (2, 2, 2, 2), // ╄ … ╋
    ]

    /// ┄ ┅ ┆ ┇ ┈ ┉ ┊ ┋.
    private static func boxDashes(_ scalar: UInt32) -> (count: Int, vertical: Bool, heavy: Bool)? {
        guard (0x2504...0x250B).contains(scalar) else { return nil }
        let i = Int(scalar - 0x2504)
        return (i < 4 ? 3 : 4, (i / 2) % 2 == 1, i % 2 == 1)
    }

    /// Arms from the cell's middle to its edges, meeting in a square at the middle.
    private func lines(_ arms: (UInt8, UInt8, UInt8, UInt8), left: Float, top: Float, width: Float, height: Float, line: Float,
                       rect: (Float, Float, Float, Float, Float) -> Void) {
        func thickness(_ weight: UInt8) -> Float { weight == 0 ? 0 : weight == 1 ? line : line * 2 }
        let (up, right, down, leftArm) = arms
        let vertical = max(thickness(up), thickness(down)), horizontal = max(thickness(right), thickness(leftArm))
        let cx = (left + width / 2).rounded(), cy = (top + height / 2).rounded()
        if leftArm > 0 { let t = thickness(leftArm); rect(left, cy - t / 2, cx + max(vertical, t) / 2, cy + t / 2, 1) }
        if right > 0 { let t = thickness(right); rect(cx - max(vertical, t) / 2, cy - t / 2, left + width, cy + t / 2, 1) }
        if up > 0 { let t = thickness(up); rect(cx - t / 2, top, cx + t / 2, cy + max(horizontal, t) / 2, 1) }
        if down > 0 { let t = thickness(down); rect(cx - t / 2, cy - max(horizontal, t) / 2, cx + t / 2, top + height, 1) }
    }

    /// ╭ ╮ ╯ ╰: a quarter circle joining two arms, its radius half the cell's width.
    private func roundedCorner(_ scalar: UInt32, left: Float, top: Float, width: Float, height: Float, line: Float,
                               rect: (Float, Float, Float, Float, Float) -> Void) {
        let cx = (left + width / 2).rounded(), cy = (top + height / 2).rounded()
        let radius = min(width, height) / 2
        // Which way the arms go from the corner: right or left, down or up.
        let toRight = scalar == 0x256D || scalar == 0x2570, toBottom = scalar == 0x256D || scalar == 0x256E
        let arcX = toRight ? cx + radius : cx - radius, arcY = toBottom ? cy + radius : cy - radius
        // The straight parts: from the arc to the cell's edges.
        if toRight { rect(arcX, cy - line / 2, left + width, cy + line / 2, 1) } else { rect(left, cy - line / 2, arcX, cy + line / 2, 1) }
        if toBottom { rect(cx - line / 2, arcY, cx + line / 2, top + height, 1) } else { rect(cx - line / 2, top, cx + line / 2, arcY, 1) }
        // The arc, sampled finely enough to be continuous at this thickness.
        let steps = max(8, Int(radius * 3))
        for i in 0...steps {
            let angle = Float(i) / Float(steps) * .pi / 2
            let x = arcX + (toRight ? -1 : 1) * radius * cos(angle)
            let y = arcY + (toBottom ? -1 : 1) * radius * sin(angle)
            rect(x - line / 2, y - line / 2, x + line / 2, y + line / 2, 1)
        }
    }

    /// ▀ through ▟: eighths, halves, quadrants and the three shades.
    private func block(_ scalar: UInt32, left: Float, top: Float, right: Float, bottom: Float, rect: (Float, Float, Float, Float, Float) -> Void) {
        let w = right - left, h = bottom - top, mx = left + w / 2, my = top + h / 2
        switch scalar {
        case 0x2580: rect(left, top, right, my, 1)
        case 0x2581...0x2588: rect(left, bottom - h * Float(scalar - 0x2580) / 8, right, bottom, 1)
        case 0x2589...0x258F: rect(left, top, left + w * Float(0x2590 - scalar) / 8, bottom, 1)
        case 0x2590: rect(mx, top, right, bottom, 1)
        case 0x2591...0x2593: rect(left, top, right, bottom, Float(scalar - 0x2590) / 4)
        case 0x2594: rect(left, top, right, top + h / 8, 1)
        case 0x2595: rect(right - w / 8, top, right, bottom, 1)
        default:
            // Quadrants: upper left, upper right, lower left, lower right.
            let quadrants: [UInt32: (Bool, Bool, Bool, Bool)] = [
                0x2596: (false, false, true, false), 0x2597: (false, false, false, true), 0x2598: (true, false, false, false),
                0x2599: (true, false, true, true), 0x259A: (true, false, false, true), 0x259B: (true, true, true, false),
                0x259C: (true, true, false, true), 0x259D: (false, true, false, false), 0x259E: (false, true, true, false),
                0x259F: (false, true, true, true),
            ]
            guard let (ul, ur, ll, lr) = quadrants[scalar] else { return }
            if ul { rect(left, top, mx, my, 1) }
            if ur { rect(mx, top, right, my, 1) }
            if ll { rect(left, my, mx, bottom, 1) }
            if lr { rect(mx, my, right, bottom, 1) }
        }
    }
}
