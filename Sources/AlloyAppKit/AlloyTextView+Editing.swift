import AlloyCore
import AppKit

/// The editing commands every code editor has, as named actions (menus reach them through the
/// responder chain; a keymap binds them): comment, move, duplicate and delete lines, indent,
/// join, select occurrences, expand the selection, go to the matching bracket. Each works on
/// every selection, and each is one undo step.
extension AlloyTextView {
    private var text: Rope { editor!.buffer.text }
    private var selections: [Selection] { editor!.buffer.selections }
    private var editable: Bool { editor?.isEditable == true }

    /// Applies edits (in the text as it is) and puts the selections where given, as one step.
    private func perform(_ edits: [TextEdit], selectionsAfter: [Selection]) {
        guard let editor, editable, !edits.isEmpty else { return }
        editor.buffer.apply(edits, selectionsAfter: selectionsAfter, kind: .other)
        editor.selectionChanged()
        editor.revealCarets()
    }

    /// The lines each selection covers, merged where they touch (a selection ending at a line's
    /// start doesn't take that line).
    private func lineBlocks() -> [ClosedRange<Int>] {
        var blocks: [ClosedRange<Int>] = []
        for selection in selections.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let first = text.line(containing: selection.range.lowerBound)
            var last = text.line(containing: selection.range.upperBound)
            if last > first, selection.range.upperBound == text.offset(ofLine: last) { last -= 1 }
            if let previous = blocks.last, first <= previous.upperBound + 1 {
                blocks[blocks.count - 1] = previous.lowerBound...max(previous.upperBound, last)
            } else {
                blocks.append(first...last)
            }
        }
        return blocks
    }

    /// A block of lines as a range, with its line break if it has one.
    private func range(ofLines block: ClosedRange<Int>) -> Range<Int> {
        let start = text.offset(ofLine: block.lowerBound)
        let end = block.upperBound + 1 < text.lineCount ? text.offset(ofLine: block.upperBound + 1) : text.utf16Count
        return start..<end
    }

    private func leadingWhitespace(_ line: String) -> Int {
        line.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
    }

    // MARK: Lines

    /// ⌘/: the owner's line comment (`//`, `#`) added to the selected lines at their shared
    /// indent, or taken off if every non-blank one has it.
    @objc public func toggleLineComment(_ sender: Any?) {
        guard let token = editor?.lineComment, !token.isEmpty else { return NSSound.beep() }
        let tokenLength = token.utf16.count
        var edits: [TextEdit] = []
        for block in lineBlocks() {
            let lines = block.map { (line: $0, text: text.substring(text.range(ofLine: $0))) }
            let nonBlank = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !nonBlank.isEmpty else { continue }
            let commented = nonBlank.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix(token) }
            if commented {
                for line in nonBlank {
                    let start = text.offset(ofLine: line.line) + leadingWhitespace(line.text)
                    let after = Array(line.text.utf16)
                    let at = leadingWhitespace(line.text) + tokenLength
                    let space = at < after.count && after[at] == 0x20 ? 1 : 0
                    edits.append(TextEdit(range: start..<(start + tokenLength + space), text: ""))
                }
            } else {
                let indent = nonBlank.map { leadingWhitespace($0.text) }.min() ?? 0
                for line in nonBlank {
                    let at = text.offset(ofLine: line.line) + indent
                    edits.append(TextEdit(range: at..<at, text: token + " "))
                }
            }
        }
        guard let editor, editable, !edits.isEmpty else { return }
        // Selections follow the text around them.
        editor.buffer.apply(edits, kind: .other)
        editor.selectionChanged()
    }

    @objc public func moveLinesUp(_ sender: Any?) { moveLines(by: -1) }
    @objc public func moveLinesDown(_ sender: Any?) { moveLines(by: 1) }

    /// ⌥⌘[ / ⌥⌘] (Xcode), ⌥↑ / ⌥↓ (VS Code): the selected lines swap with the line past them;
    /// the selections go with them.
    private func moveLines(by direction: Int) {
        let blocks = lineBlocks()
        guard !blocks.isEmpty else { return }
        // At the document's edge, nothing moves (as in every editor).
        if direction < 0, blocks[0].lowerBound == 0 { return }
        if direction > 0, blocks[blocks.count - 1].upperBound >= text.lineCount - 1 { return }
        var edits: [TextEdit] = []
        var shifts: [(range: ClosedRange<Int>, by: Int)] = []
        for block in blocks {
            let neighbor = direction < 0 ? block.lowerBound - 1 : block.upperBound + 1
            let span = min(neighbor, block.lowerBound)...max(neighbor, block.upperBound)
            // Whole lines without their breaks, reordered, joined again: the last line's missing
            // break takes care of itself.
            let lines = span.map { text.substring(text.range(ofLine: $0)) }
            let moved = direction < 0 ? Array(lines.dropFirst()) + [lines[0]] : [lines[lines.count - 1]] + Array(lines.dropLast())
            let region = text.offset(ofLine: span.lowerBound)..<text.range(ofLine: span.upperBound).upperBound
            edits.append(TextEdit(range: region, text: moved.joined(separator: "\n")))
            let neighborLength = text.range(ofLine: neighbor).count + 1
            shifts.append((text.offset(ofLine: block.lowerBound)...text.range(ofLine: block.upperBound).upperBound, direction < 0 ? -neighborLength : neighborLength))
        }
        let after = selections.map { selection -> Selection in
            let by = shifts.first { $0.range.contains(selection.range.lowerBound) }?.by ?? 0
            return Selection(anchor: selection.anchor + by, head: selection.head + by)
        }
        perform(edits, selectionsAfter: after)
    }

    /// ⌘D (Xcode's Duplicate), ⇧⌥↓ (VS Code): each block of lines copied below itself; the
    /// selections move onto the copy.
    @objc public func duplicateLines(_ sender: Any?) {
        var edits: [TextEdit] = []
        var shifts: [(range: Range<Int>, by: Int)] = []
        for block in lineBlocks() {
            let whole = range(ofLines: block)
            var copy = text.substring(whole)
            if !copy.hasSuffix("\n") { copy = "\n" + copy }
            edits.append(TextEdit(range: whole.upperBound..<whole.upperBound, text: copy))
            shifts.append((whole, copy.utf16.count))
        }
        // Each selection moves by its own block's copy, plus every copy before it.
        let after = selections.map { selection -> Selection in
            let before = shifts.filter { $0.range.upperBound <= selection.range.lowerBound && !$0.range.contains(selection.range.lowerBound) }.reduce(0) { $0 + $1.by }
            let own = shifts.first { $0.range.contains(selection.range.lowerBound) || $0.range.upperBound == selection.range.lowerBound }?.by ?? 0
            return Selection(anchor: selection.anchor + before + own, head: selection.head + before + own)
        }
        perform(edits, selectionsAfter: after)
    }

    /// ⇧⌘K (VS Code), ⌘⌫ (JetBrains): the selected lines, gone.
    @objc public func deleteLines(_ sender: Any?) {
        let blocks = lineBlocks()
        var edits: [TextEdit] = []
        var carets: [Selection] = []
        var removed = 0
        for block in blocks {
            var whole = range(ofLines: block)
            // The last line: take the break before it instead.
            if block.upperBound == text.lineCount - 1, whole.lowerBound > 0, !text.substring(whole).hasSuffix("\n") { whole = (whole.lowerBound - 1)..<whole.upperBound }
            edits.append(TextEdit(range: whole, text: ""))
            carets.append(Selection(caret: max(0, whole.lowerBound - removed)))
            removed += whole.count
        }
        perform(edits, selectionsAfter: carets)
    }

    /// ⌘] / ⌘[: the selected lines, one indent further in or out.
    @objc public func indentLines(_ sender: Any?) { shiftLines(inward: true) }
    @objc public func outdentLines(_ sender: Any?) { shiftLines(inward: false) }

    private func shiftLines(inward: Bool) {
        let unit = editor?.indentUnit ?? "    "
        var edits: [TextEdit] = []
        for block in lineBlocks() {
            for line in block {
                let start = text.offset(ofLine: line)
                let content = text.substring(text.range(ofLine: line))
                if inward {
                    guard !content.isEmpty else { continue }
                    edits.append(TextEdit(range: start..<start, text: unit))
                } else {
                    let units = Array(content.utf16)
                    var count = 0
                    if units.first == 0x09 { count = 1 } else { while count < unit.utf16.count, count < units.count, units[count] == 0x20 { count += 1 } }
                    if count > 0 { edits.append(TextEdit(range: start..<(start + count), text: "")) }
                }
            }
        }
        guard let editor, editable, !edits.isEmpty else { return }
        editor.buffer.apply(edits, kind: .other)
        editor.selectionChanged()
    }

    /// ⌃J / ⌃⇧J: each line joined with the one after it, the indent between them one space.
    @objc public func joinLines(_ sender: Any?) {
        var edits: [TextEdit] = []
        for block in lineBlocks() {
            let last = block.lowerBound == block.upperBound ? block.upperBound : block.upperBound - 1
            for line in block.lowerBound...last where line + 1 < text.lineCount {
                let end = text.range(ofLine: line).upperBound
                let next = text.substring(text.range(ofLine: line + 1))
                let trailing = text.substring(text.range(ofLine: line)).utf16.reversed().prefix { $0 == 0x20 || $0 == 0x09 }.count
                let joiner = next.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " "
                edits.append(TextEdit(range: (end - trailing)..<(end + 1 + leadingWhitespace(next)), text: joiner))
            }
        }
        guard let editor, editable, !edits.isEmpty else { return }
        editor.buffer.apply(edits, kind: .other)
        editor.selectionChanged()
    }

    // MARK: Selections

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24 || unit > 0x7F
    }

    /// The word around an offset (empty if none).
    func wordRange(around offset: Int) -> Range<Int> {
        let line = text.range(ofLine: text.line(containing: offset))
        let units = Array(text.substring(line).utf16)
        var start = offset - line.lowerBound, end = start
        while start > 0, Self.isWordUnit(units[start - 1]) { start -= 1 }
        while end < units.count, Self.isWordUnit(units[end]) { end += 1 }
        return (line.lowerBound + start)..<(line.lowerBound + end)
    }

    /// ⌘D (VS Code), ⌃G (JetBrains): a caret selects its word; a selection adds the next place
    /// its text appears (wrapping at the end).
    @objc public func selectNextOccurrence(_ sender: Any?) {
        guard let last = selections.last else { return }
        if last.isCaret {
            let word = wordRange(around: last.head)
            guard !word.isEmpty else { return NSSound.beep() }
            return setSelections(selections.dropLast() + [Selection(anchor: word.lowerBound, head: word.upperBound)])
        }
        let needle = text.substring(last.range)
        let haystack = text.string as NSString
        let taken = Set(selections.map(\.range))
        var from = last.range.upperBound
        for _ in 0..<2 {
            var search = NSRange(location: from, length: haystack.length - from)
            while search.length > 0 {
                let found = haystack.range(of: needle, options: [], range: search)
                guard found.location != NSNotFound else { break }
                let range = found.location..<NSMaxRange(found)
                if !taken.contains(range) { return setSelections(selections + [Selection(anchor: range.lowerBound, head: range.upperBound)]) }
                search = NSRange(location: NSMaxRange(found), length: haystack.length - NSMaxRange(found))
            }
            from = 0   // and round again from the top
        }
        NSSound.beep()
    }

    /// ⇧⌘L (VS Code), ⌃⌘G (JetBrains): every place the selection's text (or the caret's word)
    /// appears, selected.
    @objc public func selectAllOccurrences(_ sender: Any?) {
        guard let last = selections.last else { return }
        let range = last.isCaret ? wordRange(around: last.head) : last.range
        guard !range.isEmpty else { return NSSound.beep() }
        let needle = text.substring(range)
        let haystack = text.string as NSString
        var found: [Selection] = []
        var search = NSRange(location: 0, length: haystack.length)
        while let match = Optional(haystack.range(of: needle, options: [], range: search)), match.location != NSNotFound {
            found.append(Selection(anchor: match.location, head: NSMaxRange(match)))
            search = NSRange(location: NSMaxRange(match), length: haystack.length - NSMaxRange(match))
        }
        setSelections(found)
    }

    /// Expand Selection: the owner's next enclosing range (a syntax node) around each
    /// selection; Shrink goes back through what it grew from.
    @objc public func expandSelection(_ sender: Any?) {
        guard let editor, let expand = editor.onExpandSelection else { return NSSound.beep() }
        let grown = selections.map { selection -> Selection in
            guard let next = expand(selection.range), next != selection.range else { return selection }
            return Selection(anchor: next.lowerBound, head: next.upperBound)
        }
        guard grown != selections else { return NSSound.beep() }
        editor.selectionHistory.append(selections)
        editor.isExpandingSelection = true
        setSelections(grown)
    }

    @objc public func shrinkSelection(_ sender: Any?) {
        guard let editor, let previous = editor.selectionHistory.popLast() else { return NSSound.beep() }
        editor.isExpandingSelection = true
        setSelections(previous)
    }

    /// ⇧⌘\ (VS Code), ⌃⇧M (JetBrains): to the bracket matching the one at (or before) the caret.
    @objc public func goToMatchingBracket(_ sender: Any?) {
        guard let caret = selections.last?.head else { return }
        let pairs: [UInt16: (UInt16, Bool)] = [0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true),
                                               0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false)]
        let length = text.utf16Count
        for at in [caret, caret - 1] where at >= 0 && at < length {
            let unit = text.substring(at..<(at + 1)).utf16.first ?? 0
            guard let (other, forward) = pairs[unit] else { continue }
            let window = forward ? at..<min(length, at + 200_000) : max(0, at - 200_000)..<(at + 1)
            let units = Array(text.substring(window).utf16)
            var depth = 0
            let indices = forward ? Array(units.indices) : Array(units.indices.reversed())
            for i in indices {
                if units[i] == unit { depth += 1 } else if units[i] == other {
                    depth -= 1
                    if depth == 0 {
                        let target = window.lowerBound + i
                        return setSelections([Selection(caret: forward ? target + 1 : target)])
                    }
                }
            }
        }
        NSSound.beep()
    }
}
