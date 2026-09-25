import Foundation

/// One selection: where it started (`anchor`) and where the caret is (`head`), in UTF-16
/// offsets. Equal anchor and head is a caret.
public struct Selection: Hashable, Sendable {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    public init(caret: Int) { self.init(anchor: caret, head: caret) }

    public var range: Range<Int> { min(anchor, head)..<max(anchor, head) }
    public var isCaret: Bool { anchor == head }
}

/// A replacement: a UTF-16 range and the text that takes its place.
public struct TextEdit: Hashable, Sendable {
    public var range: Range<Int>
    public var text: String

    public init(range: Range<Int>, text: String) {
        self.range = range
        self.text = text
    }
}

/// One change as it was applied: the range in the text as it was at that moment, what was
/// there, and what replaced it. A change reports these in the order they happened, which is
/// what an incremental consumer (tree-sitter, LSP) replays.
public struct AppliedEdit: Hashable, Sendable {
    public let range: Range<Int>
    public let oldText: String
    public let newText: String

    public var inverse: AppliedEdit {
        AppliedEdit(range: range.lowerBound..<(range.lowerBound + newText.utf16.count), oldText: newText, newText: oldText)
    }
}

/// How an edit groups for undo.
public enum EditKind: Sendable {
    /// Typed characters: consecutive typing is one undo step.
    case typing
    /// Backspace and forward delete: consecutive deleting is one undo step.
    case deleting
    /// Text an input method is composing (marked text) and its commit: the whole composition
    /// is one step, however long it takes.
    case composing
    /// Everything else (paste, completion, an agent's edit) is its own step.
    case other
}

public struct TextChange: Sendable {
    /// `replace`: the owner replaced the text (an approved agent edit, a reload); not the
    /// person's edit, and outside undo.
    public enum Reason: Sendable { case edit, undo, redo, replace }
    public let edits: [AppliedEdit]
    public let reason: Reason
}

/// A document being edited: its text, its selections (as many as the user has), and its undo
/// history. Foundation only, so the whole editing model is testable without a window.
public final class TextBuffer {
    public private(set) var text: Rope
    /// Sorted, non-overlapping, never empty.
    public private(set) var selections: [Selection]
    /// Called after every change, with the edits in the order they were applied.
    public var onChange: ((TextChange) -> Void)?

    /// Consecutive typing or deleting within this long is one undo step.
    public var coalescingInterval: TimeInterval = 1.0
    /// Injectable for tests.
    public var now: () -> Date = Date.init

    private struct Snapshot {
        let text: Rope
        let selections: [Selection]
    }

    private struct UndoGroup {
        var before: Snapshot
        var after: Snapshot
        var edits: [AppliedEdit]
        var kind: EditKind
        var lastEdit: Date
        var open: Bool
    }

    private var undoStack: [UndoGroup] = []
    private var redoStack: [UndoGroup] = []

    public init(_ text: String = "") {
        self.text = Rope(text)
        selections = [Selection(caret: 0)]
    }

    public var string: String { text.string }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Selections

    /// Sets the selections: clamped, sorted, and merged where they overlap. Moving the caret
    /// closes the current undo step, as in every editor.
    public func setSelections(_ new: [Selection]) {
        selections = normalize(new)
        closeUndoGroup()
    }

    public func addSelection(_ selection: Selection) { setSelections(selections + [selection]) }

    private func normalize(_ list: [Selection]) -> [Selection] {
        let length = text.utf16Count
        let clamped = list.map { Selection(anchor: min(max(0, $0.anchor), length), head: min(max(0, $0.head), length)) }
            .sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
        var merged: [Selection] = []
        for selection in clamped {
            guard let last = merged.last else { merged.append(selection); continue }
            let overlaps = selection.range.lowerBound < last.range.upperBound
                || (selection.range == last.range)
                || (selection.isCaret && last.isCaret && selection.head == last.head)
            if overlaps {
                let lower = min(last.range.lowerBound, selection.range.lowerBound)
                let upper = max(last.range.upperBound, selection.range.upperBound)
                // Keep the direction of the selection that reaches furthest.
                merged[merged.count - 1] = last.head >= last.anchor ? Selection(anchor: lower, head: upper) : Selection(anchor: upper, head: lower)
            } else {
                merged.append(selection)
            }
        }
        return merged.isEmpty ? [Selection(caret: 0)] : merged
    }

    // MARK: Editing

