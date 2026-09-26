import AlloyCore
import AlloyRender
import AppKit
import Metal
import XCTest
@testable import AlloyAppKit

/// Step 3: everything a person does to the text, through the entry points AppKit calls.
@MainActor
final class InputTests: XCTestCase {
    private var window: NSWindow!
    private var editor: AlloyEditorView!
    private var view: AlloyTextView { editor.textView }
    private var text: String { editor.buffer.string }
    private var carets: [Int] { editor.buffer.selections.map(\.head) }

    private func open(_ string: String, width: CGFloat = 600) throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device (a CI runner without a GPU)")
        // The previous test's window goes here, not in tearDown: XCTest's tearDown isn't main-actor
        // isolated, and Swift 6.1 won't let it touch the window.
        window?.orderOut(nil)
        editor = try AlloyEditorView(buffer: TextBuffer(string), font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.layoutIfNeeded()
        editor.layout()
        window.makeFirstResponder(view)
        view.pasteboard = NSPasteboard(name: NSPasteboard.Name("alloy-tests-\(UUID().uuidString)"))
    }


    private func command(_ selector: Selector) { view.doCommand(by: selector) }
    private func type(_ string: String) { for c in string { view.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
    private func caret(_ offset: Int) { editor.buffer.setSelections([Selection(caret: offset)]) }

    func testTypingAndMovingByCharacterWordAndLine() throws {
        try open("let value = 1\nnext")
        caret(0)
        command(#selector(NSResponder.moveWordRight(_:)))
        XCTAssertEqual(carets, [3])
        command(#selector(NSResponder.moveWordRight(_:)))
        XCTAssertEqual(carets, [9], "past the space, to the end of the next word")
        command(#selector(NSResponder.moveWordLeftAndModifySelection(_:)))
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 9, head: 4)])
        type("count")
        XCTAssertEqual(text, "let count = 1\nnext", "typing replaces the selection")
        command(#selector(NSResponder.moveToRightEndOfLine(_:)))
        XCTAssertEqual(carets, [13])
        command(#selector(NSResponder.moveToLeftEndOfLine(_:)))
        XCTAssertEqual(carets, [0])
        command(#selector(NSResponder.moveToEndOfDocument(_:)))
        XCTAssertEqual(carets, [18])
        command(#selector(NSResponder.deleteWordBackward(_:)))
        XCTAssertEqual(text, "let count = 1\n")
        command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(text, "let count = 1")
    }

    func testUpAndDownKeepTheirColumn() throws {
        try open("abcdefghij\nab\nabcdefghij")
        caret(8)
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(carets, [13], "a short line: its end")
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(carets, [22], "back to column 8 on the long line")
        command(#selector(NSResponder.moveUpAndModifySelection(_:)))
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 22, head: 13)])
        command(#selector(NSResponder.moveToBeginningOfDocument(_:)))
        command(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(carets, [0])
    }

    func testRowEndsFollowWrapping() throws {
        try open(String(repeating: "word ", count: 40), width: 300)
        caret(0)
        command(#selector(NSResponder.moveToRightEndOfLine(_:)))
        let rowEnd = carets[0]
        XCTAssertGreaterThan(rowEnd, 10)
        XCTAssertLessThan(rowEnd, 190, "the end of the visual row, not the whole line")
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertGreaterThan(carets[0], rowEnd, "down moves to the next visual row")
    }

    /// An input method composing Japanese: marked text shows and changes in place, commits as
    /// one edit, and undoes as one step.
    func testCompositionIsMarkedThenCommittedAsOneUndoStep() throws {
        try open("x")
        caret(1)
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 1, length: 1))
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(text, "xにほん")
        XCTAssertEqual(view.markedRange(), NSRange(location: 1, length: 3))
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(text, "x日本")
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(carets, [3])
        view.undo(nil)
        XCTAssertEqual(text, "x", "the whole composition is one undo step")
        // The input method's candidate window goes under the caret, on screen.
        let rect = view.firstRect(forCharacterRange: NSRange(location: 1, length: 0), actualRange: nil)
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 5), actualRange: nil)?.string, "x")
    }

    func testMultipleCursors() throws {
        try open("one\ntwo\nthree")
        caret(3)
        view.addCaretBelow(nil)
        view.addCaretBelow(nil)
        XCTAssertEqual(carets, [3, 7, 11])
        type(";")
        XCTAssertEqual(text, "one;\ntwo;\nthr;ee")
        command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(editor.buffer.selections.count, 1, "Escape: back to one caret")
    }

    func testOptionDragSelectsAColumn() throws {
        try open("alpha one\nb\ngamma two\ndelta three")
        func point(_ offset: Int) -> CGPoint {
            let caret = editor.documentLayout.caretRect(at: offset)
            return view.convert(CGPoint(x: caret.minX + 1, y: caret.midY), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, at location: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        // From column 1 of the first line to column 4 of the fourth.
        mouse(.leftMouseDown, at: point(1))
        mouse(.leftMouseDragged, at: point(22 + 4))
        mouse(.leftMouseUp, at: point(22 + 4))
        XCTAssertEqual(editor.buffer.selections.map(\.range), [1..<4, 11..<11, 13..<16, 23..<26],
                       "one per line; the short line gets a caret at its end")
        type("X")
        XCTAssertEqual(text, "aXa one\nbX\ngXa two\ndXa three", "each line's part replaced at once")
    }

    func testClicksDoubleClicksAndShiftClicks() throws {
        try open("alpha beta_gamma delta\nsecond")
        func click(_ offset: Int, count: Int = 1, flags: NSEvent.ModifierFlags = []) {
            let caret = editor.documentLayout.caretRect(at: offset)
            let inWindow = view.convert(CGPoint(x: caret.minX + 1, y: caret.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
                type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
            }
        }
        click(8)
        XCTAssertEqual(carets, [8])
        click(8, count: 2)
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 6, head: 16)], "a word, underscores included")
        click(2)
        click(19, flags: .shift)
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 2, head: 19)])
        click(24, count: 3)
        XCTAssertEqual(editor.buffer.selections[0].range, 23..<29, "the line")
        click(0)
        click(10, flags: .option)
        XCTAssertEqual(carets, [0, 10], "⌥-click adds a caret")
    }

    func testCopyCutAndPasteAcrossCursors() throws {
        try open("a1\nb2\nc3")
        editor.buffer.setSelections([Selection(anchor: 0, head: 1), Selection(anchor: 3, head: 4), Selection(anchor: 6, head: 7)])
        view.copy(nil)
        XCTAssertEqual(view.pasteboard.string(forType: .string), "a\nb\nc")
        view.cut(nil)
        XCTAssertEqual(text, "1\n2\n3")
        editor.buffer.setSelections([Selection(caret: 1), Selection(caret: 3), Selection(caret: 5)])
        view.paste(nil)
        XCTAssertEqual(text, "1a\n2b\n3c", "one line per cursor")
        caret(0)
        view.paste(nil)
        XCTAssertEqual(text, "a\nb\nc1a\n2b\n3c", "one cursor: the whole thing")
        let paste = NSMenuItem(title: "Paste", action: #selector(AlloyTextView.paste(_:)), keyEquivalent: "")
        XCTAssertTrue(view.validateMenuItem(paste))
        let copy = NSMenuItem(title: "Copy", action: #selector(AlloyTextView.copy(_:)), keyEquivalent: "")
        XCTAssertFalse(view.validateMenuItem(copy), "nothing selected, nothing to copy")
    }

    /// Make's hooks: veto a typed change (auto-pairing does its own), and take a key command.
    func testTheDelegateDecides() throws {
        final class Recorder: AlloyEditorDelegate {
            var changes = 0
            var selectionChanges = 0
            func editor(_ editor: AlloyEditorView, shouldChangeTextIn range: Range<Int>, replacementString: String) -> Bool {
                guard replacementString == "(" else { return true }
                editor.buffer.apply([TextEdit(range: range, text: "()")], selectionsAfter: [Selection(caret: range.lowerBound + 1)])
                return false
            }
            func editor(_ editor: AlloyEditorView, doCommandBy selector: Selector) -> Bool {
                guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
                editor.buffer.insert("\n    ", kind: .other)
                return true
            }
            func editorTextDidChange(_ editor: AlloyEditorView) { changes += 1 }
            func editorSelectionDidChange(_ editor: AlloyEditorView) { selectionChanges += 1 }
        }
        try open("f")
        let recorder = Recorder()
        editor.delegate = recorder
        caret(1)
        type("(")
        XCTAssertEqual(text, "f()")
        XCTAssertEqual(carets, [2])
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(text, "f(\n    )")
        XCTAssertGreaterThanOrEqual(recorder.changes, 2)
        command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertGreaterThanOrEqual(recorder.selectionChanges, 3)
    }

    /// Content insets (the Find bar, Side's floating chrome) don't shift the text, and the text
    /// goes on under them: the drawing covers the whole clip view, in document coordinates.
    func testInsetsDontShiftTheDrawingAndTextFlowsUnderThem() throws {
        try open(String(repeating: "line\n", count: 200))
        editor.scrollView.automaticallyAdjustsContentInsets = false
        editor.scrollView.contentInsets = NSEdgeInsets(top: 32, left: 0, bottom: 40, right: 0)
        editor.scrollY = 0
        editor.render()
        XCTAssertEqual(editor.scrollY, 0)
        XCTAssertEqual(editor.canvasFrame, editor.scrollView.contentView.frame, "under the insets too")
        // The document's top sits 32 points into the drawing, where the document view is.
        let documentTop = view.convert(CGPoint(x: 0, y: 0), to: editor.scrollView).y
        XCTAssertEqual(documentTop - editor.canvasFrame.minY, -editor.drawingRect.minY, accuracy: 0.5)
        XCTAssertEqual(editor.drawingRect.minY, -32, accuracy: 0.5)
        editor.scrollY = 100
        editor.render()
        XCTAssertEqual(editor.scrollY, 100, accuracy: 0.5)
        XCTAssertEqual(editor.drawingRect.minY, 68, accuracy: 0.5, "the lines above the viewport are drawn, under the top inset")
        XCTAssertEqual(editor.drawingRect.maxY, editor.viewport.maxY + 40, accuracy: 0.5, "and below it, under the bottom inset")
    }

    /// Views added to the text view (Make's proposal cards) sit above the drawing.
    func testOverlaysDrawAboveTheText() throws {
        try open("text\n")
        let subviews = editor.scrollView.subviews
        let canvas = try XCTUnwrap(subviews.firstIndex { $0.frame == editor.canvasFrame && !($0 is NSClipView) && !($0 is NSScroller) })
        let clip = try XCTUnwrap(subviews.firstIndex { $0 === editor.scrollView.contentView })
        XCTAssertLessThan(canvas, clip, "the canvas is beneath the clip view and the document view's own subviews")
        XCTAssertFalse(editor.scrollView.contentView.drawsBackground, "and the clip view lets it show through")
    }

    func testFindClient() throws {
        try open("find me\nand find me again")
        XCTAssertEqual(view.string, "find me\nand find me again")
        view.selectedRanges = [NSValue(range: NSRange(location: 12, length: 4))]
        XCTAssertEqual(editor.buffer.selections, [Selection(anchor: 12, head: 16)])
        XCTAssertEqual(view.firstSelectedRange, NSRange(location: 12, length: 4))
        let rect = try XCTUnwrap(view.rects(forCharacterRange: NSRange(location: 12, length: 4))?.first?.rectValue)
        XCTAssertEqual(rect.minY, editor.documentLayout.y(ofLine: 1))
        XCTAssertGreaterThan(rect.width, 20)
        view.replaceCharacters(in: NSRange(location: 12, length: 4), with: "seek")
        XCTAssertEqual(view.string, "find me\nand seek me again")
        let visible = view.visibleCharacterRanges.first!.rangeValue
        XCTAssertEqual(visible.location, 0)
    }
}

@MainActor
final class RevealTests: XCTestCase {
    /// A line under the bottom inset (a palette over the editor) isn't "visible": revealing it
    /// scrolls it above the inset.
    func testRevealingClearsTheInsets() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device (a CI runner without a GPU)")
        let editor = try AlloyEditorView(buffer: TextBuffer(String(repeating: "line\n", count: 400)), font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.layoutIfNeeded()
        editor.layout()
        editor.scrollView.automaticallyAdjustsContentInsets = false
        editor.scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 200, right: 0)
        editor.scrollY = 0
        let offset = editor.buffer.text.offset(ofLine: 16)
        let line = editor.documentLayout.caretRect(at: offset)
        XCTAssertGreaterThan(line.maxY, editor.viewport.maxY, "the line starts out under the inset")
        editor.scrollToVisible(offset: offset)
        XCTAssertLessThanOrEqual(line.maxY, editor.viewport.maxY, "and ends up above it")
        editor.scrollToVisible(offset: offset)
        let settled = editor.scrollY
        editor.scrollToVisible(offset: offset)
        XCTAssertEqual(editor.scrollY, settled, "already visible: no scroll")
        window.orderOut(nil)
    }
}
