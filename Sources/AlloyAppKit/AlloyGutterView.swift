import AlloyCore
import AlloyRender
import AppKit

/// A mark in the gutter beside a line: a change bar (added, modified), a notch between lines
/// (removed), a dot (a diagnostic), or a breakpoint: a tag behind the line number, hollow when
/// the debugger couldn't place it, faint when it's disabled.
public struct GutterMark: Equatable {
    public enum Style: Equatable { case bar, notch, dot, breakpoint(enabled: Bool, verified: Bool) }
    public var style: Style
    public var color: NSColor
    public init(style: Style, color: NSColor) {
        self.style = style
        self.color = color
    }
}

/// Line numbers and marks, beside the editor and scrolled with it. Lines are one-based here,
/// as people (and Make's diff and diagnostics code) count them.
@MainActor
public final class AlloyGutterView: NSView {
    /// Room for five-digit numbers beside the fold column.
    public static let width: CGFloat = 54
    weak var editor: AlloyEditorView?
    public var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) { didSet { numbers.removeAll(); labels.removeAll(); needsDisplay = true } }
    public var numberColor = NSColor.tertiaryLabelColor { didSet { needsDisplay = true } }
    public var backgroundColor = NSColor.textBackgroundColor { didSet { needsDisplay = true } }
    /// Marks by one-based line.
    public var marks: [Int: [GutterMark]] = [:] { didSet { needsDisplay = true } }
    /// A click on a line (one-based) that has marks, left of the numbers (a change bar, a dot).
    public var onClick: ((Int, NSEvent) -> Void)?
    /// A click on a line's number (one-based): where a breakpoint is set, as in Xcode. A
    /// right-click (or ⌃-click) comes here too; `event.type` tells them apart.
    public var onNumberClick: ((Int, NSEvent) -> Void)?
    /// Where the numbers start: left of this is the marks' column.
    static let marksColumn: CGFloat = 15
    /// What the gutter shows for a line (zero-based) in place of its number; nil shows nothing
    /// (a diff's old and new numbers, blank beside a file's header).
    public var label: ((Int) -> String?)? { didSet { labels.removeAll(); needsDisplay = true } }
    private var labels: [String: (line: CTLine, width: CGFloat)] = [:]

    public override var isFlipped: Bool { true }

    /// Room at the right edge for the fold arrows, when the editor folds.
    static let foldColumn: CGFloat = 14
    private var showsFoldColumn: Bool { editor?.isFoldingEnabled == true && label == nil }
    /// Open regions' arrows show while the pointer is over the gutter; folded ones always.
    private var isPointerInside = false { didSet { if isPointerInside != oldValue { needsDisplay = true } } }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    public override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    public override func mouseExited(with event: NSEvent) { isPointerInside = false }

    private func drawFoldArrow(folded: Bool, rowTop: CGFloat, lineHeight: CGFloat) {
        let size: CGFloat = 4
        let centerX = bounds.width - Self.foldColumn / 2 - 1
        let centerY = rowTop + lineHeight / 2
        let path = NSBezierPath()
        if folded {
            path.move(to: NSPoint(x: centerX - size / 2, y: centerY - size))
            path.line(to: NSPoint(x: centerX + size / 2, y: centerY))
            path.line(to: NSPoint(x: centerX - size / 2, y: centerY + size))
        } else {
            path.move(to: NSPoint(x: centerX - size, y: centerY - size / 2))
            path.line(to: NSPoint(x: centerX, y: centerY + size / 2))
            path.line(to: NSPoint(x: centerX + size, y: centerY - size / 2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (folded ? NSColor.secondaryLabelColor : numberColor).setStroke()
        path.stroke()
    }

    /// Each line number, shaped once: drawing them as strings (measure, then draw) cost ~1.5 ms
    /// a frame while scrolling, more than the text itself.
    private var numbers: [Int: (line: CTLine, width: CGFloat)] = [:]

    private func shape(_ text: String) -> (line: CTLine, width: CGFloat) {
        if let cached = labels[text] { return cached }
        if labels.count > 600 { labels.removeAll() }
        let string = NSAttributedString(string: text, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let line = CTLineCreateWithAttributedString(string)
        let entry = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        labels[text] = entry
        return entry
    }

    private func number(_ value: Int) -> (line: CTLine, width: CGFloat) {
        if let cached = numbers[value] { return cached }
        if numbers.count > 600 { numbers.removeAll() }
        // The color comes from the context, so an appearance change needs no reshaping.
        let string = NSAttributedString(string: "\(value)", attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let line = CTLineCreateWithAttributedString(string)
        let entry = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        numbers[value] = entry
        return entry
    }

    public override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
    }

    // MARK: Tiles

    /// The numbers and marks are drawn in tiles of the document, which scrolling only moves:
    /// redrawing the whole gutter every frame of a scroll was most of what Core Animation
    /// committed (2026-10-01, a third of a scrolling frame). A tile is drawn when it comes into
    /// view and when what it shows changes (`needsDisplay`, as before).
    static let tileHeight: CGFloat = 512

    /// A tile is a plain layer, not a view: AppKit redraws a layer-backed view whose visible
    /// part changes, which a tile moving under the gutter's edge does every frame.
    private final class Tile: CALayer {
        var index = 0
        /// The first and last lines it drew and where they were: when rows are measured and the
        /// document's height changes, only a tile whose lines moved draws again.
        var drawn: (first: Int, firstY: CGFloat, last: Int, lastY: CGFloat)?
    }

    /// Draws a tile's layer through the gutter (a view can't be another layer's delegate).
    // Layers display on the main thread, from Core Animation's commit.
    @MainActor private final class TileDrawer: NSObject, @preconcurrency CALayerDelegate {
        weak var gutter: AlloyGutterView?
        func draw(_ layer: CALayer, in context: CGContext) {
            guard let tile = layer as? Tile else { return }
            gutter?.drawTile(tile, in: context)
        }
        // No animation when a tile moves or is shown.
        func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
    }

    private let drawer = TileDrawer()
    private var tiles: [Int: Tile] = [:]
    private var spareTiles: [Tile] = []
    /// The document's height when the tiles were last drawn: rows are measured as lines are
    /// first drawn (a wrapped line takes more than one), which moves every line after them.
    private var drawnContentHeight: CGFloat = -1

    // Layer-backed from the start: turning it on later marks the view as needing display,
    // which lays out the tiles, which turned it on again (a gutter outside a window has no
    // layer yet: Review's diff view, 2026-10-01, a stack overflow).
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    public override var needsDisplay: Bool {
        didSet {
            guard needsDisplay else { return }
            for tile in tiles.values { tile.setNeedsDisplay() }
            layoutTiles()
        }
    }

    public override func layout() {
        super.layout()
        layoutTiles()
    }

    /// Places the tiles the viewport (and half a screen either side) needs, drawing only new ones.
    func layoutTiles() {
        guard let editor, let host = layer else { return }
        let viewport = editor.drawingRect
        let top = editor.scrollView.convert(editor.scrollView.contentView.frame.origin, to: self).y
        let margin = viewport.height / 2
        let layout = editor.documentLayout
        let height = layout.contentHeight
        if height != drawnContentHeight {
            drawnContentHeight = height
            for tile in tiles.values {
                guard let drawn = tile.drawn else { continue }
                if layout.y(ofLine: drawn.first) != drawn.firstY || layout.y(ofLine: drawn.last) != drawn.lastY { tile.setNeedsDisplay() }
            }
        }
        let first = max(0, Int(floor((viewport.minY - margin) / Self.tileHeight)))
        let last = max(first, Int(floor((viewport.maxY + margin) / Self.tileHeight)))
        for (index, tile) in tiles where index < first || index > last {
            tile.isHidden = true
            spareTiles.append(tile)
            tiles[index] = nil
        }
        let scale = window?.backingScaleFactor ?? 2
        drawer.gutter = self
        for index in first...last {
            let tile: Tile
            if let placed = tiles[index] {
                tile = placed
            } else {
                tile = spareTiles.popLast() ?? {
                    let made = Tile()
                    made.delegate = drawer
                    made.isOpaque = false
                    host.addSublayer(made)
                    return made
                }()
                tile.index = index
                tile.isHidden = false
                tile.setNeedsDisplay()
                tiles[index] = tile
            }
            if tile.contentsScale != scale { tile.contentsScale = scale; tile.setNeedsDisplay() }
            // On a device pixel, so the numbers stay sharp at rest. The host layer's geometry
            // is the view's (flipped), as AppKit sets it up.
            let y = ((top + CGFloat(index) * Self.tileHeight - viewport.minY) * scale).rounded() / scale
            let frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.tileHeight)
            if tile.frame != frame {
                if tile.frame.width != frame.width { tile.setNeedsDisplay() }
                tile.frame = frame
            }
        }
    }

    /// Follows a scroll: tiles move; only the ones coming into view are drawn.
    public func scrolled() { layoutTiles() }

    private func drawTile(_ tile: Tile, in context: CGContext) {
        guard let editor else { return }
        let layout = editor.documentLayout
        let docTop = CGFloat(tile.index) * Self.tileHeight
        // Already top-down: the gutter's layer geometry is flipped, as its view is.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setFillColor(numberColor.cgColor)
        let lines = layout.visibleLines(from: docTop, to: docTop + Self.tileHeight)
        if let first = lines.first, let last = lines.last {
            tile.drawn = (first.line, layout.y(ofLine: first.line), last.line, layout.y(ofLine: last.line))
        }
        for (line, y, laid) in lines {
            let rowTop = y - docTop
            let lineHeight = layout.lineHeight
            let height = CGFloat(laid.rows.count) * lineHeight
            // On the text's baseline (row top + the text font's ascent), right-aligned.
            if let label {
                if let text = label(line), !text.isEmpty {
                    let (shaped, width) = shape(text)
                    context.textPosition = CGPoint(x: bounds.width - width - 8, y: rowTop + layout.ascent)
                    CTLineDraw(shaped, context)
                }
            } else {
                let (shaped, width) = number(line + 1)
                let right = showsFoldColumn ? Self.foldColumn + 2 : 8
                // A breakpoint's tag goes behind the number, which reads white on it.
                if let breakpoint = (marks[line + 1] ?? []).first(where: { if case .breakpoint = $0.style { return true } else { return false } }),
                   case .breakpoint(let enabled, let verified) = breakpoint.style {
                    let tag = NSRect(x: Self.marksColumn, y: rowTop + 1, width: bounds.width - right + 4 - Self.marksColumn, height: lineHeight - 2)
                    let path = Self.tagPath(tag)
                    let color = enabled ? breakpoint.color : breakpoint.color.withAlphaComponent(0.35)
                    if verified { color.setFill(); path.fill() } else { color.setStroke(); path.lineWidth = 1.5; path.stroke() }
                    context.setFillColor(verified ? NSColor.white.cgColor : numberColor.cgColor)
                }
                context.textPosition = CGPoint(x: bounds.width - width - right, y: rowTop + layout.ascent)
                CTLineDraw(shaped, context)
                context.setFillColor(numberColor.cgColor)
            }
            if showsFoldColumn, editor.foldRegion(headedBy: line) != nil {
                let folded = editor.isFolded(line: line)
                if folded || isPointerInside { drawFoldArrow(folded: folded, rowTop: rowTop, lineHeight: lineHeight) }
            }
            for mark in marks[line + 1] ?? [] {
                mark.color.setFill()
                switch mark.style {
                case .bar: NSRect(x: 0, y: rowTop, width: 3, height: height).fill()
                case .notch: NSRect(x: 0, y: rowTop - 1, width: 3, height: 3).fill()
                case .dot:
                    let size: CGFloat = 6
                    NSBezierPath(ovalIn: NSRect(x: 7, y: rowTop + (lineHeight - size) / 2, width: size, height: size)).fill()
                case .breakpoint:
                    break   // drawn with the number
                }
            }
            context.setFillColor(numberColor.cgColor)
        }
        context.restoreGState()
    }


    /// Xcode's breakpoint shape: a rounded rectangle whose right end points at the text.
    static func tagPath(_ rect: NSRect) -> NSBezierPath {
        let point = min(6, rect.height / 2)
        let radius: CGFloat = 2.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - point, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX - point, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }

    /// The one-based line under a point in the gutter.
    public func line(at point: CGPoint) -> Int? {
        guard let editor else { return nil }
        let top = editor.scrollView.convert(editor.scrollView.contentView.frame.origin, to: self).y
        let documentY = editor.drawingRect.minY + (point.y - top)
        return editor.documentLayout.line(atY: documentY).line + 1
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let line = line(at: point) else { return }
        // The fold column, on a line that heads a region: fold or unfold it.
        if showsFoldColumn, point.x >= bounds.width - Self.foldColumn - 4, let editor, editor.foldRegion(headedBy: line - 1) != nil {
            editor.toggleFold(line: line - 1)
            return
        }
        // On the numbers: the owner's (a breakpoint). Left of them: the marks' own click.
        if point.x >= Self.marksColumn, let onNumberClick {
            onNumberClick(line, event)
            return
        }
        guard marks[line] != nil else { return }
        onClick?(line, event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let onNumberClick, let line = line(at: point) else { return super.rightMouseDown(with: event) }
        onNumberClick(line, event)
    }
}
