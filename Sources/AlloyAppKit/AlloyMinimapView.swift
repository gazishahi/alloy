import AlloyCore
import AlloyRender
import AppKit

/// The document drawn small beside the editor: each line a bar per colored span, two points
/// tall, the part on screen marked, and marks for find matches. Click or drag to scroll there.
/// Long documents scroll the minimap with the editor, so it's always the stretch around what's
/// on screen; only the lines in the minimap's own view are drawn.
@MainActor
public final class AlloyMinimapView: NSView {
    public static let width: CGFloat = 96
    weak var editor: AlloyEditorView?
    public var backgroundColor = NSColor.textBackgroundColor { didSet { needsDisplay = true } }
    /// The mark over the part of the document on screen.
    public var viewportColor = NSColor.labelColor.withAlphaComponent(0.08) { didSet { layoutTiles() } }
    /// Points per line, and per character across.
    static let lineHeight: CGFloat = 2
    static let characterWidth: CGFloat = 1
    static let inset: CGFloat = 6

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }

    /// The minimap's first line at the top of its view: the document's share scrolled, scaled.
    func firstLine(editor: AlloyEditorView) -> Int {
        let lines = editor.buffer.text.lineCount
        let shown = Int(bounds.height / Self.lineHeight)
        guard lines > shown else { return 0 }
        let layout = editor.documentLayout
        let scrollable = max(1, layout.contentHeight - editor.viewport.height)
        let fraction = min(1, max(0, editor.scrollY / scrollable))
        return Int((CGFloat(lines - shown) * fraction).rounded())
    }

    public override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
    }

    // MARK: Tiles

    /// The lines are drawn in tiles that scrolling only moves, and the mark over what's on
    /// screen is a layer of its own: drawing every line the minimap shows on every frame of a
    /// scroll (about 470 at full screen, each copied out, colored, and searched character by
    /// character) was 70% of the main thread scrolling a TSX file, and more the taller the
    /// window (2026-10-01, the owner's Khidma files).
    static let tileLines = 64

    private final class Tile: CALayer {
        var index = 0
    }

    @MainActor private final class TileDrawer: NSObject, @preconcurrency CALayerDelegate {
        weak var minimap: AlloyMinimapView?
        func draw(_ layer: CALayer, in context: CGContext) {
            guard let tile = layer as? Tile else { return }
            minimap?.drawTile(tile, in: context)
        }
        func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
    }

    private let drawer = TileDrawer()
    private var tiles: [Int: Tile] = [:]
    private var spareTiles: [Tile] = []
    private let viewportMark: CALayer = {
        let layer = CALayer()
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        layer.zPosition = 1
        return layer
    }()

    // Layer-backed from the start (see AlloyGutterView: turning it on later recursed).
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    /// What it shows changed (the text, its colors, the marks, the theme): every tile again.
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

    // Tiles aren't laid out while hidden.
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        layoutTiles()
    }

    /// Follows a scroll: tiles and the mark move; only tiles coming into view are drawn.
    public func scrolled() { layoutTiles() }

    func layoutTiles() {
        guard let editor, let host = layer, !isHiddenOrHasHiddenAncestor else { return }
        drawer.minimap = self
        let first = firstLine(editor: editor)
        let shown = Int(bounds.height / Self.lineHeight) + 1
        let lineCount = editor.buffer.text.lineCount
        let lowest = first / Self.tileLines
        let highest = max(lowest, min(lineCount - 1, first + shown) / Self.tileLines)
        for (index, tile) in tiles where index < lowest || index > highest {
            tile.isHidden = true
            spareTiles.append(tile)
            tiles[index] = nil
        }
        let scale = window?.backingScaleFactor ?? 2
        let height = CGFloat(Self.tileLines) * Self.lineHeight
        for index in lowest...highest {
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
            let frame = CGRect(x: 0, y: CGFloat(index * Self.tileLines - first) * Self.lineHeight, width: bounds.width, height: height)
            if tile.frame != frame {
                if tile.frame.width != frame.width { tile.setNeedsDisplay() }
                tile.frame = frame
            }
        }
        // The part on screen.
        if viewportMark.superlayer !== host { host.addSublayer(viewportMark) }
        let layout = editor.documentLayout
        let viewport = editor.viewport
        let top = layout.line(atY: viewport.minY).line, bottom = layout.line(atY: viewport.maxY).line
        viewportMark.frame = CGRect(x: 0, y: CGFloat(top - first) * Self.lineHeight, width: bounds.width, height: CGFloat(max(1, bottom - top + 1)) * Self.lineHeight)
        viewportMark.backgroundColor = viewportColor.cgColor
    }

    private func drawTile(_ tile: Tile, in context: CGContext) {
        guard let editor else { return }
        let text = editor.buffer.text
        let firstLine = tile.index * Self.tileLines
        let lastLine = min(text.lineCount - 1, firstLine + Self.tileLines - 1)
        guard firstLine <= lastLine else { return }
        // The tile's colors in one query, not one a line.
        editor.prepareStyles?(firstLine..<(lastLine + 1))
        let plain = editor.theme.text
        let maxColumns = Int((bounds.width - Self.inset * 2) / Self.characterWidth)
        var lineStart = text.offset(ofLine: firstLine)
        for line in firstLine...lastLine {
            let y = CGFloat(line - firstLine) * Self.lineHeight
            let lineEnd = line + 1 < text.lineCount ? text.offset(ofLine: line + 1) - 1 : text.utf16Count
            defer { lineStart = lineEnd + 1 }
            guard lineEnd > lineStart else { continue }
            let utf16 = text.substring(lineStart..<min(lineEnd, lineStart + maxColumns * 2)).utf16
            let spans = editor.styles?(line) ?? []
            // Runs of non-space characters, each in its span's color; spans are in order.
            var column = 0, runStart = -1, runColor = plain, spanIndex = 0
            func flush(_ end: Int) {
                guard runStart >= 0, runStart < maxColumns else { runStart = -1; return }
                let width = CGFloat(min(end, maxColumns) - runStart) * Self.characterWidth
                context.setFillColor(red: CGFloat(runColor.x), green: CGFloat(runColor.y), blue: CGFloat(runColor.z), alpha: CGFloat(runColor.w) * 0.55)
                context.fill(CGRect(x: Self.inset + CGFloat(runStart) * Self.characterWidth, y: y, width: width, height: Self.lineHeight - 0.5))
                runStart = -1
            }
            var index = 0
            for unit in utf16 {
                defer { index += 1 }
                if unit == 0x09 { flush(column); column += 4 - column % 4; continue }
                if unit == 0x20 { flush(column); column += 1; continue }
                while spanIndex < spans.count, spans[spanIndex].range.upperBound <= index { spanIndex += 1 }
                let spanColor = spanIndex < spans.count && spans[spanIndex].range.contains(index) ? spans[spanIndex].color : plain
                if runStart >= 0, spanColor != runColor { flush(column) }
                if runStart < 0 { runStart = column; runColor = spanColor }
                column += 1
                if column >= maxColumns { break }
            }
            flush(column)
        }
        // Find matches and other background marks: a mark at the right edge, so a file with many
        // doesn't turn to stripes.
        let tileRange = text.offset(ofLine: firstLine)..<(lastLine + 1 < text.lineCount ? text.offset(ofLine: lastLine + 1) : text.utf16Count + 1)
        for decoration in editor.decorations where decoration.style == .background && tileRange.contains(decoration.range.lowerBound) {
            let line = text.line(containing: decoration.range.lowerBound)
            let c = decoration.color
            context.setFillColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            context.fill(CGRect(x: bounds.width - 5, y: CGFloat(line - firstLine) * Self.lineHeight - 0.5, width: 4, height: Self.lineHeight + 1))
        }
    }

    // MARK: Scrolling from here

    private var dragOffset: CGFloat?

    public override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let first = firstLine(editor: editor)
        let layout = editor.documentLayout
        let top = CGFloat(layout.line(atY: editor.viewport.minY).line - first) * Self.lineHeight
        let height = CGFloat(max(1, layout.line(atY: editor.viewport.maxY).line - layout.line(atY: editor.viewport.minY).line + 1)) * Self.lineHeight
        if point.y >= top, point.y <= top + height {
            // On the viewport mark: drag it.
            dragOffset = point.y - top
        } else {
            // Elsewhere: that line to the middle of the screen, then drag from there.
            dragOffset = height / 2
            scroll(toMinimapY: point.y - height / 2, first: first)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let editor, let offset = dragOffset else { return }
        let point = convert(event.locationInWindow, from: nil)
        scroll(toMinimapY: point.y - offset, first: firstLine(editor: editor))
    }

    public override func mouseUp(with event: NSEvent) { dragOffset = nil }

    private func scroll(toMinimapY y: CGFloat, first: Int) {
        guard let editor else { return }
        let line = max(0, min(editor.buffer.text.lineCount - 1, first + Int(y / Self.lineHeight)))
        let layout = editor.documentLayout
        let limit = max(0, layout.contentHeight - editor.viewport.height)
        editor.scrollY = min(limit, layout.y(ofLine: line))
    }

    public override func scrollWheel(with event: NSEvent) { editor?.scrollView.scrollWheel(with: event) }

    // A picture of the document; the text itself is what VoiceOver reads.
    public override func isAccessibilityElement() -> Bool { false }
}
