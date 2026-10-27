import AlloyCore
import AlloyRender
import AppKit
import Metal
import XCTest
@testable import AlloyAppKit

/// Folding in the editor: hidden lines take no space, edits and selections open what they touch.
@MainActor
final class FoldingViewTests: XCTestCase {
    private var window: NSWindow!
    private var editor: AlloyEditorView!

    private let source = "struct A {\n    func b() {\n        one()\n        two()\n    }\n}\nlet c = 1"

    private func open() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device (a CI runner without a GPU)")
        window?.orderOut(nil)
        editor = try AlloyEditorView(buffer: TextBuffer(source), font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.layoutIfNeeded()
        editor.layout()
        editor.foldRegions = Folding.ranges(in: editor.buffer.text)
    }

    /// A snapshot holds the text that's on screen (for previews of a file elsewhere).
    func testASnapshotHoldsTheText() throws {
        try open()
        let image = try XCTUnwrap(editor.snapshot())
        XCTAssertEqual(image.size, editor.drawingRect.size)
        let rep = try XCTUnwrap(image.representations.first.flatMap { _ in NSBitmapImageRep(data: image.tiffRepresentation!) })
        let background = rep.colorAt(x: rep.pixelsWide - 2, y: rep.pixelsHigh - 2)
        var differing = 0
        for y in stride(from: 0, to: min(rep.pixelsHigh, 120), by: 2) {
            for x in stride(from: 0, to: min(rep.pixelsWide, 300), by: 2) where rep.colorAt(x: x, y: y) != background { differing += 1 }
        }
        XCTAssertGreaterThan(differing, 50, "glyphs drawn, not just the background")
    }

