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
    public var viewportColor = NSColor.labelColor.withAlphaComponent(0.08) { didSet { needsDisplay = true } }
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
        guard let editor, let context = NSGraphicsContext.current?.cgContext else { return }
        let text = editor.buffer.text
        let first = firstLine(editor: editor)
        let last = min(text.lineCount - 1, first + Int(bounds.height / Self.lineHeight) + 1)
        guard first <= last else { return }
        let plain = editor.theme.text
        let maxColumns = Int((bounds.width - Self.inset * 2) / Self.characterWidth)
        for line in first...last {
            let y = CGFloat(line - first) * Self.lineHeight
            let lineText = text.substring(text.range(ofLine: line))
            let utf16 = Array(lineText.utf16)
            guard !utf16.isEmpty else { continue }
            let spans = editor.styles?(line) ?? []
            // Runs of non-space characters, each in its span's color.
            var column = 0, runStart = -1, runColor = plain
            func color(at index: Int) -> SIMD4<Float> { spans.last { $0.range.contains(index) }?.color ?? plain }
            func flush(_ end: Int) {
                guard runStart >= 0, runStart < maxColumns else { runStart = -1; return }
                let width = CGFloat(min(end, maxColumns) - runStart) * Self.characterWidth
                context.setFillColor(red: CGFloat(runColor.x), green: CGFloat(runColor.y), blue: CGFloat(runColor.z), alpha: CGFloat(runColor.w) * 0.55)
                context.fill(CGRect(x: Self.inset + CGFloat(runStart) * Self.characterWidth, y: y, width: width, height: Self.lineHeight - 0.5))
                runStart = -1
            }
            for (index, unit) in utf16.enumerated() {
                if unit == 0x09 { flush(column); column += 4 - column % 4; continue }
                if unit == 0x20 { flush(column); column += 1; continue }
                let spanColor = color(at: index)
                if runStart >= 0, spanColor != runColor { flush(column) }
                if runStart < 0 { runStart = column; runColor = spanColor }
                column += 1
                if column >= maxColumns { break }
            }
            flush(column)
        }
        // Find matches and other background marks: a mark at the right edge, so a file with many
        // doesn't turn to stripes.
        for decoration in editor.decorations where decoration.style == .background {
            let line = text.line(containing: decoration.range.lowerBound)
            guard line >= first, line <= last else { continue }
            let c = decoration.color
            context.setFillColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            context.fill(CGRect(x: bounds.width - 5, y: CGFloat(line - first) * Self.lineHeight - 0.5, width: 4, height: Self.lineHeight + 1))
        }
        // The part on screen.
        let layout = editor.documentLayout
        let viewport = editor.viewport
        let top = layout.line(atY: viewport.minY).line, bottom = layout.line(atY: viewport.maxY).line
        let rect = CGRect(x: 0, y: CGFloat(top - first) * Self.lineHeight, width: bounds.width, height: CGFloat(max(1, bottom - top + 1)) * Self.lineHeight)
        viewportColor.setFill()
        rect.fill()
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
