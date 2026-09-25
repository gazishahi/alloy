import XCTest
@testable import AlloyCore

final class TextBufferTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 0)

    private func buffer(_ text: String) -> TextBuffer {
        let buffer = TextBuffer(text)
        buffer.now = { [unowned self] in self.clock }
        return buffer
    }

    private func type(_ text: String, into buffer: TextBuffer) {
        for character in text {
            clock += 0.1
            buffer.insert(String(character))
        }
    }

    func testTypingAndDeletingMoveTheCaret() {
        let b = buffer("hello")
        b.setSelections([Selection(caret: 5)])
        type(" world", into: b)
        XCTAssertEqual(b.string, "hello world")
        XCTAssertEqual(b.selections, [Selection(caret: 11)])
        b.deleteBackward()
        XCTAssertEqual(b.string, "hello worl")
        b.setSelections([Selection(anchor: 0, head: 5)])
        b.insert("HELLO")
        XCTAssertEqual(b.string, "HELLO worl", "typing replaces the selection")
        b.setSelections([Selection(caret: 0)])
        b.deleteForward()
        XCTAssertEqual(b.string, "ELLO worl")
    }

    func testBackspaceRemovesWholeCharacters() {
        let b = buffer("a😀e\u{301}")
        b.setSelections([Selection(caret: b.text.utf16Count)])
        b.deleteBackward()
        XCTAssertEqual(b.string, "a😀", "e + combining accent goes as one")
        b.deleteBackward()
        XCTAssertEqual(b.string, "a", "the emoji goes whole")
    }

    func testMultipleCursorsEditTogether() {
        let b = buffer("one\ntwo\nthree")
        b.setSelections([Selection(caret: 3), Selection(caret: 7), Selection(caret: 13)])
        type("!", into: b)
        XCTAssertEqual(b.string, "one!\ntwo!\nthree!")
        XCTAssertEqual(b.selections.map(\.head), [4, 9, 16])
        b.deleteBackward()
        XCTAssertEqual(b.string, "one\ntwo\nthree")
        XCTAssertEqual(b.selections.map(\.head), [3, 7, 13])
    }

    func testSelectionsMerge() {
        let b = buffer("abcdefgh")
        b.setSelections([Selection(anchor: 0, head: 3), Selection(anchor: 2, head: 5), Selection(caret: 7), Selection(caret: 7)])
        XCTAssertEqual(b.selections, [Selection(anchor: 0, head: 5), Selection(caret: 7)])
        b.setSelections([])
        XCTAssertEqual(b.selections, [Selection(caret: 0)], "there's always a caret")
    }

    func testTypingIsOneUndoStepAndANewlineOrAPauseSplitsIt() {
        let b = buffer("")
        type("hello", into: b)
        b.insert("\n")
        type("world", into: b)
        clock += 5
        type("!", into: b)
        XCTAssertEqual(b.string, "hello\nworld!")
        b.undo()
        XCTAssertEqual(b.string, "hello\nworld", "a pause starts a new step")
        b.undo()
        XCTAssertEqual(b.string, "hello\n")
        b.undo()
        XCTAssertEqual(b.string, "hello", "the newline is its own step")
        b.undo()
        XCTAssertEqual(b.string, "")
        XCTAssertFalse(b.canUndo)
        b.redo(); b.redo()
        XCTAssertEqual(b.string, "hello\n")
        XCTAssertEqual(b.selections, [Selection(caret: 6)], "redo restores the caret too")
    }

    func testMovingTheCaretSplitsAStep() {
        let b = buffer("ab")
        b.setSelections([Selection(caret: 1)])
        type("x", into: b)
        b.setSelections([Selection(caret: 3)])
        type("y", into: b)
        b.undo()
        XCTAssertEqual(b.string, "axb")
    }

    func testAnEditClearsRedo() {
        let b = buffer("")
        type("a", into: b)
        b.undo()
        type("b", into: b)
        XCTAssertFalse(b.canRedo)
    }

    /// Consumers (tree-sitter, LSP) replay changes in order; replaying every change, including
    /// undo and redo, onto a copy must give the same text.
    func testChangesReplayExactly() {
        let b = buffer("func f() {\n}\n")
        var replica = b.string
        b.onChange = { change in
            for edit in change.edits {
                let units = Array(replica.utf16)
                XCTAssertEqual(String(decoding: units[edit.range], as: UTF16.self), edit.oldText)
                replica = String(decoding: units[..<edit.range.lowerBound] + Array(edit.newText.utf16) + units[edit.range.upperBound...], as: UTF16.self)
            }
        }
        b.setSelections([Selection(caret: 10), Selection(caret: 12)])
        type("ab", into: b)
        b.apply([TextEdit(range: 0..<4, text: "function"), TextEdit(range: 5..<6, text: "g")])
        XCTAssertEqual(replica, b.string)
        b.undo()
        XCTAssertEqual(replica, b.string)
        b.undo()
        XCTAssertEqual(replica, b.string)
        b.redo()
        XCTAssertEqual(replica, b.string)
    }

    func testAnEditMovesOtherSelections() {
        let b = buffer("0123456789")
        b.setSelections([Selection(caret: 8)])
        b.apply([TextEdit(range: 2..<4, text: "abcd")])
        XCTAssertEqual(b.selections, [Selection(caret: 10)], "text before the caret grew by two")
        b.apply([TextEdit(range: 9..<11, text: "")])
        XCTAssertEqual(b.selections, [Selection(caret: 9)], "a caret inside a deletion lands at its end")
    }
}

