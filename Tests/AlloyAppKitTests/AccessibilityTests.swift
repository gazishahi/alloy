import AlloyCore
import AppKit
import Metal
import XCTest
@testable import AlloyAppKit

/// Step 6: what VoiceOver and other assistive clients read from, and do to, the editor.
@MainActor
final class AccessibilityTests: XCTestCase {
    private var window: NSWindow!
    private var editor: AlloyEditorView!
    private var view: AlloyTextView { editor.textView }

    private func open(_ string: String) throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device (a CI runner without a GPU)")
        editor = try AlloyEditorView(buffer: TextBuffer(string), font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.layoutIfNeeded()
        editor.layout()
    }

    override func tearDown() { window?.orderOut(nil) }

    func testIsATextAreaWithTheTextAsItsValue() throws {
        try open("let a = 1\nlet b = 2\n")
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertEqual(view.accessibilityLabel(), "Editor")
        editor.accessibilityName = "main.swift"
        XCTAssertEqual(view.accessibilityLabel(), "main.swift")
        XCTAssertEqual(view.accessibilityValue() as? String, "let a = 1\nlet b = 2\n")
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), 20)
    }

    func testSelectionReadsAndMoves() throws {
        try open("let a = 1\nlet b = 2")
        editor.buffer.setSelections([Selection(anchor: 4, head: 5)])
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 4, length: 1))
        XCTAssertEqual(view.accessibilitySelectedText(), "a")
        view.setAccessibilitySelectedTextRange(NSRange(location: 14, length: 1))
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 14, head: 15)])
        XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), NSNotFound, "a selection has no insertion point")
        view.setAccessibilitySelectedTextRange(NSRange(location: 14, length: 0))
        XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 1)
        view.setAccessibilitySelectedTextRanges([NSValue(range: NSRange(location: 0, length: 3)), NSValue(range: NSRange(location: 10, length: 3))])
        XCTAssertEqual(view.accessibilitySelectedTextRanges()?.map(\.rangeValue), [NSRange(location: 0, length: 3), NSRange(location: 10, length: 3)])
    }

    func testLinesAreLogicalLines() throws {
        try open("one\ntwo\nthree")
        XCTAssertEqual(view.accessibilityLine(for: 0), 0)
        XCTAssertEqual(view.accessibilityLine(for: 5), 1)
        XCTAssertEqual(view.accessibilityRange(forLine: 1), NSRange(location: 4, length: 4), "with its newline")
        XCTAssertEqual(view.accessibilityRange(forLine: 2), NSRange(location: 8, length: 5))
        XCTAssertEqual(view.accessibilityRange(forLine: 3).location, NSNotFound)
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 4, length: 3)), "two")
        XCTAssertEqual(view.accessibilityAttributedString(for: NSRange(location: 8, length: 5))?.string, "three")
    }

    func testComposedCharactersAreOneRange() throws {
        try open("a👍🏽b")
        XCTAssertEqual(view.accessibilityRange(for: 1), NSRange(location: 1, length: 4))
        XCTAssertEqual(view.accessibilityRange(for: 2), NSRange(location: 1, length: 4), "from inside the cluster too")
        XCTAssertEqual(view.accessibilityRange(for: 5), NSRange(location: 5, length: 1))
    }

    func testFramesAreOnScreenAndRoundTrip() throws {
        try open("let a = 1\nlet b = 2")
        let word = view.accessibilityFrame(for: NSRange(location: 4, length: 1))
        XCTAssertGreaterThan(word.width, 1)
        let lines = view.accessibilityFrame(for: NSRange(location: 0, length: 14))
        XCTAssertGreaterThan(lines.height, word.height, "a range across rows covers both")
        XCTAssertEqual(view.accessibilityRange(for: NSPoint(x: word.midX, y: word.midY)), NSRange(location: 4, length: 1))
        XCTAssertEqual(view.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: 19))
    }

    func testAssistiveEditsGoThroughTheBufferAndUndo() throws {
        try open("let a = 1")
        editor.isEditable = true
        editor.buffer.setSelections([Selection(anchor: 4, head: 5)])
        view.setAccessibilitySelectedText("count")
        XCTAssertEqual(editor.buffer.string, "let count = 1")
        view.setAccessibilityValue("replaced")
        XCTAssertEqual(editor.buffer.string, "replaced")
        editor.buffer.undo()
        XCTAssertEqual(editor.buffer.string, "let count = 1")
        editor.isEditable = false
        view.setAccessibilityValue("no")
        XCTAssertEqual(editor.buffer.string, "let count = 1", "read-only stays read-only")
    }
}

@MainActor
final class CaretBlinkTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "NSTextInsertionPointBlinkPeriodOn")
        UserDefaults.standard.removeObject(forKey: "NSTextInsertionPointBlinkPeriodOff")
    }

    func testBlinkFollowsTheSystemDefaults() {
        UserDefaults.standard.removeObject(forKey: "NSTextInsertionPointBlinkPeriodOn")
        UserDefaults.standard.removeObject(forKey: "NSTextInsertionPointBlinkPeriodOff")
        XCTAssertEqual(AlloyEditorView.blinkPeriods?.on, 0.53)
        UserDefaults.standard.set(900, forKey: "NSTextInsertionPointBlinkPeriodOn")
        UserDefaults.standard.set(300, forKey: "NSTextInsertionPointBlinkPeriodOff")
        XCTAssertEqual(AlloyEditorView.blinkPeriods?.on, 0.9)
        XCTAssertEqual(AlloyEditorView.blinkPeriods?.off, 0.3)
        UserDefaults.standard.set(0, forKey: "NSTextInsertionPointBlinkPeriodOff")
        XCTAssertNil(AlloyEditorView.blinkPeriods, "off period zero: a solid caret")
        UserDefaults.standard.set(300, forKey: "NSTextInsertionPointBlinkPeriodOff")
        UserDefaults.standard.set(99_999_999, forKey: "NSTextInsertionPointBlinkPeriodOn")
        XCTAssertNil(AlloyEditorView.blinkPeriods, "on forever: a solid caret")
    }
}
