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
    /// Hidden markup (concealed): laid out at no width, not drawn.
    public var isConcealed = false
    /// The line's replacement this run stands for (its box), if any.
    public var replacement: Int?
}

/// A visual row: all of a line, or one wrapped piece of it.
public struct LayoutRow {
    /// UTF-16 range within the line.
    public let range: Range<Int>
    public let line: CTLine
    public let runs: [GlyphRun]
    public let width: CGFloat
}

/// A run of a line set in another font than the document's (bold, italic, code), by UTF-16
/// range within the line. Laid out before the line is measured, so it changes widths and wraps.
public struct FontSpan: Equatable {
    public let range: Range<Int>
    public let font: CTFont
    /// The font's name and size: what tells two runs apart.
    let key: String

    public init(range: Range<Int>, font: CTFont) {
        self.range = range
        self.font = font
        key = "\(CTFontCopyPostScriptName(font) as String)@\(CTFontGetSize(font))"
    }

    public static func == (a: FontSpan, b: FontSpan) -> Bool { a.range == b.range && a.key == b.key }
}

/// A range of a line drawn as an image instead of its text (a typeset formula): laid out as one
/// box its size on the baseline, `descent` below it. Where a selection touches the line, its
/// text shows instead.
public struct InlineReplacement: Equatable {
    public let range: Range<Int>
    /// Pixels at the screen's scale.
    public let image: CGImage
    /// In points.
    public let size: CGSize
    public let descent: CGFloat
    /// What it shows (two equal keys are the same image).
    public let key: String
    /// The image's own size when it's drawn smaller than its box, centered in it (a displayed
    /// formula centered in the column). Nil: the box's size.
    public var drawSize: CGSize?
    /// Shown on a line a selection touches too (a table's column padding, which keeps the
    /// columns lined up while a row is edited).
    public var persistent: Bool

    public init(range: Range<Int>, image: CGImage, size: CGSize, descent: CGFloat, key: String, drawSize: CGSize? = nil, persistent: Bool = false) {
        self.range = range
        self.image = image
        self.size = size
        self.descent = descent
        self.key = key
        self.drawSize = drawSize
        self.persistent = persistent
    }

    public static func == (a: InlineReplacement, b: InlineReplacement) -> Bool { a.range == b.range && a.key == b.key && a.size == b.size }
}

/// A line laid out by CoreText, split into rows at the wrap width.
public final class LaidOutLine {
    public let text: String
    public let rows: [LayoutRow]
    /// The font runs it was laid out with.
    public let fontSpans: [FontSpan]
    /// Each row's top below the line's top, its height, and its baseline below its own top, in
    /// whole points. One line height and the font's ascent each, unless the document's rows vary
    /// (prose: a heading's taller row).
    public private(set) var rowTops: [CGFloat] = []
    public private(set) var rowHeights: [CGFloat] = []
    public private(set) var rowBaselines: [CGFloat] = []
    /// The line's height: its rows'.
    public private(set) var height: CGFloat = 0

    /// A document's plain row: what every row is unless it varies.
    struct Metrics {
        let lineHeight: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        /// Rows take the height their fonts need (prose); otherwise every row is one line height.
        let varies: Bool
    }

    /// The ranges it hides (laid out at no width).
    public let concealed: [Range<Int>]
    /// The ranges it draws as images.
    public let replacements: [InlineReplacement]

