import AlloyCore
import AlloyRender
import AppKit

/// What the editor asks and tells its owner: the same decisions Make's editor makes today
/// (`EditorEngineDelegate` in Side), so Make can plug Alloy in unchanged (step 5).
@MainActor
public protocol AlloyEditorDelegate: AnyObject {
    /// A typed change is about to happen; false to handle it yourself (auto-pairing).
    func editor(_ editor: AlloyEditorView, shouldChangeTextIn range: Range<Int>, replacementString: String) -> Bool
    /// A key command (moveUp:, insertNewline:…); true if handled.
    func editor(_ editor: AlloyEditorView, doCommandBy selector: Selector) -> Bool
    func editorTextDidChange(_ editor: AlloyEditorView)
    func editorSelectionDidChange(_ editor: AlloyEditorView)
    /// The context menu for a right-click at a UTF-16 offset: add to it or replace it.
    func editor(_ editor: AlloyEditorView, menu: NSMenu, forCharacterAt offset: Int) -> NSMenu
}

public extension AlloyEditorDelegate {
    func editor(_ editor: AlloyEditorView, menu: NSMenu, forCharacterAt offset: Int) -> NSMenu { menu }
    func editor(_ editor: AlloyEditorView, shouldChangeTextIn range: Range<Int>, replacementString: String) -> Bool { true }
    func editor(_ editor: AlloyEditorView, doCommandBy selector: Selector) -> Bool { false }
    func editorTextDidChange(_ editor: AlloyEditorView) {}
    func editorSelectionDidChange(_ editor: AlloyEditorView) {}
}

/// The document view: as tall as the text, inside the scroll view, and the first responder.
/// Everything a person does to the text arrives here, through AppKit's own protocols:
/// `NSTextInputClient` for typing (input methods, dictation, the character palette),
/// `interpretKeyEvents` for key bindings, and `NSTextFinderClient` for the Find bar.
@MainActor
public final class AlloyTextView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation, @preconcurrency NSTextFinderClient {
    weak var editor: AlloyEditorView?

    /// The range of text an input method is composing (shown underlined), if any.
    public private(set) var composingRange: Range<Int>?
    /// The column (x) vertical movement aims for, per selection, until something else moves them.
    private var goalX: [CGFloat]?
    private var dragAnchor: Selection?
    private var dragGranularity = 1
    private var dragAddsCaret = false
    /// ⌥-drag: where the rectangle started, and the selections before the press.
    private var columnStart: CGPoint?
    private var autoscrollTimer: Timer?
    let textFinder = NSTextFinder()

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        textFinder.client = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var buffer: TextBuffer { editor!.buffer }
    private var layout: DocumentLayout { editor!.documentLayout }

    public override func becomeFirstResponder() -> Bool {
        editor?.focusChanged(true)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        editor?.focusChanged(false)
        return true
    }