    /// Applies non-overlapping edits at once, as one step. Without `selectionsAfter`, each
    /// selection moves with the text around it.
    public func apply(_ edits: [TextEdit], selectionsAfter: [Selection]? = nil, kind: EditKind = .other) {
        let length = text.utf16Count
        let sorted = edits
            .map { TextEdit(range: max(0, min($0.range.lowerBound, length))..<max(0, min($0.range.upperBound, length)), text: $0.text) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            precondition(a.range.upperBound <= b.range.lowerBound, "edits overlap")
        }
        guard sorted.contains(where: { !$0.range.isEmpty || !$0.text.isEmpty }) else { return }

        let before = Snapshot(text: text, selections: selections)
        var applied: [AppliedEdit] = []
        // Back to front, so each range is still valid in the text as it stands.
        for edit in sorted.reversed() {
            let old = text.substring(edit.range)
            text.replace(edit.range, with: edit.text)
            applied.append(AppliedEdit(range: edit.range, oldText: old, newText: edit.text))
        }
        selections = normalize(selectionsAfter ?? selections.map { Selection(anchor: Self.map($0.anchor, through: sorted), head: Self.map($0.head, through: sorted)) })
        record(before: before, edits: applied, kind: kind)
        onChange?(TextChange(edits: applied, reason: .edit))
    }

    /// Types `string` at every selection, replacing what's selected; each caret ends after it.
    public func insert(_ string: String, kind: EditKind = .typing) {
        let edits = selections.map { TextEdit(range: $0.range, text: string) }
        apply(edits, selectionsAfter: carets(after: edits), kind: string.contains("\n") ? .other : kind)
    }

    /// Backspace at every selection: a selection deletes itself, a caret the character before it.
    public func deleteBackward() {
        let edits: [TextEdit] = selections.compactMap { selection in
            if !selection.isCaret { return TextEdit(range: selection.range, text: "") }
            guard selection.head > 0 else { return nil }
            return TextEdit(range: previousBoundary(before: selection.head)..<selection.head, text: "")
        }
        guard !edits.isEmpty else { return }
        apply(edits, selectionsAfter: carets(after: edits), kind: .deleting)
    }

    /// Forward delete at every selection.
    public func deleteForward() {
        let edits: [TextEdit] = selections.compactMap { selection in
            if !selection.isCaret { return TextEdit(range: selection.range, text: "") }
            guard selection.head < text.utf16Count else { return nil }
            return TextEdit(range: selection.head..<nextBoundary(after: selection.head), text: "")
        }
        guard !edits.isEmpty else { return }
        apply(edits, selectionsAfter: carets(after: edits), kind: .deleting)
    }

    /// Where each edit's caret lands: just after its inserted text, in the text after all edits.
    private func carets(after edits: [TextEdit]) -> [Selection] {
        let sorted = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var shift = 0
        return sorted.map { edit in
            let caret = edit.range.lowerBound + shift + edit.text.utf16.count
            shift += edit.text.utf16.count - edit.range.count
            return Selection(caret: caret)
        }
    }

    /// A position after edits (sorted, pre-edit coordinates). Inside a replaced range, it moves
    /// to the end of the replacement.
    static func map(_ position: Int, through edits: [TextEdit]) -> Int {
        var shift = 0
        for edit in edits {
            if edit.range.upperBound <= position, !(edit.range.isEmpty && edit.range.lowerBound == position) {
                shift += edit.text.utf16.count - edit.range.count
            } else if edit.range.lowerBound < position {
                return edit.range.lowerBound + shift + edit.text.utf16.count
            } else {
                break
            }
        }
        return position + shift
    }

    /// The start of the character (grapheme cluster) before `offset`, so backspace removes an
    /// emoji or an accented letter whole.
    public func previousBoundary(before offset: Int) -> Int {
        let start = max(0, offset - 32)
        let window = text.substring(start..<offset)
        guard let last = window.last else { return max(0, offset - 1) }
        return offset - String(last).utf16.count
    }

    public func nextBoundary(after offset: Int) -> Int {
        let end = min(text.utf16Count, offset + 32)
        let window = text.substring(offset..<end)
        guard let first = window.first else { return min(text.utf16Count, offset + 1) }
        return offset + String(first).utf16.count
    }

    // MARK: Undo

