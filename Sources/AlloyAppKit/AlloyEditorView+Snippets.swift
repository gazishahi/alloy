import AlloyCore
import AlloyRender
import AppKit

/// Snippets: text with tab stops. Inserting one selects its first stop (every place it
/// appears, so a mirrored name is typed once); Tab and ⇧Tab move between stops, Escape or
/// moving away ends it, and the last stop (`$0`) is where the caret is left.
extension AlloyEditorView {
    /// Inserts `snippet` over `range`, with `extra` edits elsewhere (an import a completion
    /// adds), as one undo step, and selects its first stop.
    public func insert(_ snippet: Snippet, replacing range: Range<Int>, alsoApplying extra: [TextEdit] = []) {
        endSnippet()
        let shift = extra
            .filter { $0.range.upperBound <= range.lowerBound }
            .reduce(0) { $0 + $1.text.utf16.count - $1.range.count }
        let base = range.lowerBound + shift
        let stops = snippet.stops.map { $0.map { (base + $0.lowerBound)..<(base + $0.upperBound) } }
        let first = stops[0].map { Selection(anchor: $0.lowerBound, head: $0.upperBound) }
        buffer.apply([TextEdit(range: range, text: snippet.text)] + extra, selectionsAfter: first, kind: .other)
        if snippet.hasStops { snippetStops = SnippetStops(stops: stops) }
        selectionChanged()
        revealCarets()
    }

    /// Whether Tab is moving through a snippet's stops.
    public var isInSnippet: Bool { snippetStops != nil }

    /// To the next (1) or previous (-1) stop; false if there's no snippet to move through.
    @discardableResult
    public func moveToSnippetStop(_ step: Int) -> Bool {
        guard var stops = snippetStops else { return false }
        guard let ranges = stops.advance(by: step) else {
            if step > 0 { endSnippet() }
            return step > 0
        }
        snippetStops = stops
        isMovingBetweenStops = true
        buffer.setSelections(ranges.map { Selection(anchor: $0.lowerBound, head: $0.upperBound) })
        isMovingBetweenStops = false
        if stops.isAtLast { endSnippet() }
        selectionChanged()
        revealCarets()
        return true
    }

    public func endSnippet() {
        guard snippetStops != nil else { return }
        snippetStops = nil
        setNeedsRender()
    }

    /// After an edit: the stops follow it. Undo and replacements end the snippet.
    func snippetFollow(_ change: TextChange) {
        guard var stops = snippetStops else { return }
        guard change.reason == .edit else { return endSnippet() }
        stops.follow(change.edits)
        snippetStops = stops
    }

    /// After the selection moved: a caret outside the current stop ends the snippet.
    func snippetCheckSelection() {
        guard !isMovingBetweenStops, let stops = snippetStops else { return }
        if !buffer.selections.allSatisfy({ stops.contains($0) }) { endSnippet() }
    }

    /// The stops still ahead, faintly boxed so a person sees where Tab goes.
    var snippetDecorations: [Decoration] {
        guard let stops = snippetStops else { return [] }
        var color = theme.text
        color.w *= 0.12
        return stops.stops.enumerated().flatMap { index, ranges in
            ranges.filter { !$0.isEmpty && index != stops.current }.map { Decoration(range: $0, color: color, style: .background) }
        }
    }
}
