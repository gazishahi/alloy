import AlloyCore
import AppKit
import Metal
import XCTest
@testable import AlloyAppKit

/// The editing commands a keymap binds: each on every selection, each one undo step.
@MainActor
final class EditingActionsTests: XCTestCase {
    private var window: NSWindow!
    private var editor: AlloyEditorView!

    private func open(_ text: String, selections: [Selection]) throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device (a CI runner without a GPU)")
        window?.orderOut(nil)
        editor = try AlloyEditorView(buffer: TextBuffer(text), font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.layoutIfNeeded()
        editor.layout()
        editor.buffer.setSelections(selections)
    }

    private var view: AlloyTextView { editor.textView }
    private var text: String { editor.buffer.string }

    func testToggleCommentAddsAtTheSharedIndentAndTakesOff() throws {
        try open("func a() {\n    one()\n\n  two()\n}", selections: [Selection(anchor: 11, head: 30)])
        editor.lineComment = "//"
        view.toggleLineComment(nil)
        XCTAssertEqual(text, "func a() {\n  //   one()\n\n  // two()\n}", "at the shallowest indent, blank lines left alone")
        view.toggleLineComment(nil)
        XCTAssertEqual(text, "func a() {\n    one()\n\n  two()\n}")
        editor.buffer.undo()
        XCTAssertEqual(text, "func a() {\n  //   one()\n\n  // two()\n}", "one undo step each")
    }

    func testMovingLinesTakesTheSelectionAlongAndStopsAtTheEdge() throws {
        try open("a\nb\nc", selections: [Selection(caret: 2)])
        view.moveLinesUp(nil)
        XCTAssertEqual(text, "b\na\nc")
        XCTAssertEqual(editor.buffer.selections, [Selection(caret: 0)])
        view.moveLinesUp(nil)
        XCTAssertEqual(text, "b\na\nc", "the first line doesn't move up")
        view.moveLinesDown(nil); view.moveLinesDown(nil)
        XCTAssertEqual(text, "a\nc\nb", "down to the last line, whose missing break sorts itself out")
        XCTAssertEqual(editor.buffer.selections, [Selection(caret: 4)])
    }

    func testDuplicateDeleteIndentAndJoin() throws {
        try open("one\ntwo", selections: [Selection(caret: 1)])
        view.duplicateLines(nil)
        XCTAssertEqual(text, "one\none\ntwo")
        XCTAssertEqual(editor.buffer.selections, [Selection(caret: 5)], "the caret goes onto the copy")
        view.deleteLines(nil)
        XCTAssertEqual(text, "one\ntwo")
        editor.buffer.setSelections([Selection(anchor: 0, head: 5)])
        view.indentLines(nil)
        XCTAssertEqual(text, "    one\n    two")
        view.outdentLines(nil)
        XCTAssertEqual(text, "one\ntwo")
        editor.buffer.setSelections([Selection(caret: 0)])
        view.joinLines(nil)
        XCTAssertEqual(text, "one two")
    }

    func testSelectingOccurrences() throws {
        try open("let count = count + count", selections: [Selection(caret: 6)])
        view.selectNextOccurrence(nil)
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 4, head: 9)], "a caret takes its word")
        view.selectNextOccurrence(nil)
        XCTAssertEqual(editor.buffer.selections.count, 2)
        view.selectAllOccurrences(nil)
        XCTAssertEqual(editor.buffer.selections.map(\.range), [4..<9, 12..<17, 20..<25])
    }

    func testExpandShrinkAndMatchingBracket() throws {
        try open("f(a, [b])", selections: [Selection(caret: 6)])
        let ranges: [Range<Int>] = [6..<7, 5..<8, 2..<8, 0..<9]
        editor.onExpandSelection = { range in ranges.first { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound && $0 != range } }
        view.expandSelection(nil); view.expandSelection(nil)
        XCTAssertEqual(editor.buffer.selections.first?.range, 5..<8)
        view.shrinkSelection(nil)
        XCTAssertEqual(editor.buffer.selections.first?.range, 6..<7)
        editor.buffer.setSelections([Selection(caret: 1)])
        view.goToMatchingBracket(nil)
        XCTAssertEqual(editor.buffer.selections, [Selection(caret: 9)], "past the closer")
        view.goToMatchingBracket(nil)
        XCTAssertEqual(editor.buffer.selections, [Selection(caret: 1)], "and back")
    }
}
