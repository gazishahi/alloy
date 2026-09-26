import AlloyCore
import AlloyRender
import AppKit

/// Code folding: regions from indentation (`Folding`), hidden in layout (`DocumentLayout`),
/// toggled from the gutter or the commands here.
extension AlloyEditorView {
    /// Finds the regions again, off the main thread, a moment after the text last changed.
    func scheduleFoldRegions() {
        guard isFoldingEnabled else { return }
        foldRegionsGeneration += 1
        let generation = foldRegionsGeneration
        let text = buffer.text
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            let regions = Folding.ranges(in: text)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.foldRegionsGeneration == generation else { return }
                    self.foldRegions = regions
                    self.gutter.needsDisplay = true
                }
            }
        }
    }

    func clearFolds() {
        foldRegions = []
        unfoldAll()
    }

    /// The region a line heads, if any.
    public func foldRegion(headedBy line: Int) -> ClosedRange<Int>? {
        var low = 0, high = foldRegions.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if foldRegions[mid].lowerBound < line { low = mid + 1 } else if foldRegions[mid].lowerBound > line { high = mid - 1 } else { return foldRegions[mid] }
        }
        return nil
    }

    /// Whether a line's region is folded now.
    public func isFolded(line: Int) -> Bool { documentLayout.hiddenRange(containing: line + 1)?.lowerBound == line + 1 }

    public func fold(line: Int) {
        guard let region = foldRegion(headedBy: line), region.upperBound > line else { return }
        setHidden(documentLayout.hiddenLines + [(line + 1)...region.upperBound])
        // A caret inside goes to the end of the line that stays.
        let end = buffer.text.range(ofLine: line).upperBound
        let hidden = (line + 1)...region.upperBound
        if buffer.selections.contains(where: { hidden.contains(buffer.text.line(containing: $0.head)) }) {
            setSelections([Selection(caret: end)])
        }
    }

    public func unfold(line: Int) {
        guard let hidden = documentLayout.hiddenRange(containing: line + 1) else { return }
        // Only this region's lines open; a fold nested inside it that was folded stays so,
        // if it was folded on its own before (it isn't tracked apart once merged: it opens too).
        setHidden(documentLayout.hiddenLines.filter { $0 != hidden })
    }

    public func toggleFold(line: Int) {
        if isFolded(line: line) { unfold(line: line) } else { fold(line: line) }
    }

    /// The innermost region around the caret (or the one it heads).
    private func regionAtCaret() -> ClosedRange<Int>? {
        guard let head = buffer.selections.first?.head else { return nil }
        let line = buffer.text.line(containing: head)
        return foldRegions.filter { $0.contains(line) && $0.upperBound > $0.lowerBound }.max { $0.lowerBound < $1.lowerBound }
    }

    @objc public func foldAtCaret(_ sender: Any?) {
        guard let region = regionAtCaret() else { NSSound.beep(); return }
        if isFolded(line: region.lowerBound), let outer = foldRegions.filter({ $0.lowerBound < region.lowerBound && $0.upperBound >= region.upperBound }).max(by: { $0.lowerBound < $1.lowerBound }) {
            fold(line: outer.lowerBound)
        } else {
            fold(line: region.lowerBound)
        }
    }

    @objc public func unfoldAtCaret(_ sender: Any?) {
        guard let head = buffer.selections.first?.head else { return }
        let line = buffer.text.line(containing: head)
        if isFolded(line: line) { unfold(line: line) } else if let region = regionAtCaret(), isFolded(line: region.lowerBound) { unfold(line: region.lowerBound) }
    }

    @objc public func foldAll(_ sender: Any?) {
        setHidden(foldRegions.filter { $0.upperBound > $0.lowerBound }.map { ($0.lowerBound + 1)...$0.upperBound })
        let heads = buffer.selections.map(\.head)
        if heads.contains(where: { documentLayout.isHidden(line: buffer.text.line(containing: $0)) }), let first = heads.first {
            let line = buffer.text.line(containing: first)
            let header = foldRegions.filter { $0.lowerBound < line && $0.upperBound >= line }.map(\.lowerBound).min() ?? line
            setSelections([Selection(caret: buffer.text.range(ofLine: header).upperBound)])
        }
    }

    @objc public func unfoldAll(_ sender: Any? = nil) { setHidden([]) }

    private func setHidden(_ ranges: [ClosedRange<Int>]) {
        documentLayout.setHiddenLines(ranges)
        updateDocumentHeight()
        setNeedsRender()
        gutter.needsDisplay = true
        documentView.postAccessibilityChange(value: false)
    }

    /// A selection that lands in a folded region (Find, Go to Line, a click on a search result)
    /// opens it: what's selected is never out of sight.
    func revealFoldedSelections() {
        guard !documentLayout.hiddenLines.isEmpty else { return }
        let lines = buffer.selections.map { buffer.text.line(containing: $0.head) }
        let touched = documentLayout.hiddenLines.filter { range in lines.contains { range.contains($0) } }
        guard !touched.isEmpty else { return }
        setHidden(documentLayout.hiddenLines.filter { !touched.contains($0) })
    }

    /// The owner's line colors, and the band on a folded region's first line.
    var foldAwareLineBackground: ((Int) -> SIMD4<Float>?)? {
        guard !documentLayout.hiddenLines.isEmpty else { return lineBackground }
        let own = lineBackground, band = foldedLineColor
        let headers = Set(documentLayout.hiddenLines.map { $0.lowerBound - 1 })
        return { row in own?(row) ?? (headers.contains(row) ? band : nil) }
    }
}