final class ReplaceAllTests: XCTestCase {
    func testReplacesOnlyWhatDiffers() {
        let buffer = TextBuffer("func a() {}\nfunc b() {}\nfunc c() {}\n")
        buffer.setSelections([Selection(caret: 30)])
        var changes: [TextChange] = []
        buffer.onChange = { changes.append($0) }
        buffer.insert("x")
        let edit = buffer.replaceAll(with: "func a() {}\nfunc bee() { 1 }\nfunc c() {}\n")
        XCTAssertEqual(buffer.string, "func a() {}\nfunc bee() { 1 }\nfunc c() {}\n")
        XCTAssertEqual(edit?.range.lowerBound, 18, "the common start is kept")
        XCTAssertEqual(changes.last?.reason, .replace)
        XCTAssertFalse(buffer.canUndo, "outside undo: the history described the old text")
        XCTAssertNil(buffer.replaceAll(with: buffer.string), "no change, no edit")
    }

    func testNeverSplitsASurrogatePair() {
        let buffer = TextBuffer("a👍b")
        // 👍 (D83D DC4D) and 👎 (D83D DC4E) share their lead surrogate.
        let edit = buffer.replaceAll(with: "a👎b")
        XCTAssertEqual(buffer.string, "a👎b")
        XCTAssertEqual(edit?.range, 1..<3)
        XCTAssertEqual(edit?.newText, "👎")
    }

    func testSelectionsFollowTheEdit() {
        let buffer = TextBuffer("one two three")
        buffer.setSelections([Selection(caret: 11)])
        buffer.replaceAll(with: "one 2 three")
        XCTAssertEqual(buffer.selections.first?.head, 9, "the caret moves with the text after the edit")
    }
}

final class ReplaceAllRandomTests: XCTestCase {
    /// Against the plain answer, over many leaves and multi-byte text: random replacements at
    /// random places, including at the very start and end.
    func testMatchesTheNewTextExactly() {
        let pieces = ["a", "é", "👍🏽", "\n", "中", "ab\ncd", "", "🇺🇸"]
        var generator = SystemRandomNumberGenerator()
        var current = (0..<4_000).map { _ in pieces.randomElement(using: &generator)! }.joined()
        let buffer = TextBuffer(current)
        for _ in 0..<300 {
            var scalars = Array(current.unicodeScalars)
            let at = Int.random(in: 0...scalars.count, using: &generator)
            let length = Int.random(in: 0...min(20, scalars.count - at), using: &generator)
            let insert = (0..<Int.random(in: 0...5, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            scalars.replaceSubrange(at..<(at + length), with: insert.unicodeScalars)
            current = String(String.UnicodeScalarView(scalars))
            buffer.replaceAll(with: current)
            XCTAssertEqual(buffer.string, current)
            if buffer.string != current { return }
        }
    }
}