    public override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .iBeam)
    }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) {
        // Input methods and key bindings both go through here, as in NSTextView.
        if inputContext?.handleEvent(event) == true { return }
        interpretKeyEvents([event])
    }

    public override func doCommand(by selector: Selector) {
        guard let editor else { return }
        if editor.delegate?.editor(editor, doCommandBy: selector) == true { return }
        // Only the commands this view implements; anything else beeps, as in NSTextView.
        if responds(to: selector), Self.commands.contains(selector) {
            perform(selector, with: nil)
        } else {
            NSSound.beep()
        }
    }

    static let commands: Set<Selector> = [
        #selector(moveLeft(_:)), #selector(moveRight(_:)), #selector(moveUp(_:)), #selector(moveDown(_:)),
        #selector(moveLeftAndModifySelection(_:)), #selector(moveRightAndModifySelection(_:)),
        #selector(moveUpAndModifySelection(_:)), #selector(moveDownAndModifySelection(_:)),
        #selector(moveWordLeft(_:)), #selector(moveWordRight(_:)),
        #selector(moveWordLeftAndModifySelection(_:)), #selector(moveWordRightAndModifySelection(_:)),
        #selector(moveToLeftEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)),
        #selector(moveToLeftEndOfLineAndModifySelection(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:)),
        #selector(moveToBeginningOfLine(_:)), #selector(moveToEndOfLine(_:)),
        #selector(moveToBeginningOfDocument(_:)), #selector(moveToEndOfDocument(_:)),
        #selector(moveToBeginningOfDocumentAndModifySelection(_:)), #selector(moveToEndOfDocumentAndModifySelection(_:)),
        #selector(moveToBeginningOfParagraph(_:)), #selector(moveToEndOfParagraph(_:)),
        #selector(pageUp(_:)), #selector(pageDown(_:)), #selector(scrollPageUp(_:)), #selector(scrollPageDown(_:)),
        #selector(scrollToBeginningOfDocument(_:)), #selector(scrollToEndOfDocument(_:)),
        #selector(deleteBackward(_:)), #selector(deleteForward(_:)), #selector(deleteWordBackward(_:)), #selector(deleteWordForward(_:)),
        #selector(deleteToBeginningOfLine(_:)), #selector(deleteToEndOfLine(_:)), #selector(deleteBackwardByDecomposingPreviousCharacter(_:)),
        #selector(insertNewline(_:)), #selector(insertTab(_:)), #selector(insertBacktab(_:)), #selector(insertLineBreak(_:)),
        #selector(selectAll(_:)), #selector(selectLine(_:)), #selector(cancelOperation(_:)),
        #selector(addCaretAbove(_:)), #selector(addCaretBelow(_:)),
    ]

    // Movement: each selection moves; with the modify variants its anchor stays.

    private func move(extending: Bool, keepsGoal: Bool = false, _ target: (Selection, Int) -> Int) {
        if !keepsGoal { goalX = nil }
        let moved = buffer.selections.enumerated().map { index, selection -> Selection in
            let head = target(selection, index)
            return extending ? Selection(anchor: selection.anchor, head: head) : Selection(caret: head)
        }
        setSelections(moved)
    }

    @objc public override func moveLeft(_ sender: Any?) {
        move(extending: false) { s, _ in s.isCaret ? buffer.previousBoundary(before: s.head) : s.range.lowerBound }
    }
    @objc public override func moveRight(_ sender: Any?) {
        move(extending: false) { s, _ in s.isCaret ? buffer.nextBoundary(after: s.head) : s.range.upperBound }
    }
    @objc public override func moveLeftAndModifySelection(_ sender: Any?) { move(extending: true) { s, _ in buffer.previousBoundary(before: s.head) } }
    @objc public override func moveRightAndModifySelection(_ sender: Any?) { move(extending: true) { s, _ in buffer.nextBoundary(after: s.head) } }

    @objc public override func moveUp(_ sender: Any?) { vertical(-1, extending: false) }
    @objc public override func moveDown(_ sender: Any?) { vertical(1, extending: false) }
    @objc public override func moveUpAndModifySelection(_ sender: Any?) { vertical(-1, extending: true) }
    @objc public override func moveDownAndModifySelection(_ sender: Any?) { vertical(1, extending: true) }

    /// Up and down by visual row, aiming for the column the move started in.
    private func vertical(_ direction: Int, extending: Bool, rows: Int = 1) {
        let goals = goalX ?? buffer.selections.map { layout.caretRect(at: $0.head).minX }
        move(extending: extending, keepsGoal: true) { s, index in
            let caret = layout.caretRect(at: extending || s.isCaret ? s.head : (direction < 0 ? s.range.lowerBound : s.range.upperBound))
            let y = caret.midY + CGFloat(direction * rows) * layout.lineHeight
            if y < layout.insets.height { return 0 }
            if y > layout.contentHeight - layout.insets.height { return buffer.text.utf16Count }
            return layout.offset(at: CGPoint(x: goals[min(index, goals.count - 1)], y: y))
        }
        goalX = goals
    }

    @objc public override func moveWordLeft(_ sender: Any?) { move(extending: false) { s, _ in wordBoundary(before: s.isCaret ? s.head : s.range.lowerBound) } }
    @objc public override func moveWordRight(_ sender: Any?) { move(extending: false) { s, _ in wordBoundary(after: s.isCaret ? s.head : s.range.upperBound) } }
    @objc public override func moveWordLeftAndModifySelection(_ sender: Any?) { move(extending: true) { s, _ in wordBoundary(before: s.head) } }
    @objc public override func moveWordRightAndModifySelection(_ sender: Any?) { move(extending: true) { s, _ in wordBoundary(after: s.head) } }

    @objc public override func moveToLeftEndOfLine(_ sender: Any?) { move(extending: false) { s, _ in rowBounds(s.head).lowerBound } }
    @objc public override func moveToRightEndOfLine(_ sender: Any?) { move(extending: false) { s, _ in rowBounds(s.head).upperBound } }
    @objc public override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { move(extending: true) { s, _ in rowBounds(s.head).lowerBound } }
    @objc public override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { move(extending: true) { s, _ in rowBounds(s.head).upperBound } }
    @objc public override func moveToBeginningOfLine(_ sender: Any?) { moveToLeftEndOfLine(sender) }
    @objc public override func moveToEndOfLine(_ sender: Any?) { moveToRightEndOfLine(sender) }
    @objc public override func moveToBeginningOfParagraph(_ sender: Any?) {
        move(extending: false) { s, _ in buffer.text.offset(ofLine: buffer.text.line(containing: s.head)) }
    }
    @objc public override func moveToEndOfParagraph(_ sender: Any?) {
        move(extending: false) { s, _ in buffer.text.range(ofLine: buffer.text.line(containing: s.head)).upperBound }
    }
    @objc public override func moveToBeginningOfDocument(_ sender: Any?) { move(extending: false) { _, _ in 0 } }
    @objc public override func moveToEndOfDocument(_ sender: Any?) { move(extending: false) { _, _ in buffer.text.utf16Count } }
    @objc public override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(extending: true) { _, _ in 0 } }
    @objc public override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(extending: true) { _, _ in buffer.text.utf16Count } }

    @objc public override func pageUp(_ sender: Any?) { page(-1) }
    @objc public override func pageDown(_ sender: Any?) { page(1) }
    @objc public override func scrollPageUp(_ sender: Any?) { editor?.scrollY -= visibleRect.height * 0.9 }
    @objc public override func scrollPageDown(_ sender: Any?) { editor?.scrollY += visibleRect.height * 0.9 }
    @objc public override func scrollToBeginningOfDocument(_ sender: Any?) { editor?.scrollY = 0 }
    @objc public override func scrollToEndOfDocument(_ sender: Any?) { editor?.scrollY = .greatestFiniteMagnitude }

    private func page(_ direction: Int) {
        let rows = max(1, Int(visibleRect.height / layout.lineHeight) - 2)
        editor?.scrollY += CGFloat(direction * rows) * layout.lineHeight
        vertical(direction, extending: false, rows: rows)
    }

    /// The start and end of the visual row holding an offset (a wrapped row, not the whole line).
    private func rowBounds(_ offset: Int) -> Range<Int> {
        let line = buffer.text.line(containing: offset)
        let start = buffer.text.offset(ofLine: line)
        let laid = layout.layout(line: line)
        let row = laid.rows[laid.row(containing: offset - start)]
        let isLast = row.range.upperBound == laid.text.utf16.count
        // A wrapped row's end is its last character's far side; the line's own end has no newline in the range.
        return (start + row.range.lowerBound)..<(start + (isLast ? row.range.upperBound : max(row.range.lowerBound, row.range.upperBound - 1)))
    }

    // Words: letters, digits and underscore; movement skips anything else first.

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    func wordBoundary(before offset: Int) -> Int {
        let start = max(0, offset - 400)
        let window = Array(buffer.text.substring(start..<offset))
        var i = window.count
        while i > 0, !Self.isWord(window[i - 1]) { i -= 1 }
        while i > 0, Self.isWord(window[i - 1]) { i -= 1 }
        return offset - window[i...].reduce(0) { $0 + String($1).utf16.count }
    }

    func wordBoundary(after offset: Int) -> Int {
        let end = min(buffer.text.utf16Count, offset + 400)
        let window = Array(buffer.text.substring(offset..<end))
        var i = 0
        while i < window.count, !Self.isWord(window[i]) { i += 1 }
        while i < window.count, Self.isWord(window[i]) { i += 1 }
        return offset + window[..<i].reduce(0) { $0 + String($1).utf16.count }
    }

    /// What a double-click selects: the run of word characters, or of spaces, under the
    /// pointer, or the single symbol there.
    func wordRange(at offset: Int) -> Range<Int> {
        let lineRange = buffer.text.range(ofLine: buffer.text.line(containing: offset))
        var characters: [(character: Character, range: Range<Int>)] = []
        var position = lineRange.lowerBound
        for character in buffer.text.substring(lineRange) {
            let length = String(character).utf16.count
            characters.append((character, position..<(position + length)))
            position += length
        }
        guard !characters.isEmpty else { return offset..<offset }
        let hit = characters.firstIndex { $0.range.contains(offset) } ?? characters.count - 1
        let kind: (Character) -> Int = { Self.isWord($0) ? 0 : ($0.isWhitespace ? 1 : 2) }
        let target = kind(characters[hit].character)
        guard target != 2 else { return characters[hit].range }
        var lower = hit
        while lower > 0, kind(characters[lower - 1].character) == target { lower -= 1 }
        var upper = hit
        while upper < characters.count - 1, kind(characters[upper + 1].character) == target { upper += 1 }
        return characters[lower].range.lowerBound..<characters[upper].range.upperBound
    }

    // Deleting.

    @objc public override func deleteBackward(_ sender: Any?) { goalX = nil; guardedEdit { buffer.deleteBackward() } }
    @objc public override func deleteForward(_ sender: Any?) { goalX = nil; guardedEdit { buffer.deleteForward() } }
    @objc public override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) { deleteBackward(sender) }
    @objc public override func deleteWordBackward(_ sender: Any?) { deleteTo { s in wordBoundary(before: s.head)..<s.head } }
    @objc public override func deleteWordForward(_ sender: Any?) { deleteTo { s in s.head..<wordBoundary(after: s.head) } }
    @objc public override func deleteToBeginningOfLine(_ sender: Any?) { deleteTo { s in rowBounds(s.head).lowerBound..<s.head } }
    @objc public override func deleteToEndOfLine(_ sender: Any?) { deleteTo { s in s.head..<rowBounds(s.head).upperBound } }

    private func deleteTo(_ range: (Selection) -> Range<Int>) {
        goalX = nil
        let edits = buffer.selections.map { TextEdit(range: $0.isCaret ? range($0) : $0.range, text: "") }
        apply(edits, kind: .deleting)
    }

    // Inserting.

    @objc public override func insertNewline(_ sender: Any?) { insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    @objc public override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }
    @objc public override func insertTab(_ sender: Any?) { insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    @objc public override func insertBacktab(_ sender: Any?) {}

    @objc public override func selectAll(_ sender: Any?) { setSelections([Selection(anchor: 0, head: buffer.text.utf16Count)]) }
    @objc public override func selectLine(_ sender: Any?) {
        setSelections(buffer.selections.map { s in
            let line = buffer.text.line(containing: s.head)
            return Selection(anchor: buffer.text.offset(ofLine: line), head: min(buffer.text.utf16Count, buffer.text.range(ofLine: line).upperBound + 1))
        })
    }

    /// Escape: back to one caret (the first), as in every multi-cursor editor.
    @objc public override func cancelOperation(_ sender: Any?) {
        if buffer.selections.count > 1 { setSelections([Selection(caret: buffer.selections[0].head)]) }
    }

    /// ⌥⌘↑ / ⌥⌘↓: another caret a row above or below each one.
    @objc public func addCaretAbove(_ sender: Any?) { addCarets(-1) }
    @objc public func addCaretBelow(_ sender: Any?) { addCarets(1) }

    private func addCarets(_ direction: Int) {
        let extra = buffer.selections.compactMap { s -> Selection? in
            let caret = layout.caretRect(at: s.head)
            let y = caret.midY + CGFloat(direction) * layout.lineHeight
            guard y > layout.insets.height, y < layout.contentHeight - layout.insets.height else { return nil }
            return Selection(caret: layout.offset(at: CGPoint(x: caret.minX, y: y)))
        }
        setSelections(buffer.selections + extra)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags == [.command, .option], event.keyCode == 126 { addCaretAbove(nil); return true }
        if flags == [.command, .option], event.keyCode == 125 { addCaretBelow(nil); return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Editing through the delegate

    /// Every typed change passes the delegate's check first, so Make's auto-pairing and
    /// auto-indent decide as they do today.
    private var canEdit: Bool { editor?.isEditable ?? false }

    private func apply(_ edits: [TextEdit], kind: EditKind, selectionsAfter: [Selection]? = nil) {
        guard let editor, !edits.isEmpty, canEdit else { return }
        if let delegate = editor.delegate, edits.count == 1, !delegate.editor(editor, shouldChangeTextIn: edits[0].range, replacementString: edits[0].text) { return }
        buffer.apply(edits, selectionsAfter: selectionsAfter ?? carets(after: edits), kind: kind)
        editor.revealCarets()
    }

    private func guardedEdit(_ body: () -> Void) {
        guard let editor, canEdit else { return }
        if let delegate = editor.delegate, buffer.selections.count == 1 {
            let s = buffer.selections[0]
            let range = s.isCaret ? buffer.previousBoundary(before: s.head)..<s.head : s.range
            if !delegate.editor(editor, shouldChangeTextIn: range, replacementString: "") { return }
        }
        body()
        editor.revealCarets()
    }

    private func carets(after edits: [TextEdit]) -> [Selection] {
        let sorted = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var shift = 0
        return sorted.map { edit in
            let caret = edit.range.lowerBound + shift + edit.text.utf16.count
            shift += edit.text.utf16.count - edit.range.count
            return Selection(caret: caret)
        }
    }

    func setSelections(_ selections: [Selection]) {
        buffer.setSelections(selections)
        editor?.selectionChanged()
        editor?.revealCarets()
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard canEdit else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        goalX = nil
        if let marked = composingRange {
            // Committing a composition: it replaces the marked text, in the same undo step.
            composingRange = nil
            let edits = [TextEdit(range: marked, text: text)]
            buffer.apply(edits, selectionsAfter: carets(after: edits), kind: .composing)
            buffer.closeUndoGroup()
            editor?.textInputChanged()
            editor?.revealCarets()
            return
        }
        let targets: [Range<Int>] = replacementRange.location != NSNotFound
            ? [replacementRange.location..<(replacementRange.location + replacementRange.length)]
            : buffer.selections.map(\.range)
        apply(targets.map { TextEdit(range: $0, text: text) }, kind: text.contains("\n") ? .other : .typing)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard canEdit else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        goalX = nil
        // Composition happens at one caret: the first.
        let target: Range<Int>
        if let marked = composingRange {
            target = marked
        } else if replacementRange.location != NSNotFound {
            target = replacementRange.location..<(replacementRange.location + replacementRange.length)
        } else {
            target = buffer.selections[0].range
        }
        let caret = target.lowerBound + min(selectedRange.location, text.utf16.count)
        let selection = selectedRange.length > 0 ? Selection(anchor: caret, head: caret + selectedRange.length) : Selection(caret: caret)
        buffer.apply([TextEdit(range: target, text: text)], selectionsAfter: [selection], kind: .composing)
        composingRange = text.isEmpty ? nil : target.lowerBound..<(target.lowerBound + text.utf16.count)
        editor?.textInputChanged()
        editor?.revealCarets()
    }

    public func unmarkText() {
        composingRange = nil
        buffer.closeUndoGroup()
        editor?.textInputChanged()
    }

    public func selectedRange() -> NSRange {
        let range = buffer.selections[0].range
        return NSRange(location: range.lowerBound, length: range.count)
    }

    public func markedRange() -> NSRange {
        guard let composingRange else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: composingRange.lowerBound, length: composingRange.count)
    }

    public func hasMarkedText() -> Bool { composingRange != nil }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let length = buffer.text.utf16Count
        let lower = max(0, min(range.location, length))
        let upper = max(lower, min(range.location + range.length, length))
        actualRange?.pointee = NSRange(location: lower, length: upper - lower)
        return NSAttributedString(string: buffer.text.substring(lower..<upper), attributes: [.font: layout.font])
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }

    /// Where the input method puts its candidate window: under the range, on screen.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let caret = layout.caretRect(at: range.location)
        let end = layout.caretRect(at: range.location + range.length)
        let rect = CGRect(x: caret.minX, y: caret.minY, width: end.minY == caret.minY ? max(1, end.minX - caret.minX) : 1, height: caret.height)
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return NSNotFound }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return layout.offset(at: local)
    }

    public func windowLevel() -> Int { window?.level.rawValue ?? 0 }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if hasMarkedText() { inputContext?.discardMarkedText(); unmarkText() }
        let point = convert(event.locationInWindow, from: nil)
        // A folded line's "… }": opens the fold.
        if event.clickCount == 1, editor?.unfoldIfClickedPlaceholder(at: point) == true { return }
        let offset = layout.offset(at: point)
        dragGranularity = event.clickCount
        dragAddsCaret = event.modifierFlags.contains(.option) && event.clickCount == 1
        let range = unit(at: offset, granularity: event.clickCount)
        goalX = nil
        if event.modifierFlags.contains(.shift), let first = buffer.selections.first {
            dragAnchor = Selection(caret: first.anchor)
            setSelections([Selection(anchor: first.anchor, head: offset)])
        } else if dragAddsCaret {
            // ⌥-click: one more caret. Dragging from here selects a rectangle instead.
            dragAnchor = nil
            columnStart = point
            setSelections(buffer.selections + [Selection(caret: offset)])
        } else {
            dragAnchor = Selection(anchor: range.lowerBound, head: range.upperBound)
            setSelections([Selection(anchor: range.lowerBound, head: range.upperBound)])
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if let start = columnStart {
            setSelections(columnSelections(from: start, to: convert(event.locationInWindow, from: nil)))
            autoscroll(with: event)
            return
        }
        extendDrag(to: convert(event.locationInWindow, from: nil))
        // Past the edge: keep scrolling while the button is held.
        autoscroll(with: event)
        if autoscrollTimer == nil, !visibleRect.contains(convert(event.locationInWindow, from: nil)) {
            autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    guard !self.visibleRect.contains(point) else { self.autoscrollTimer?.invalidate(); self.autoscrollTimer = nil; return }
                    self.scrollToVisible(CGRect(x: 0, y: point.y, width: 1, height: 1))
                    self.extendDrag(to: point)
                }
            }
        }
    }

    public override func mouseUp(with event: NSEvent) {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        dragAnchor = nil
        columnStart = nil
    }

    /// A rectangle between two points: on each visual row it crosses, from the left edge's
    /// column to the right's (a row too short for either gets a caret at its end). The head is on
    /// the side the drag went, so extending goes on from there.
    public func columnSelections(from start: CGPoint, to end: CGPoint) -> [Selection] {
        let top = min(start.y, end.y), bottom = max(start.y, end.y)
        let height = layout.lineHeight
        var result: [Selection] = []
        var y = top
        var lastRowStart = -1
        while y <= bottom + 0.5 {
            let anchor = layout.offset(at: CGPoint(x: start.x, y: y))
            let head = layout.offset(at: CGPoint(x: end.x, y: y))
            let rowStart = layout.offset(at: CGPoint(x: 0, y: y))
            if rowStart != lastRowStart { result.append(Selection(anchor: anchor, head: head)) }
            lastRowStart = rowStart
            y += height
        }
        return result.isEmpty ? [Selection(caret: layout.offset(at: end))] : result
    }

    private func extendDrag(to point: CGPoint) {
        guard let anchor = dragAnchor else { return }
        let offset = layout.offset(at: point)
        let unit = unit(at: offset, granularity: dragGranularity)
        let lower = min(anchor.range.lowerBound, unit.lowerBound)
        let upper = max(anchor.range.upperBound, unit.upperBound)
        let head = unit.lowerBound < anchor.range.lowerBound ? lower : upper
        setSelections([Selection(anchor: head == lower ? upper : lower, head: head)])
    }

    /// What a click selects: a caret, a word (double), or a line (triple).
    private func unit(at offset: Int, granularity: Int) -> Range<Int> {
        switch granularity {
        case 2: return wordRange(at: offset)
        case 3...:
            let line = buffer.text.line(containing: offset)
            return buffer.text.offset(ofLine: line)..<min(buffer.text.utf16Count, buffer.text.range(ofLine: line).upperBound + 1)
        default: return offset..<offset
        }
    }

    // MARK: Pasteboard, undo

    /// The pasteboard used for copy and paste; tests give it a private one.
    public var pasteboard: NSPasteboard = .general

    @objc public func copy(_ sender: Any?) {
        let pieces = buffer.selections.filter { !$0.isCaret }.map { buffer.text.substring($0.range) }
        guard !pieces.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(pieces.joined(separator: "\n"), forType: .string)
    }

    @objc public func cut(_ sender: Any?) {
        copy(sender)
        let edits = buffer.selections.filter { !$0.isCaret }.map { TextEdit(range: $0.range, text: "") }
        apply(edits, kind: .other)
    }

    /// Pastes; with as many lines on the pasteboard as there are cursors, one line each.
    @objc public func paste(_ sender: Any?) {
        guard let string = pasteboard.string(forType: .string) else { return }
        let selections = buffer.selections
        let lines = string.components(separatedBy: "\n")
        let edits: [TextEdit] = selections.count > 1 && lines.count == selections.count
            ? zip(selections, lines).map { TextEdit(range: $0.range, text: $1) }
            : selections.map { TextEdit(range: $0.range, text: string) }
        apply(edits, kind: .other)
    }

    @objc public func undo(_ sender: Any?) {
        guard canEdit else { return }
        if buffer.undo() { editor?.textInputChanged(); editor?.revealCarets(); editor?.onUndoRedo?(false) }
    }

    @objc public func redo(_ sender: Any?) {
        guard canEdit else { return }
        if buffer.redo() { editor?.textInputChanged(); editor?.revealCarets(); editor?.onUndoRedo?(true) }
    }

    /// Right-click: Cut, Copy, Paste, and whatever the owner adds (Make: Jump to Definition).
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        let offset = layout.offset(at: convert(event.locationInWindow, from: nil))
        guard let editor, let delegate = editor.delegate else { return menu }
        return delegate.editor(editor, menu: menu, forCharacterAt: offset)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return buffer.selections.contains { !$0.isCaret }
        case #selector(paste(_:)): return canEdit && pasteboard.string(forType: .string) != nil
        case #selector(cut(_:)): return canEdit && buffer.selections.contains { !$0.isCaret }
        case #selector(undo(_:)): return buffer.canUndo
        case #selector(redo(_:)): return buffer.canRedo
        case #selector(performFindPanelAction(_:)), #selector(performTextFinderAction(_:)):
            return textFinder.validateAction(NSTextFinder.Action(rawValue: item.tag) ?? .showFindInterface)
        default: return true
        }
    }

    // MARK: Find (NSTextFinder)

    @objc public func performFindPanelAction(_ sender: Any?) { performTextFinderAction(sender) }

    @objc public override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        textFinder.findBarContainer = editor?.scrollView
        textFinder.isIncrementalSearchingEnabled = true
        textFinder.performAction(NSTextFinder.Action(rawValue: tag) ?? .showFindInterface)
    }

    public var string: String { buffer.string }
    public var isSelectable: Bool { true }
    public var isEditable: Bool { true }
    public var allowsMultipleSelection: Bool { true }

    public var firstSelectedRange: NSRange { selectedRange() }

    public var selectedRanges: [NSValue] {
        get { buffer.selections.map { NSValue(range: NSRange(location: $0.range.lowerBound, length: $0.range.count)) } }
        set { setSelections(newValue.map { let r = $0.rangeValue; return Selection(anchor: r.location, head: r.location + r.length) }) }
    }

    public func scrollRangeToVisible(_ range: NSRange) {
        editor?.scrollToVisible(offset: range.location)
    }

    public func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool { true }

    public func replaceCharacters(in range: NSRange, with string: String) {
        buffer.apply([TextEdit(range: range.location..<(range.location + range.length), text: string)], kind: .other)
    }

    public func didReplaceCharacters() { editor?.textInputChanged() }

    public func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        outRange.pointee = NSRange(location: 0, length: buffer.text.utf16Count)
        return self
    }

    public func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        let start = layout.caretRect(at: range.location)
        let end = layout.caretRect(at: range.location + range.length)
        return [NSValue(rect: CGRect(x: start.minX, y: start.minY, width: max(1, end.minY == start.minY ? end.minX - start.minX : 1), height: start.height))]
    }

    public var visibleCharacterRanges: [NSValue] {
        let top = layout.offset(at: CGPoint(x: 0, y: visibleRect.minY))
        let bottom = layout.offset(at: CGPoint(x: .greatestFiniteMagnitude, y: visibleRect.maxY))
        return [NSValue(range: NSRange(location: top, length: max(0, bottom - top)))]
    }

    public func drawCharacters(in range: NSRange, forContentView view: NSView) {
        // The find indicator's bouncing highlight: draw the matched text plainly.
        let text = buffer.text.substring(range.location..<(range.location + range.length))
        let caret = layout.caretRect(at: range.location)
        let attributed = NSAttributedString(string: text, attributes: [.font: layout.font, .foregroundColor: NSColor.black])
        attributed.draw(at: CGPoint(x: caret.minX, y: caret.minY + (layout.lineHeight - layout.ascent) / 4))
    }
}
