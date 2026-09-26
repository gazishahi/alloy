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
}
