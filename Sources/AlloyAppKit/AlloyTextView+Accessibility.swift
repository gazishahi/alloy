import AlloyCore
import AlloyRender
import AppKit

/// VoiceOver and every other assistive client (docs/DESIGN.md: accessibility is not
/// optional). A custom text view says nothing unless it implements the text-area protocol
/// itself; this is that protocol: role, value, selection, and the parameterized queries clients
/// use to read by character, word and line, and to find where text is on screen.
///
/// Lines here are logical lines (up to "\n"), so reading a line reads the whole line of code
/// however it wraps on screen.
extension AlloyTextView {
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityRoleDescription() -> String? { NSAccessibility.Role.textArea.description(with: nil) }
    public override func accessibilityLabel() -> String? { editor?.accessibilityName ?? "Editor" }
    public override func isAccessibilityEnabled() -> Bool { true }

    private var ax: TextBuffer? { editor?.buffer }

    /// Set when lines carry spoken prefixes: then every query answers about that text.
    private var spoken: SpokenText? { editor?.spokenText }

    private func toValue(_ offset: Int) -> Int {
        guard let spoken, let text = ax?.text else { return offset }
        return spoken.toValue(offset, in: text)
    }
    private func toBuffer(_ offset: Int) -> Int { spoken?.toBuffer(offset) ?? offset }
    private func valueRange(_ range: Range<Int>) -> NSRange {
        let lower = toValue(range.lowerBound), upper = toValue(range.upperBound)
        return NSRange(location: lower, length: upper - lower)
    }

    public override func accessibilityValue() -> Any? {
        if let spoken { return spoken.string as String }
        return ax?.string ?? ""
    }

    /// VoiceOver can replace the text outright; it's one undoable edit, like a paste.
    public override func setAccessibilityValue(_ value: Any?) {
        guard let editor, editor.isEditable, let string = value as? String, let buffer = ax else { return }
        buffer.apply([TextEdit(range: 0..<buffer.text.utf16Count, text: string)], kind: .other)
        editor.textInputChanged()
    }

    public override func accessibilityNumberOfCharacters() -> Int { spoken?.length ?? ax?.text.utf16Count ?? 0 }

    public override func accessibilitySelectedText() -> String? {
        guard let buffer = ax, let range = buffer.selections.first?.range else { return nil }
        if let spoken { return spoken.string.substring(with: valueRange(range)) }
        return buffer.text.substring(range)
    }

    /// Typing through an assistive client (Switch Control, Voice Control): replaces the selection.
    public override func setAccessibilitySelectedText(_ text: String?) {
        insertText(text ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        valueRange(ax?.selections.first?.range ?? 0..<0)
    }

    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        setSelections([Selection(anchor: toBuffer(range.location), head: toBuffer(range.location + range.length))])
    }

    public override func accessibilitySelectedTextRanges() -> [NSValue]? {
        ax?.selections.map { NSValue(range: valueRange($0.range)) }
    }

