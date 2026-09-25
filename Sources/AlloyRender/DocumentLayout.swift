import AlloyCore
import CoreGraphics
import CoreText
import Foundation

/// One glyph run of a laid-out row: a font (CoreText may fall back per run, for emoji or CJK),
/// its glyphs, where they sit, and which UTF-16 offsets of the line they came from.
public struct GlyphRun {
    public let font: CTFont
    public let glyphs: [CGGlyph]
    /// Baseline-relative, in points, from the row's start.
    public let positions: [CGPoint]
    /// UTF-16 offset in the line for each glyph.
    public let indices: [Int]
    /// Apple Color Emoji and friends: drawn in their own colors, not the text color.
    public let isColor: Bool
}

/// A visual row: all of a line, or one wrapped piece of it.
public struct LayoutRow {
    /// UTF-16 range within the line.
    public let range: Range<Int>
    public let line: CTLine
    public let runs: [GlyphRun]
    public let width: CGFloat
}

/// A line laid out by CoreText, split into rows at the wrap width.
public final class LaidOutLine {
    public let text: String
    public let rows: [LayoutRow]

    init(text: String, font: CTFont, tabWidth: CGFloat, wrapWidth: CGFloat?) {
        self.text = text
        let attributes = Self.attributes(font: font, tabWidth: tabWidth)
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = text.utf16.count
        var rows: [LayoutRow] = []
        var start = 0
        repeat {
            let count: Int
            if let wrapWidth, length > 0 {
                count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(wrapWidth)))
            } else {
                count = length - start
            }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            rows.append(LayoutRow(range: start..<(start + count), line: line, runs: Self.runs(of: line, rowStart: start),
                                  width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
            start += count
        } while start < length
        self.rows = rows
    }

    static func attributes(font: CTFont, tabWidth: CGFloat) -> [NSAttributedString.Key: Any] {
        var interval = tabWidth
        let paragraph = withUnsafeBytes(of: &interval) { bytes -> CTParagraphStyle in
            var settings = [CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: bytes.baseAddress!)]
            // No fixed tab stops: every tab goes to the next multiple of the interval.
            let empty = [CTTextTab]() as CFArray
            return withUnsafeBytes(of: empty) { tabBytes in
                settings.append(CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: tabBytes.baseAddress!))
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        return [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph]
    }

    private static func runs(of line: CTLine, rowStart: Int) -> [GlyphRun] {
        let ctRuns = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        return ctRuns.map { run in
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName as String] as! CTFont
            let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
            // Positions are relative to the whole line's start; make them relative to this row.
            let rowOffset = positions.first.map { _ in CGFloat(CTLineGetOffsetForStringIndex(line, rowStart, nil)) } ?? 0
            return GlyphRun(font: font, glyphs: glyphs, positions: positions.map { CGPoint(x: $0.x - rowOffset, y: $0.y) },
                            indices: indices.map { Int($0) }, isColor: isColor)
        }
    }

    /// The row holding a UTF-16 offset within the line (the end of a wrapped row belongs to
    /// the next one, except at the very end).
    public func row(containing offset: Int) -> Int {
        for (index, row) in rows.enumerated() where offset < row.range.upperBound { return index }
        return rows.count - 1
    }

    /// The x of a caret before the UTF-16 offset, within its row.
    public func caretX(at offset: Int) -> (row: Int, x: CGFloat) {
        let row = row(containing: offset)
        let layout = rows[row]
        let start = CTLineGetOffsetForStringIndex(layout.line, layout.range.lowerBound, nil)
        return (row, CGFloat(CTLineGetOffsetForStringIndex(layout.line, offset, nil) - start))
    }

    /// The UTF-16 offset nearest an x in a row.
    public func offset(row: Int, x: CGFloat) -> Int {
        let layout = rows[max(0, min(row, rows.count - 1))]
        let start = CTLineGetOffsetForStringIndex(layout.line, layout.range.lowerBound, nil)
        let index = CTLineGetStringIndexForPosition(layout.line, CGPoint(x: x + start, y: 0))
        guard index != kCFNotFound else { return layout.range.lowerBound }
        // A wrapped row's last position belongs to the next row, except on the last row.
        let upper = row == rows.count - 1 ? layout.range.upperBound : max(layout.range.lowerBound, layout.range.upperBound - 1)
        return min(max(index, layout.range.lowerBound), upper)
    }
}

/// Where everything in a document sits: rows, lines, carets and hit tests, for a font and a
/// wrap width. Lays out only what's asked for (what's on screen), caching by line text, so a
/// file's size costs memory for its text, not its layout.
@MainActor
public final class DocumentLayout {
    public private(set) var text: Rope
    public let font: CTFont
    public let lineHeight: CGFloat
    public let ascent: CGFloat
    public let tabWidth: CGFloat
    /// Space around the text, in points.
    public var insets = CGSize(width: 16, height: 12)
    /// nil: no wrapping.
    public private(set) var wrapWidth: CGFloat?