    private func record(before: Snapshot, edits: [AppliedEdit], kind: EditKind) {
        redoStack.removeAll()
        let after = Snapshot(text: text, selections: selections)
        let time = now()
        let continues: Bool
        if let last = undoStack.last, last.open, last.kind == kind {
            continues = kind == .composing
                || (kind != .other && time.timeIntervalSince(last.lastEdit) < coalescingInterval && last.after.selections == before.selections)
        } else {
            continues = false
        }
        if continues, var last = undoStack.last {
            last.after = after
            last.edits += edits
            last.lastEdit = time
            undoStack[undoStack.count - 1] = last
            return
        }
        closeUndoGroup()
        undoStack.append(UndoGroup(before: before, after: after, edits: edits, kind: kind, lastEdit: time, open: kind != .other))
    }

    /// Ends the current undo step, so the next edit starts a new one.
    public func closeUndoGroup() {
        guard let last = undoStack.last, last.open else { return }
        undoStack[undoStack.count - 1].open = false
    }

    @discardableResult
    public func undo() -> Bool {
        guard var group = undoStack.popLast() else { return false }
        group.open = false
        text = group.before.text
        selections = group.before.selections
        redoStack.append(group)
        onChange?(TextChange(edits: group.edits.reversed().map(\.inverse), reason: .undo))
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let group = redoStack.popLast() else { return false }
        text = group.after.text
        selections = group.after.selections
        undoStack.append(group)
        onChange?(TextChange(edits: group.edits, reason: .redo))
        return true
    }

    /// Replaces the whole text with `string`, outside undo, as one edit over the span that
    /// differs (the common start and end are kept). So what follows edits (syntax, layout,
    /// selections) updates incrementally instead of starting over: an agent's change to one
    /// function re-lays and re-colors that function, not the file.
    @discardableResult
    public func replaceAll(with string: String) -> AppliedEdit? {
        var string = string
        let chunks = text.chunks
        let oldCount = text.utf8Count
        // Compared as UTF-8 bytes, a chunk at a time: no copy of either text.
        let (prefix, suffix, replacement): (Int, Int, String) = string.withUTF8 { new in
            let limit = min(oldCount, new.count)
            var prefix = 0
            for chunk in chunks where prefix < limit {
                var chunk = chunk
                let matched = chunk.withUTF8 { bytes in
                    var i = 0
                    let n = min(bytes.count, limit - prefix)
                    while i < n, bytes[i] == new[prefix + i] { i += 1 }
                    return i
                }
                prefix += matched
                if matched < chunk.utf8.count { break }
            }
            var suffix = 0
            for chunk in chunks.reversed() where prefix + suffix < limit {
                var chunk = chunk
                let matched = chunk.withUTF8 { bytes in
                    var i = 0
                    let n = min(bytes.count, limit - prefix - suffix)
                    while i < n, bytes[bytes.count - 1 - i] == new[new.count - 1 - suffix - i] { i += 1 }
                    return i
                }
                suffix += matched
                if matched < chunk.utf8.count { break }
            }
            // Both ends on character boundaries (never inside a scalar, so never inside a
            // surrogate pair). Before `prefix` the texts agree; at it, check each.
            func continues(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }
            if prefix > 0, (prefix < new.count && continues(new[prefix])) || text.utf8Offset(ofUTF16: text.utf16Offset(ofUTF8: prefix)) != prefix {
                prefix -= 1
                while prefix > 0, continues(new[prefix]) { prefix -= 1 }
            }
            while suffix > 0, continues(new[new.count - suffix]) { suffix -= 1 }
            return (prefix, suffix, String(decoding: UnsafeBufferPointer(rebasing: new[prefix..<(new.count - suffix)]), as: UTF8.self))
        }
        let range = text.utf16Offset(ofUTF8: prefix)..<text.utf16Offset(ofUTF8: oldCount - suffix)
        guard !range.isEmpty || !replacement.isEmpty else { return nil }
        let oldText = text.substring(range)
        text.replace(range, with: replacement)
        let edit = TextEdit(range: range, text: replacement)
        selections = normalize(selections.map { Selection(anchor: Self.map($0.anchor, through: [edit]), head: Self.map($0.head, through: [edit])) })
        undoStack.removeAll()
        redoStack.removeAll()
        let applied = AppliedEdit(range: range, oldText: oldText, newText: replacement)
        onChange?(TextChange(edits: [applied], reason: .replace))
        return applied
    }

    /// Replaces the whole text outside undo (loading a file, reloading it from disk).
    public func reset(_ string: String) {
        text = Rope(string)
        selections = [Selection(caret: 0)]
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