    /// Writer mode: a centered reading column, and every line but the focused ones faded.
    func testAReadingColumnAndFocusedLines() throws {
        try open()
        editor.readingColumnWidth = 300
        editor.layout()
        let width = editor.scrollView.contentView.bounds.width
        XCTAssertEqual(editor.documentLayout.caretRect(at: 0).minX, ((width - 300) / 2).rounded(), accuracy: 1, "the text starts where the column does")
        window.setContentSize(NSSize(width: 800, height: 400))
        editor.layout()
        XCTAssertEqual(editor.documentLayout.caretRect(at: 0).minX, ((editor.scrollView.contentView.bounds.width - 300) / 2).rounded(), accuracy: 1, "and stays centered as the window grows")

        func ink(_ image: NSImage, line: Int) -> Int {
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let scale = CGFloat(rep.pixelsHigh) / image.size.height
            let top = Int(editor.documentLayout.y(ofLine: line) * scale), bottom = Int((editor.documentLayout.y(ofLine: line) + editor.documentLayout.lineHeight) * scale)
            let background = rep.colorAt(x: 2, y: 2)!
            var total = 0
            for y in stride(from: top, to: min(bottom, rep.pixelsHigh), by: 1) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let back = background.usingColorSpace(.sRGB) else { continue }
                    total += Int(abs(color.redComponent - back.redComponent) * 100) + Int(abs(color.greenComponent - back.greenComponent) * 100)
                }
            }
            return total
        }
        let plain = try XCTUnwrap(editor.snapshot())
        editor.focusedLines = 1...1
        let focused = try XCTUnwrap(editor.snapshot())
        XCTAssertEqual(Double(ink(focused, line: 1)), Double(ink(plain, line: 1)), accuracy: Double(ink(plain, line: 1)) * 0.05, "the focused line as it was")
        XCTAssertLessThan(ink(focused, line: 2), ink(plain, line: 2) / 2, "another faded")
        editor.readingColumnWidth = nil
        editor.layout()
        XCTAssertEqual(editor.documentLayout.insets.width, DocumentLayout.standardInsets.width)
    }

    /// Font runs are laid out before measuring: a bold run is wider, a line with runs and the
    /// same line without them don't share a layout, and changing the runs lays it out again.
    func testFontRunsChangeTheLayout() throws {
        try open()
        let layout = editor.documentLayout
        let plainWidth = layout.layout(line: 6).rows[0].width
        // A proportional bold (the editor's font here is monospaced: its bold is no wider).
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 13, nil)
        var runs: [FontSpan] = [FontSpan(range: 0..<9, font: bold)]
        editor.fontSpans = { line in line == 6 ? runs : [] }
        let boldLine = layout.layout(line: 6)
        XCTAssertNotEqual(boldLine.rows[0].width, plainWidth, "measured in the run's font")
        XCTAssertEqual(boldLine.fontSpans, runs)
        XCTAssertTrue(boldLine.rows[0].runs.contains { CTFontCopyPostScriptName($0.font) == CTFontCopyPostScriptName(bold) })
        runs = []
        XCTAssertEqual(layout.layout(line: 6).rows[0].width, plainWidth, accuracy: 0.01, "runs gone: laid out plain again")
        editor.fontSpans = nil
    }

    /// Step 2 of live Markdown: a row in a bigger font is taller, and everything that places
    /// rows (positions, the caret, hit tests, moving up and down) follows it.
    func testRowsTakeTheHeightTheirFontNeeds() throws {
        try open()
        let layout = editor.documentLayout
        let plain = layout.lineHeight
        let big = CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil)
        editor.fontSpans = { line in line == 1 ? [FontSpan(range: 0..<14, font: big)] : [] }
        let tall = layout.layout(line: 1)
        XCTAssertGreaterThan(tall.height, plain * 1.5, "the big row is taller")
        XCTAssertGreaterThan(tall.rowBaselines[0], layout.ascent, "and its baseline lower")
        XCTAssertEqual(layout.layout(line: 0).height, plain, "a plain row stays one line height")
        XCTAssertEqual(layout.y(ofLine: 2), layout.y(ofLine: 1) + tall.height, "the next line starts after it")
        let lineOne = layout.text.offset(ofLine: 1)
        XCTAssertEqual(layout.caretRect(at: lineOne + 2).height, tall.height, "the caret is the row's height")
        XCTAssertEqual(layout.line(atY: layout.y(ofLine: 1) + tall.height - 2).line, 1, "a point low in the tall row is in it")
        XCTAssertEqual(layout.line(atY: layout.y(ofLine: 2) + 1).line, 2)
        XCTAssertEqual(layout.contentHeight, CGFloat(layout.lineCount - 1) * plain + tall.height + layout.insets.height * 2, accuracy: 0.5)

        editor.setSelections([Selection(caret: 2)])
        editor.textView.moveDown(nil)
        XCTAssertEqual(layout.text.line(containing: editor.buffer.selections[0].head), 1, "down into the tall line")
        editor.textView.moveDown(nil)
        XCTAssertEqual(layout.text.line(containing: editor.buffer.selections[0].head), 2, "and out of it")
        editor.textView.moveUp(nil)
        XCTAssertEqual(layout.text.line(containing: editor.buffer.selections[0].head), 1)
        editor.fontSpans = nil
        XCTAssertEqual(layout.layout(line: 1).height, plain, "without runs, every row is plain again")
    }

    /// Scrolling up into lines not measured yet, which turn out taller: the text on screen stays
    /// where it was instead of jumping.
    func testScrollingUpKeepsTheTextInPlace() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device (a CI runner without a GPU)")
        let source = (0..<400).map { $0 % 4 == 0 ? "# Heading \($0)" : "Line \($0) of some prose." }.joined(separator: "\n")
        editor = try AlloyEditorView(buffer: TextBuffer(source), font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.layoutIfNeeded()
        editor.layout()
        let big = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
        editor.fontSpans = { [unowned self] line in
            line % 4 == 0 ? [FontSpan(range: 0..<self.editor.documentLayout.text.range(ofLine: line).count, font: big)] : []
        }
        let layout = editor.documentLayout
        editor.scrollY = 3_000
        editor.render()
        let top = layout.line(atY: editor.viewport.minY).line
        let onScreen = layout.y(ofLine: top + 1) - editor.viewport.minY
        editor.scrollY -= 120
        editor.render()
        XCTAssertEqual(layout.y(ofLine: top + 1) - editor.viewport.minY, onScreen + 120, accuracy: 1,
                       "the line that was on screen moved by the scroll, not by the lines measured above it")
    }

    /// Step 3 of live Markdown: hidden markup takes no width and draws nothing, except on the
    /// lines a selection touches; offsets stay the source's.
    func testHiddenMarkupShowsOnlyWhereTheCaretIs() throws {
        try open()
        let layout = editor.documentLayout
        // "    func b() {": hide the four spaces of indent.
        let plain = layout.layout(line: 1)
        let plainX = plain.caretX(at: 4).x
        editor.setSelections([Selection(caret: 0)])
        editor.concealment = { line in line == 1 ? [0..<4] : [] }
        let hidden = layout.layout(line: 1)
        XCTAssertEqual(hidden.concealed, [0..<4])
        XCTAssertEqual(hidden.caretX(at: 4).x, 0, accuracy: 0.01, "the hidden spaces take no room")
        XCTAssertGreaterThan(plainX, 10)
        XCTAssertTrue(hidden.rows[0].runs.contains { $0.isConcealed }, "and are drawn as nothing")
        XCTAssertEqual(layout.offset(at: CGPoint(x: layout.insets.width + 1, y: layout.y(ofLine: 1) + 2)) - layout.text.offset(ofLine: 1), 4,
                       "a click at the line's start lands after what's hidden, in source offsets")

        editor.setSelections([Selection(caret: layout.text.offset(ofLine: 1) + 6)])
        XCTAssertEqual(layout.layout(line: 1).concealed, [], "the caret's line shows its markup")
        XCTAssertEqual(layout.layout(line: 1).caretX(at: 4).x, plainX, accuracy: 0.01)
        editor.setSelections([Selection(anchor: 0, head: layout.text.offset(ofLine: 2))])
        XCTAssertEqual(layout.layout(line: 1).concealed, [], "so does every line a selection touches")
        editor.setSelections([Selection(caret: layout.text.offset(ofLine: 3))])
        XCTAssertEqual(layout.layout(line: 1).concealed, [0..<4], "and hides it again once the caret leaves")
        editor.concealment = nil
    }

    /// Step 4 of live Markdown: a range drawn as the client's image (a formula), as a box its
    /// size; where a selection touches the line, its text instead.
    func testAnInlineReplacementDrawsItsImage() throws {
        try open()
        let layout = editor.documentLayout
        let scale = editor.window?.backingScaleFactor ?? 2
        let red = CGContext(data: nil, width: Int(60 * scale), height: Int(40 * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        red.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        red.fill(CGRect(x: 0, y: 0, width: red.width, height: red.height))
        let image = InlineReplacement(range: 4..<8, image: red.makeImage()!, size: CGSize(width: 60, height: 40), descent: 10, key: "red")
        editor.fontSpans = { _ in [] }   // rows vary, as prose's do
        editor.setSelections([Selection(caret: 0)])
        editor.inlineReplacements = { line in line == 1 ? [image] : [] }
        let laid = layout.layout(line: 1)
        XCTAssertEqual(laid.caretX(at: 8).x - laid.caretX(at: 4).x, 60, accuracy: 0.5, "the box is the image's width")
        XCTAssertGreaterThan(laid.height, layout.lineHeight + 15, "the row grows to hold it")
        XCTAssertTrue(laid.rows[0].runs.contains { $0.replacement == 0 })

        let snapshot = try XCTUnwrap(editor.snapshot())
        let rep = try XCTUnwrap(NSBitmapImageRep(data: snapshot.tiffRepresentation!))
        var redPixels = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.85, c.greenComponent < 0.45, c.blueComponent < 0.3 { redPixels += 1 }
            }
        }
        XCTAssertGreaterThan(redPixels, 300, "the image is drawn")

        editor.setSelections([Selection(caret: layout.text.offset(ofLine: 1) + 2)])
        XCTAssertEqual(layout.layout(line: 1).replacements, [], "the caret's line shows the source")
        editor.inlineReplacements = nil
        editor.fontSpans = nil
    }

    /// Step 5: a picture (its own texture), drawn centered in a wider box; and a box that stays
    /// on the caret's line too.
    func testPicturesCenteredBoxesAndPersistentOnes() throws {
        try open()
        let layout = editor.documentLayout
        let scale = editor.window?.backingScaleFactor ?? 2
        func solid(_ width: CGFloat, _ height: CGFloat, red: CGFloat, blue: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            return context.makeImage()!
        }
        let lineLength = layout.text.range(ofLine: 2).count
        let picture = InlineReplacement(range: 0..<lineLength, image: solid(300, 150, red: 0, blue: 1), size: CGSize(width: 500, height: 150), descent: 0,
                                        key: "blue", drawSize: CGSize(width: 300, height: 150))
        editor.fontSpans = { _ in [] }
        editor.setSelections([Selection(caret: 0)])
        editor.inlineReplacements = { line in line == 2 ? [picture] : [] }
        XCTAssertGreaterThan(layout.layout(line: 2).height, 150, "the row holds the picture")
        let snapshot = try XCTUnwrap(editor.snapshot())
        let rep = try XCTUnwrap(NSBitmapImageRep(data: snapshot.tiffRepresentation!))
        var blueColumns = Set<Int>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.blueComponent > 0.85, c.redComponent < 0.3 { blueColumns.insert(x) }
            }
        }
        XCTAssertFalse(blueColumns.isEmpty, "the picture is drawn, from its own texture")
        let left = CGFloat(blueColumns.min() ?? 0) / CGFloat(rep.pixelsWide) * snapshot.size.width
        XCTAssertEqual(left, layout.insets.width + 100, accuracy: 3, "centered in its 500-point box")

        let padding = InlineReplacement(range: 4..<5, image: solid(1, 1, red: 0, blue: 0), size: CGSize(width: 40, height: 1), descent: 0, key: "pad", persistent: true)
        editor.inlineReplacements = { line in line == 1 ? [padding] : [] }
        editor.setSelections([Selection(caret: layout.text.offset(ofLine: 1) + 2)])
        XCTAssertEqual(layout.layout(line: 1).replacements.count, 1, "a persistent box stays on the caret's line")
        editor.inlineReplacements = nil
        editor.fontSpans = nil
    }

    func testFoldingHidesLinesAndUnfoldingBringsThemBack() throws {
        try open()
        let layout = editor.documentLayout
        let full = layout.contentHeight
        editor.fold(line: 1)
        XCTAssertTrue(editor.isFolded(line: 1))
        XCTAssertEqual(layout.hiddenLines, [2...4], "the body and its closing brace")
        XCTAssertEqual(layout.contentHeight, full - 3 * layout.lineHeight, accuracy: 0.5, "three lines' less")
        XCTAssertEqual(layout.visibleLines(from: 0, to: 1000).map(\.line), [0, 1, 5, 6])
        XCTAssertEqual(layout.line(atY: layout.y(ofLine: 5) + 1).line, 5, "the line after a fold is where the fold's lines were")
        editor.fold(line: 0)
        XCTAssertEqual(layout.hiddenLines, [1...5], "an outer fold takes the inner one in")
        editor.unfoldAll()
        XCTAssertEqual(layout.hiddenLines, [])
        XCTAssertEqual(layout.contentHeight, full, accuracy: 0.5)
    }

    func testASelectionInsideOpensTheFold() throws {
        try open()
        editor.fold(line: 1)
        // Find landing on "two()".
        let offset = (editor.buffer.string as NSString).range(of: "two").location
        editor.setSelections([Selection(anchor: offset, head: offset + 3)])
        XCTAssertFalse(editor.isFolded(line: 1), "what's selected is never out of sight")
    }

    func testFoldingMovesACaretOutAndEditsOpenWhatTheyTouch() throws {
        try open()
        let inside = (editor.buffer.string as NSString).range(of: "one").location
        editor.setSelections([Selection(caret: inside)])
        editor.foldAtCaret(nil)
        XCTAssertTrue(editor.isFolded(line: 1), "the innermost region around the caret")
        XCTAssertEqual(editor.buffer.text.line(containing: editor.buffer.selections[0].head), 1, "the caret moves to the line that stays")
        // An edit above the fold moves it down with its lines.
        editor.buffer.apply([TextEdit(range: 0..<0, text: "// top\n")], kind: .typing)
        XCTAssertEqual(editor.documentLayout.hiddenLines, [3...5])
        // An edit on the fold's first line opens it.
        let header = editor.buffer.text.offset(ofLine: 2)
        editor.buffer.apply([TextEdit(range: header..<header, text: " ")], kind: .typing)
        XCTAssertEqual(editor.documentLayout.hiddenLines, [])
    }

    func testAFoldedRegionReadsAsOneLineAndItsPillOpensIt() throws {
        try open()
        // The regions take in their closing braces.
        XCTAssertEqual(editor.foldRegions, [0...5, 1...4])
        editor.fold(line: 1)
        XCTAssertEqual(editor.documentLayout.hiddenLines, [2...4], "the body and its closing brace")
        XCTAssertEqual(editor.foldSuffixes[1]?.text, "\u{2026} }", "func b() { … }")
        XCTAssertEqual(AlloyEditorView.foldPlaceholder(closing: "    return x"), "\u{2026}", "no closing bracket: just the ellipsis")
        let pill = editor.documentLayout.suffixRect(line: 1, text: "\u{2026} }")
        XCTAssertTrue(editor.unfoldIfClickedPlaceholder(at: CGPoint(x: pill.midX, y: pill.midY)))
        XCTAssertFalse(editor.isFolded(line: 1))
    }

    func testFoldsComeBackWithTheirDocument() throws {
        try open()
        editor.fold(line: 1)
        let first = editor.buffer
        editor.setBuffer(TextBuffer("another\ndocument"))
        XCTAssertEqual(editor.documentLayout.hiddenLines, [])
        editor.setBuffer(first)
        XCTAssertEqual(editor.documentLayout.hiddenLines, [2...4], "the tab comes back folded as it was")
        // Changed while away, where the fold hung from: it doesn't come back folded.
        let other = TextBuffer("x")
        editor.setBuffer(other)
        first.apply([TextEdit(range: first.text.range(ofLine: 1), text: "    func renamed() {")], kind: .typing)
        editor.setBuffer(first)
        XCTAssertEqual(editor.documentLayout.hiddenLines, [])
    }

    func testTheMinimapFollowsAndScrollsTheEditor() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device (a CI runner without a GPU)")
        window?.orderOut(nil)
        let text = (0..<1000).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        editor = try AlloyEditorView(buffer: TextBuffer(text), font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        editor.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        editor.minimap.frame = NSRect(x: 600, y: 0, width: AlloyMinimapView.width, height: 400)
        container.addSubview(editor)
        container.addSubview(editor.minimap)
        window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.layoutIfNeeded()
        editor.layout()
        let minimap = editor.minimap
        XCTAssertEqual(minimap.firstLine(editor: editor), 0, "at the top, the map starts at the top")
        editor.scrollY = editor.documentLayout.contentHeight
        let shown = Int(minimap.bounds.height / AlloyMinimapView.lineHeight)
        XCTAssertEqual(minimap.firstLine(editor: editor), 1000 - shown, "at the bottom, it ends at the bottom")
        // A click near the map's top scrolls the editor to that stretch.
        let point = minimap.convert(NSPoint(x: 20, y: 10), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        minimap.mouseDown(with: event)
        minimap.mouseUp(with: event)
        let top = editor.documentLayout.line(atY: editor.viewport.minY).line
        XCTAssertLessThan(top, 1000 - shown + 10, "scrolled up to the clicked stretch")
    }

    /// A click on a line's number goes to its owner (a breakpoint); left of the numbers, to the
    /// marks; a right-click on a number, to its owner too.
    func testGutterClicksGoWhereTheyLand() throws {
        try open()
        let gutter = editor.gutter
        var numbers: [(Int, NSEvent.EventType)] = []
        var marks: [Int] = []
        gutter.onNumberClick = { numbers.append(($0, $1.type)) }
        gutter.onClick = { line, _ in marks.append(line) }
        gutter.marks = [3: [GutterMark(style: .dot, color: .red)]]
        let layout = editor.documentLayout
        func event(_ type: NSEvent.EventType, x: CGFloat, line: Int) -> NSEvent {
            // `line(at:)` in reverse: the line's middle, in the gutter's coordinates.
            let top = editor.scrollView.convert(editor.scrollView.contentView.frame.origin, to: gutter).y
            let y = top + layout.y(ofLine: line) + layout.lineHeight / 2 - editor.drawingRect.minY
            XCTAssertEqual(gutter.line(at: NSPoint(x: x, y: y)), line + 1)
            let point = gutter.convert(NSPoint(x: x, y: y), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        gutter.mouseDown(with: event(.leftMouseDown, x: 30, line: 2))
        gutter.rightMouseDown(with: event(.rightMouseDown, x: 30, line: 4))
        gutter.mouseDown(with: event(.leftMouseDown, x: 5, line: 2))
        XCTAssertEqual(numbers.map(\.0), [3, 5])
        XCTAssertEqual(numbers.map(\.1), [.leftMouseDown, .rightMouseDown])
        XCTAssertEqual(marks, [3], "left of the numbers: the line's marks")

        // A breakpoint mark draws without taking the marks' clicks.
        gutter.marks = [3: [GutterMark(style: .breakpoint(enabled: true, verified: false), color: .systemBlue)]]
        gutter.display()
    }

    /// Another document in the same view: its numbers, not the last one's (a 17-line file, then
    /// a longer one, kept 17 numbers until the window was resized).
    func testGutterNumbersFollowAnotherDocument() throws {
        try open()
        // Beside the editor, as Side places it.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        editor.removeFromSuperview()
        editor.frame = NSRect(x: 40, y: 0, width: 600, height: 400)
        editor.gutter.frame = NSRect(x: 0, y: 0, width: 40, height: 400)
        host.addSubview(editor.gutter)
        host.addSubview(editor)
        window.contentView = host
        let short = (1...17).map { "line \($0)" }.joined(separator: "\n")
        let long = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let shown = Int(editor.drawingRect.height / editor.documentLayout.lineHeight)
        for hidden in [false, true] {
            editor.setBuffer(TextBuffer(short))
            window.displayIfNeeded()
            XCTAssertEqual(editor.gutter.drawnLastLinesForTesting.last, 16)
            // A sheet or an image between the two (the gutter hidden), or straight across.
            editor.gutter.isHidden = hidden
            editor.setBuffer(TextBuffer(long))
            window.displayIfNeeded()
            editor.gutter.isHidden = false
            window.displayIfNeeded()
            XCTAssertGreaterThanOrEqual(editor.gutter.drawnLastLinesForTesting.last ?? 0, shown - 1, hidden ? "after a hidden gutter" : "straight across")
        }
    }

    /// A minimap turned off (Make hides it and gives it no width) draws nothing when asked: its
    /// tiles keep the width they had, and a negative column count made a backwards range (0.2.0's
    /// crash, 2026-10-27).
    func testAMinimapTurnedOffDrawsNothing() throws {
        try open()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        editor.removeFromSuperview()
        editor.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        editor.minimap.frame = NSRect(x: 600, y: 0, width: AlloyMinimapView.width, height: 400)
        host.addSubview(editor)
        host.addSubview(editor.minimap)
        window.contentView = host
        window.displayIfNeeded()
        let tiles = editor.minimap.layer?.sublayers ?? []
        XCTAssertFalse(tiles.isEmpty)
        for tile in tiles { tile.displayIfNeeded() }
        editor.minimap.isHidden = true
        editor.minimap.frame.size.width = 0
        editor.minimap.needsDisplay = true
        for tile in tiles { tile.setNeedsDisplay(); tile.displayIfNeeded() }
    }
}