    private var rowIndex: RowIndex
    private var cache: [String: LaidOutLine] = [:]
    private var cacheOrder: [String] = []
    static let cacheLimit = 1_000

    public init(text: Rope, font: CTFont, tabSize: Int = 4) {
        self.text = text
        self.font = font
        ascent = ceil(CTFontGetAscent(font))
        lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + max(CTFontGetLeading(font), CTFontGetSize(font) * 0.25))
        var space: CGGlyph = 0
        var character: UniChar = 0x20
        CTFontGetGlyphsForCharacters(font, &character, &space, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &space, &advance, 1)
        tabWidth = advance.width * CGFloat(tabSize)
        rowIndex = RowIndex(lineCount: text.lineCount)
    }

    /// Follows an edit. Rows of the lines it touched are re-measured when next drawn.
    public func update(_ newText: Rope, edits: [AppliedEdit]) {
        var working = text
        for edit in edits {
            let firstLine = working.line(containing: edit.range.lowerBound)
            let lastLine = working.line(containing: edit.range.upperBound)
            var newLines = 0
            for unit in edit.newText.utf16 where unit == 0x0A { newLines += 1 }
            rowIndex.replaceLines(start: firstLine, oldCount: lastLine - firstLine + 1, newCount: newLines + 1)
            working.replace(edit.range, with: edit.newText)
        }
        text = newText
        if rowIndex.lineCount != text.lineCount { rowIndex = RowIndex(lineCount: text.lineCount) }
    }

    /// Replaces the text wholesale (a document swap).
    public func reset(_ newText: Rope) {
        text = newText
        rowIndex = RowIndex(lineCount: text.lineCount)
    }

    public func setWrapWidth(_ width: CGFloat?) {
        let rounded = width.map { max(40, floor($0)) }
        guard rounded != wrapWidth else { return }
        wrapWidth = rounded
        cache.removeAll()
        cacheOrder.removeAll()
        rowIndex = RowIndex(lineCount: text.lineCount)
    }

    public var lineCount: Int { text.lineCount }
    public var contentHeight: CGFloat { CGFloat(rowIndex.totalRows) * lineHeight + insets.height * 2 }

    /// A line's layout, measured now if it wasn't.
    public func layout(line: Int) -> LaidOutLine {
        let string = text.substring(text.range(ofLine: line))
        let laid: LaidOutLine
        if let cached = cache[string] {
            laid = cached
        } else {
            laid = LaidOutLine(text: string, font: font, tabWidth: tabWidth, wrapWidth: wrapWidth)
            cache[string] = laid
            cacheOrder.append(string)
            if cacheOrder.count > Self.cacheLimit {
                let evicted = cacheOrder.prefix(cacheOrder.count / 4)
                for key in evicted { cache.removeValue(forKey: key) }
                cacheOrder.removeFirst(evicted.count)
            }
        }
        rowIndex.set(line: line, rows: laid.rows.count)
        return laid
    }

    /// The y of a line's first row (top), in points, document coordinates.
    public func y(ofLine line: Int) -> CGFloat {
        insets.height + CGFloat(rowIndex.prefix(line)) * lineHeight
    }

    /// The line and row under a y.
    public func line(atY y: CGFloat) -> (line: Int, row: Int) {
        let row = Int(floor(max(0, y - insets.height) / lineHeight))
        let found = rowIndex.line(atRow: min(row, max(0, rowIndex.totalRows - 1)))
        return (found.line, found.rowInLine)
    }

    /// Lines that intersect a vertical span, with their tops, measured as they go (a line that
    /// turns out to wrap pushes the ones after it down, which the loop accounts for).
    public func visibleLines(from top: CGFloat, to bottom: CGFloat) -> [(line: Int, y: CGFloat, layout: LaidOutLine)] {
        var result: [(Int, CGFloat, LaidOutLine)] = []
        var line = line(atY: top).line
        while line < lineCount {
            let laid = layout(line: line)
            let y = y(ofLine: line)
            if y > bottom { break }
            result.append((line, y, laid))
            line += 1
        }
        return result
    }

    /// The caret's rectangle for a UTF-16 offset, in document points.
    public func caretRect(at offset: Int) -> CGRect {
        let clamped = max(0, min(offset, text.utf16Count))
        let line = text.line(containing: clamped)
        let laid = layout(line: line)
        let (row, x) = laid.caretX(at: clamped - text.offset(ofLine: line))
        return CGRect(x: insets.width + x, y: y(ofLine: line) + CGFloat(row) * lineHeight, width: 0, height: lineHeight)
    }

    /// The UTF-16 offset nearest a point, in document points.
    public func offset(at point: CGPoint) -> Int {
        let (line, row) = line(atY: point.y)
        let laid = layout(line: line)
        let rowInLine = min(row, laid.rows.count - 1)
        return text.offset(ofLine: line) + laid.offset(row: rowInLine, x: point.x - insets.width)
    }
}
