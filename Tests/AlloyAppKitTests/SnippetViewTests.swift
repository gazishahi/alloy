import AlloyCore
import AppKit
import Metal
import XCTest
@testable import AlloyAppKit

/// Snippets in the editor: Tab moves through the stops, a mirror is typed once, and moving
/// away ends it.
@MainActor
final class SnippetViewTests: XCTestCase {
    private var window: NSWindow!
    private var editor: AlloyEditorView!

    private func open(_ text: String) throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device (a CI runner without a GPU)")
        window?.orderOut(nil)
        editor = try AlloyEditorView(buffer: TextBuffer(text), font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.layoutIfNeeded()
        editor.layout()
        window.makeFirstResponder(editor.textView)
    }

    private func type(_ text: String) {
        editor.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func testTabMovesThroughTheStopsAndAMirrorIsTypedOnce() throws {
        try open("let x = \n")
        editor.insert(Snippet(parsing: "${1:name}(${2:arg}) // ${1:name}$0"), replacing: 8..<8)
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 8, head: 12), Selection(anchor: 21, head: 25)], "the stop and its mirror, selected")
        type("go")
        XCTAssertEqual(editor.buffer.string, "let x = go(arg) // go\n")
        editor.textView.insertTab(nil)
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 11, head: 14)], "the next stop")
        type("1")
        editor.textView.insertTab(nil)
        XCTAssertEqual(editor.buffer.selections, [Selection(caret: 19)], "the end")
        XCTAssertFalse(editor.isInSnippet, "done at $0")
        editor.textView.insertTab(nil)
        XCTAssertEqual(editor.buffer.string, "let x = go(1) // go\t\n", "Tab types a tab again")
    }

    func testBacktabGoesBackAndEscapeOrMovingAwayEnds() throws {
        try open("\n")
        editor.insert(Snippet(parsing: "f(${1:a}, ${2:b})"), replacing: 0..<0)
        editor.textView.insertTab(nil)
        editor.textView.insertBacktab(nil)
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 2, head: 3)])
        editor.textView.cancelOperation(nil)
        XCTAssertFalse(editor.isInSnippet)

        editor.insert(Snippet(parsing: "g(${1:a}, ${2:b})"), replacing: 0..<0)
        XCTAssertTrue(editor.isInSnippet)
        editor.textView.moveToEndOfDocument(nil)
        XCTAssertFalse(editor.isInSnippet, "a caret outside the stop ends it")
    }

    func testExtraEditsBeforeItMoveItsStops() throws {
        try open("\nuse\n")
        editor.insert(Snippet(parsing: "useThing(${1:x})"), replacing: 1..<4, alsoApplying: [TextEdit(range: 0..<0, text: "import thing\n")])
        XCTAssertEqual(editor.buffer.string, "import thing\n\nuseThing(x)\n")
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 23, head: 24)])
        editor.buffer.undo()
        XCTAssertEqual(editor.buffer.string, "\nuse\n", "one undo step")
    }

    func testTheCharacterUnderThePointer() throws {
        try open("abc\n\ndef")
        let layout = editor.documentLayout
        let b = layout.caretRect(at: 1)
        XCTAssertEqual(editor.characterOffset(at: CGPoint(x: b.minX + 1, y: b.midY)), 1)
        let lineEnd = layout.caretRect(at: 3)
        XCTAssertNil(editor.characterOffset(at: CGPoint(x: lineEnd.maxX + 40, y: lineEnd.midY)), "past the line's end")
        let blank = layout.caretRect(at: 4)
        XCTAssertNil(editor.characterOffset(at: CGPoint(x: blank.minX + 1, y: blank.midY)), "an empty line")
    }
}