    public override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        guard let ranges, !ranges.isEmpty else { return }
        setSelections(ranges.map { let r = $0.rangeValue; return Selection(anchor: toBuffer(r.location), head: toBuffer(r.location + r.length)) })
    }

    public override func accessibilityInsertionPointLineNumber() -> Int {
        // As NSTextView: a selection has no insertion point.
        guard let buffer = ax, let selection = buffer.selections.first, selection.range.isEmpty else { return NSNotFound }
        return buffer.text.line(containing: selection.head)
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let editor else { return NSRange(location: 0, length: 0) }
        let viewport = editor.viewport
        let layout = editor.documentLayout
        let top = toValue(layout.offset(at: CGPoint(x: 0, y: viewport.minY)))
        let bottom = toValue(layout.offset(at: CGPoint(x: .greatestFiniteMagnitude, y: viewport.maxY)))
        return NSRange(location: top, length: max(0, bottom - top))
    }

    public override func accessibilityLine(for index: Int) -> Int {
        if let spoken { return spoken.line(ofValue: index) }
        return ax?.text.line(containing: index) ?? 0
    }

    public override func accessibilityRange(forLine line: Int) -> NSRange {
        if let spoken { return line >= 0 && line < spoken.lineCount ? spoken.rangeOfLine(line) : NSRange(location: NSNotFound, length: 0) }
        guard let text = ax?.text, line >= 0, line < text.lineCount else { return NSRange(location: NSNotFound, length: 0) }
        // Including its "\n", as NSTextView reports a line.
        let start = text.offset(ofLine: line)
        let end = line + 1 < text.lineCount ? text.offset(ofLine: line + 1) : text.utf16Count
        return NSRange(location: start, length: end - start)
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        if let spoken {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: spoken.length))
            return spoken.string.substring(with: clamped)
        }
        return ax?.text.substring(range.location..<(range.location + range.length))
    }

    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let string = accessibilityString(for: range), let editor else { return nil }
        // Assistive clients live in another process, so the font goes in the AX form (a
        // dictionary), not as an NSFont, which doesn't cross; without it the string comes back nil.
        let font = editor.documentLayout.font
        let description: [NSAccessibility.FontAttributeKey: Any] = [
            .fontName: CTFontCopyPostScriptName(font) as String,
            .fontFamily: CTFontCopyFamilyName(font) as String,
            .visibleName: CTFontCopyDisplayName(font) as String,
            .fontSize: CTFontGetSize(font),
        ]
        return NSAttributedString(string: string, attributes: [.accessibilityFont: description])
    }

    /// Where a range is on screen: VoiceOver's cursor outline, and zoom following the caret.
    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let editor, let window else { return .zero }
        let layout = editor.documentLayout
        let start = layout.caretRect(at: toBuffer(range.location))
        let end = layout.caretRect(at: toBuffer(range.location + range.length))
        let rect: CGRect
        if end.minY == start.minY {
            rect = CGRect(x: start.minX, y: start.minY, width: max(1, end.minX - start.minX), height: start.height)
        } else {
            // Across rows: from the start row's top to the end row's bottom, the text's full width.
            rect = CGRect(x: layout.insets.width, y: start.minY, width: max(1, bounds.width - layout.insets.width * 2), height: end.maxY - start.minY)
        }
        return window.convertToScreen(convert(rect, to: nil))
    }

    public override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let editor, let window else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let layout = editor.documentLayout
        // The character under the point: `offset(at:)` gives the nearest caret position, which
        // past a character's middle is the one after it.
        var offset = layout.offset(at: local)
        let caret = layout.caretRect(at: offset)
        if offset > 0, caret.minX > local.x, local.y >= caret.minY, local.y < caret.maxY, let buffer = ax {
            offset = buffer.previousBoundary(before: offset)
        }
        return accessibilityRange(for: toValue(offset))
    }

    /// The composed character at an index (a whole emoji, an accented letter).
    public override func accessibilityRange(for index: Int) -> NSRange {
        if let spoken {
            guard index >= 0, index < spoken.length else { return NSRange(location: NSNotFound, length: 0) }
            return spoken.string.rangeOfComposedCharacterSequence(at: index)
        }
        guard let buffer = ax, index >= 0, index < buffer.text.utf16Count else { return NSRange(location: NSNotFound, length: 0) }
        let text = buffer.text
        let line = text.line(containing: index)
        let start = text.offset(ofLine: line)
        let end = line + 1 < text.lineCount ? text.offset(ofLine: line + 1) : text.utf16Count
        let cluster = (text.substring(start..<end) as NSString).rangeOfComposedCharacterSequence(at: index - start)
        return NSRange(location: start + cluster.location, length: cluster.length)
    }

    public override func accessibilityStyleRange(for index: Int) -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    /// Tells assistive clients the text or the selection moved.
    func postAccessibilityChange(value: Bool) {
        if value { NSAccessibility.post(element: self, notification: .valueChanged) }
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }
}