    init(text: String, font: CTFont, tabWidth: CGFloat, wrapWidth: CGFloat?, fontSpans: [FontSpan] = [], concealed: [Range<Int>] = [],
         replacements: [InlineReplacement] = [], metrics: Metrics? = nil) {
        self.text = text
        self.fontSpans = fontSpans
        self.concealed = concealed
        self.replacements = replacements
        let attributes = Self.attributes(font: font, tabWidth: tabWidth)
        // A UTF-16 string, made once: from a Swift string (UTF-8 inside), CoreText's character
        // and offset reads were converted and copied again for each row of a wrapped line
        // (2026-10-01, Review's 12,000-character HTML lines: 40% of the main thread's work).
        let attributed = NSMutableAttributedString(string: NSMutableString(string: text) as String, attributes: attributes)
        let length = attributed.length
        for span in fontSpans where span.range.lowerBound < length && !span.range.isEmpty {
            let upper = min(span.range.upperBound, length)
            attributed.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: span.font,
                                    range: NSRange(location: span.range.lowerBound, length: upper - span.range.lowerBound))
        }
        for range in concealed where range.lowerBound < length && !range.isEmpty {
            let upper = min(range.upperBound, length)
            attributed.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: Self.nothing,
                                    range: NSRange(location: range.lowerBound, length: upper - range.lowerBound))
        }
        // A replacement: its first character is a box the image's size, the rest take no room.
        for (index, replacement) in replacements.enumerated() where replacement.range.lowerBound < length && !replacement.range.isEmpty {
            let upper = min(replacement.range.upperBound, length)
            let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
            attributed.addAttribute(delegateKey, value: Self.nothing, range: NSRange(location: replacement.range.lowerBound, length: upper - replacement.range.lowerBound))
            attributed.addAttribute(delegateKey, value: Self.box(width: replacement.size.width, ascent: replacement.size.height - replacement.descent, descent: replacement.descent),
                                    range: NSRange(location: replacement.range.lowerBound, length: 1))
            attributed.addAttribute(Self.replacementKey, value: index, range: NSRange(location: replacement.range.lowerBound, length: 1))
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
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
        let plain = metrics ?? Metrics(lineHeight: ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + max(CTFontGetLeading(font), CTFontGetSize(font) * 0.25)),
                                       ascent: ceil(CTFontGetAscent(font)), descent: ceil(CTFontGetDescent(font)), varies: false)
        var top: CGFloat = 0
        for row in rows {
            var rowHeight = plain.lineHeight, baseline = plain.ascent
            if plain.varies {
                // A row with a bigger font is taller by what it reaches past the plain row's
                // ascent and descent; a plain one stays exactly the plain height.
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                CTLineGetTypographicBounds(row.line, &ascent, &descent, &leading)
                let above = max(0, ceil(ascent) - plain.ascent), below = max(0, ceil(descent) - plain.descent)
                rowHeight += above + below
                baseline += above
            }
            rowTops.append(top)
            rowHeights.append(rowHeight)
            rowBaselines.append(baseline)
            top += rowHeight
        }
        height = top
    }

    /// The row a y within the line (from its top) falls in.
    public func row(atY y: CGFloat) -> Int {
        for index in rows.indices.reversed() where y >= rowTops[index] { return index }
        return 0
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

    static let replacementKey = NSAttributedString.Key("AlloyReplacement")

    private final class Box {
        let width: CGFloat, ascent: CGFloat, descent: CGFloat
        init(width: CGFloat, ascent: CGFloat, descent: CGFloat) { self.width = width; self.ascent = ascent; self.descent = descent }
    }

    /// A run delegate of a given size: the room a replacement's image takes.
    static func box(width: CGFloat, ascent: CGFloat, descent: CGFloat) -> CTRunDelegate {
        var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1,
                                               dealloc: { Unmanaged<Box>.fromOpaque($0).release() },
                                               getAscent: { Unmanaged<Box>.fromOpaque($0).takeUnretainedValue().ascent },
                                               getDescent: { Unmanaged<Box>.fromOpaque($0).takeUnretainedValue().descent },
                                               getWidth: { Unmanaged<Box>.fromOpaque($0).takeUnretainedValue().width })
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(Box(width: width, ascent: ascent, descent: descent)).toOpaque())!
    }

    /// A run delegate of no width, ascent or descent: what hidden markup is laid out as.
    nonisolated(unsafe) static let nothing: CTRunDelegate = {
        var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { _ in }, getAscent: { _ in 0 },
                                               getDescent: { _ in 0 }, getWidth: { _ in 0 })
        return CTRunDelegateCreate(&callbacks, nil)!
    }()

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
            var glyphRun = GlyphRun(font: font, glyphs: glyphs, positions: positions.map { CGPoint(x: $0.x - rowOffset, y: $0.y) },
                                    indices: indices.map { Int($0) }, isColor: isColor)
            glyphRun.replacement = (attributes[replacementKey.rawValue] as? NSNumber)?.intValue
            glyphRun.isConcealed = glyphRun.replacement == nil && attributes[kCTRunDelegateAttributeName as String] != nil
            return glyphRun
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
    public static let standardInsets = CGSize(width: 16, height: 12)
    public var insets = DocumentLayout.standardInsets
    /// nil: no wrapping.
    public private(set) var wrapWidth: CGFloat?

    private var rowIndex: RowIndex
    /// Folded regions' hidden lines, sorted and apart: each takes no rows, so it takes no space
    /// and nothing draws it. A fold's first line isn't in its range; it stays.
    public private(set) var hiddenLines: [ClosedRange<Int>] = []
    private var cache: [String: LaidOutLine] = [:]
    private var cacheOrder: [String] = []
    /// Each line's layout until the text, folds or wrap width change: a frame asks for every
    /// visible line (the text and the gutter both), and finding one by its text meant copying
    /// it out of the rope and hashing it every time (2026-10-01).
    private var byLine: [Int: LaidOutLine] = [:]
    static let cacheLimit = 1_000
    /// A line's font runs (prose set in a reading font: bold, italic, code), asked each time a
    /// line's layout is wanted; a line whose runs changed is laid out again. Nil: one font.
    /// Markup a line hides (ranges within it), and the lines that show theirs anyway (where the
    /// caret or a selection is). Nil: nothing hidden.
    public var concealment: ((Int) -> [Range<Int>])? { didSet { byLine.removeAll(keepingCapacity: true) } }
    /// Ranges a line draws as images (formulas), except where a selection touches it. Nil: none.
    public var replacements: ((Int) -> [InlineReplacement])? { didSet { byLine.removeAll(keepingCapacity: true) } }
    public var revealedLines: Set<Int> = [] {
        didSet {
            guard revealedLines != oldValue, concealment != nil || replacements != nil else { return }
            for line in revealedLines.symmetricDifference(oldValue) { byLine[line] = nil }
        }
    }

    public var fontSpans: ((Int) -> [FontSpan])? {
        didSet {
            guard (fontSpans == nil) != (oldValue == nil) || fontSpans != nil else { return }
            // Rows vary with runs and not without: every layout and height is stale.
            cache.removeAll()
            cacheOrder.removeAll()
            byLine.removeAll()
            rowIndex = RowIndex(lineCount: text.lineCount, unit: Int(lineHeight))
            hideFoldedRows()
        }
    }

    public init(text: Rope, font: CTFont, tabSize: Int = 4) {
        self.text = text
        self.font = font
        ascent = ceil(CTFontGetAscent(font))
        lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + max(CTFontGetLeading(font), CTFontGetSize(font) * 0.25))
        descent = ceil(CTFontGetDescent(font))
        var space: CGGlyph = 0
        var character: UniChar = 0x20
        CTFontGetGlyphsForCharacters(font, &character, &space, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &space, &advance, 1)
        tabWidth = advance.width * CGFloat(tabSize)
        rowIndex = RowIndex(lineCount: text.lineCount, unit: Int(lineHeight))
    }

    /// The font's descent, rounded up: a plain row's part below the baseline.
    public let descent: CGFloat
    /// What a row of `font` is, and whether rows vary (with font runs, a document's do).
    var metrics: LaidOutLine.Metrics { LaidOutLine.Metrics(lineHeight: lineHeight, ascent: ascent, descent: descent, varies: fontSpans != nil) }

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
            // A fold the edit touches (its lines, or the line it hangs from) opens; those after
            // it move with the lines.
            let delta = newLines - (lastLine - firstLine)
            hiddenLines = hiddenLines.compactMap { range in
                if range.upperBound < firstLine - 1 { return range }
                if range.lowerBound - 1 > lastLine { return (range.lowerBound + delta)...(range.upperBound + delta) }
                return nil
            }
        }
        text = newText
        byLine.removeAll(keepingCapacity: true)
        if rowIndex.lineCount != text.lineCount { rowIndex = RowIndex(lineCount: text.lineCount, unit: Int(lineHeight)) }
        hideFoldedRows()
    }

    /// Folds: the lines to hide, as ranges (merged, clipped to the document). Lines that were
    /// hidden and aren't now count as one row until they're drawn again.
    public func setHiddenLines(_ ranges: [ClosedRange<Int>]) {
        let last = max(0, text.lineCount - 1)
        var merged: [ClosedRange<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound <= last {
            let clipped = max(0, range.lowerBound)...min(last, range.upperBound)
            if let previous = merged.last, clipped.lowerBound <= previous.upperBound + 1 {
                merged[merged.count - 1] = previous.lowerBound...max(previous.upperBound, clipped.upperBound)
            } else {
                merged.append(clipped)
            }
        }
        for range in hiddenLines { for line in range where !Self.contains(merged, line) { rowIndex.set(line: line, rows: rowIndex.unit) } }
        hiddenLines = merged
        byLine.removeAll(keepingCapacity: true)
        hideFoldedRows()
    }

    private func hideFoldedRows() {
        for range in hiddenLines { for line in range { rowIndex.set(line: line, rows: 0) } }
    }

    /// The hidden range a line is in, if any (binary search).
    public func hiddenRange(containing line: Int) -> ClosedRange<Int>? {
        var low = 0, high = hiddenLines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = hiddenLines[mid]
            if line < range.lowerBound { high = mid - 1 } else if line > range.upperBound { low = mid + 1 } else { return range }
        }
        return nil
    }

    public func isHidden(line: Int) -> Bool { hiddenRange(containing: line) != nil }

    private static func contains(_ ranges: [ClosedRange<Int>], _ line: Int) -> Bool { ranges.contains { $0.contains(line) } }

    /// Replaces the text wholesale (a document swap).
    public func reset(_ newText: Rope) {
        text = newText
        rowIndex = RowIndex(lineCount: text.lineCount, unit: Int(lineHeight))
        hiddenLines = []
        byLine.removeAll(keepingCapacity: true)
    }

    public func setWrapWidth(_ width: CGFloat?) {
        let rounded = width.map { max(40, floor($0)) }
        guard rounded != wrapWidth else { return }
        wrapWidth = rounded
        cache.removeAll()
        cacheOrder.removeAll()
        byLine.removeAll()
        rowIndex = RowIndex(lineCount: text.lineCount, unit: Int(lineHeight))
        hideFoldedRows()
    }

    public var lineCount: Int { text.lineCount }
    public var contentHeight: CGFloat { CGFloat(rowIndex.totalRows) + insets.height * 2 }

    /// A line's layout, measured now if it wasn't.
    public func layout(line: Int) -> LaidOutLine {
        let spans = fontSpans?(line) ?? []
        let revealed = revealedLines.contains(line)
        let hidden = revealed ? [] : (concealment?(line) ?? [])
        let images = (replacements?(line) ?? []).filter { !revealed || $0.persistent }
        if let known = byLine[line], known.fontSpans == spans, known.concealed == hidden, known.replacements == images { return known }
        let string = text.substring(text.range(ofLine: line))
        // Equal lines share a layout only with equal runs.
        var key = string
        if !spans.isEmpty { key += "\u{0}" + spans.map { "\($0.range.lowerBound)-\($0.range.upperBound):\($0.key)" }.joined(separator: ",") }
        if fontSpans != nil { key += "\u{1}" }
        if !hidden.isEmpty { key += "\u{2}" + hidden.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",") }
        if !images.isEmpty { key += "\u{3}" + images.map { "\($0.range.lowerBound)-\($0.range.upperBound):\($0.key):\($0.size.width)x\($0.size.height)" }.joined(separator: ",") }
        let laid: LaidOutLine
        if let cached = cache[key] {
            laid = cached
        } else {
            laid = LaidOutLine(text: string, font: font, tabWidth: tabWidth, wrapWidth: wrapWidth, fontSpans: spans, concealed: hidden,
                               replacements: images, metrics: metrics)
            cache[key] = laid
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit {
                let evicted = cacheOrder.prefix(cacheOrder.count / 4)
                for key in evicted { cache.removeValue(forKey: key) }
                cacheOrder.removeFirst(evicted.count)
            }
        }
        rowIndex.set(line: line, rows: isHidden(line: line) ? 0 : Int(laid.height))
        if byLine.count > 4_000 { byLine.removeAll(keepingCapacity: true) }
        byLine[line] = laid
        return laid
    }

    private var suffixes: [String: (line: LaidOutLine, width: CGFloat)] = [:]

    /// A suffix's layout (unwrapped), shaped once per text.
    public func suffixLayout(_ text: String) -> (line: LaidOutLine, width: CGFloat) {
        if let cached = suffixes[text] { return cached }
        if suffixes.count > 200 { suffixes.removeAll() }
        let laid = LaidOutLine(text: text, font: font, tabWidth: tabWidth, wrapWidth: nil)
        let width = laid.caretX(at: (text as NSString).length).x
        suffixes[text] = (laid, width)
        return (laid, width)
    }

    /// Where a line's suffix pill sits (a click there opens a fold), in document points.
    public func suffixRect(line: Int, text: String) -> CGRect {
        let laid = layout(line: line)
        let endX = laid.caretX(at: (laid.text as NSString).length).x
        let last = laid.rows.count - 1
        let top = y(ofLine: line) + laid.rowTops[last]
        return CGRect(x: insets.width + endX + LineSuffix.gap, y: top, width: suffixLayout(text).width + LineSuffix.padding * 2, height: laid.rowHeights[last])
    }

    /// The y of a line's first row (top), in points, document coordinates.
    public func y(ofLine line: Int) -> CGFloat {
        insets.height + CGFloat(rowIndex.prefix(line))
    }

    /// The line and row under a y.
    public func line(atY y: CGFloat) -> (line: Int, row: Int) {
        let point = Int(floor(max(0, y - insets.height)))
        let found = rowIndex.line(atRow: min(point, max(0, rowIndex.totalRows - 1)))
        // Which of the line's rows: measured now if the line wasn't (its height may change, but
        // the point within it is what was asked).
        let laid = layout(line: found.line)
        return (found.line, laid.row(atY: CGFloat(found.rowInLine)))
    }

    /// Lines that intersect a vertical span, with their tops, measured as they go (a line that
    /// turns out to wrap pushes the ones after it down, which the loop accounts for).
    public func visibleLines(from top: CGFloat, to bottom: CGFloat) -> [(line: Int, y: CGFloat, layout: LaidOutLine)] {
        var result: [(Int, CGFloat, LaidOutLine)] = []
        var line = line(atY: top).line
        while line < lineCount {
            // A folded region is skipped whole, however long.
            if let hidden = hiddenRange(containing: line) { line = hidden.upperBound + 1; continue }
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
        return CGRect(x: insets.width + x, y: y(ofLine: line) + laid.rowTops[row], width: 0, height: laid.rowHeights[row])
    }

    /// The UTF-16 offset nearest a point, in document points.
    public func offset(at point: CGPoint) -> Int {
        let (line, row) = line(atY: point.y)
        let laid = layout(line: line)
        let rowInLine = min(row, laid.rows.count - 1)
        var inLine = laid.offset(row: rowInLine, x: point.x - insets.width)
        // Hidden markup has no width, so a click beside it could go either side. An opening mark
        // (at the line's start or after a space: `**` before a word, `#`, `[`) puts the caret
        // after it, in what it marks; a closing one (`**` after a word, `](url)`) before it.
        let units = Array(laid.text.utf16)
        if let range = laid.concealed.first(where: { $0.lowerBound == inLine && !$0.isEmpty }) {
            let before = range.lowerBound == 0 ? nil : units[range.lowerBound - 1]
            if before == nil || before == 0x20 || before == 0x09 { inLine = min(range.upperBound, units.count) }
        }
        return text.offset(ofLine: line) + inLine
    }
}
