import AlloyCore
import AlloyRender
import AppKit

/// A mark in the gutter beside a line: a change bar (added, modified), a notch between lines
/// (removed), or a dot (a diagnostic).
public struct GutterMark: Equatable {
    public enum Style: Equatable { case bar, notch, dot }
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
    /// A click on a line (one-based) that has marks.
    public var onClick: ((Int, NSEvent) -> Void)?
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
        guard let editor else { return }
        let layout = editor.documentLayout
        // Every line the editor draws, insets included, so numbers flow under floating chrome
        // with their text. The clip view's top edge in the gutter's coordinates.
        let viewport = editor.drawingRect
        let top = editor.scrollView.convert(editor.scrollView.contentView.frame.origin, to: self).y
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setFillColor(numberColor.cgColor)
        for (line, y, laid) in layout.visibleLines(from: viewport.minY, to: viewport.maxY) {
            let rowTop = top + (y - viewport.minY)
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
                context.textPosition = CGPoint(x: bounds.width - width - right, y: rowTop + layout.ascent)
                CTLineDraw(shaped, context)
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
                }
            }
            context.setFillColor(numberColor.cgColor)
        }
        context.restoreGState()
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
        guard marks[line] != nil else { return }
        onClick?(line, event)
    }
}
