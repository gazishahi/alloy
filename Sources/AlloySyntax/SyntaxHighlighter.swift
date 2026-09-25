import AlloyCore
import AlloyRender
import Foundation
import QuartzCore
@preconcurrency import SwiftTreeSitter

/// Colors for highlight captures. A capture takes the color of its longest matching name
/// prefix ("function.method" falls back to "function"); a capture with no color leaves the text
/// under it as it was, as tree-sitter's own highlighter does.
public struct SyntaxTheme: Sendable {
    public var colors: [String: SIMD4<Float>]

    public init(colors: [String: SIMD4<Float>]) { self.colors = colors }

    public func color(for capture: String) -> SIMD4<Float>? {
        var name = Substring(capture)
        while true {
            if let color = colors[String(name)] { return color }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = name[..<dot]
        }
    }

    /// Side's palette (the regex highlighter's colors), light and dark.
    public static func side(dark: Bool) -> SyntaxTheme {
        func pick(_ d: SIMD4<Float>, _ l: SIMD4<Float>) -> SIMD4<Float> { dark ? d : l }
        let keyword = pick([0.78, 0.48, 0.96, 1], [0.55, 0.2, 0.75, 1])
        let string = pick([0.94, 0.60, 0.44, 1], [0.72, 0.3, 0.12, 1])
        let comment = pick([0.45, 0.45, 0.45, 1], [0.50, 0.50, 0.50, 1])
        let number = pick([0.68, 0.80, 0.98, 1], [0.15, 0.35, 0.7, 1])
        let type = pick([0.98, 0.78, 0.45, 1], [0.62, 0.4, 0.05, 1])
        let function = pick([0.92, 0.87, 0.58, 1], [0.5, 0.42, 0.05, 1])
        let property = pick([0.56, 0.82, 0.92, 1], [0.1, 0.45, 0.6, 1])
        let heading = pick([0.55, 0.85, 0.65, 1], [0.12, 0.5, 0.3, 1])
        let tag = pick([0.42, 0.82, 0.66, 1], [0.1, 0.5, 0.38, 1])
        return SyntaxTheme(colors: [
            "keyword": keyword, "conditional": keyword, "repeat": keyword, "include": keyword, "exception": keyword,
            "storageclass": keyword, "boolean": keyword, "constant.builtin": keyword, "variable.builtin": keyword,
            "attribute": keyword, "label": keyword,
            "string": string, "character": string, "escape": number, "string.escape": number, "string.regex": string,
            "comment": comment, "spell": comment,
            "number": number, "float": number, "constant.numeric": number,
            "type": type, "type.builtin": type, "constructor": type, "namespace": type, "module": type,
            "function": function, "method": function, "function.method": function, "function.call": function, "function.macro": function,
            "property": property, "field": property, "variable.member": property, "variable.parameter": property, "parameter": property,
            "tag": tag, "tag.attribute": property,
            "text.title": heading, "markup.heading": heading, "punctuation.special": heading,
            "text.literal": string, "markup.raw": string, "text.uri": property, "markup.link": property, "text.reference": property,
        ])
    }
}

/// A document's syntax: a tree-sitter tree kept current with every edit (incremental reparse
/// from the rope, as UTF-16), and colors per line from the highlight query, cached until an edit
/// or a reparse changes that line.
@MainActor
public final class SyntaxHighlighter {
    public let language: SyntaxLanguage
    public var theme: SyntaxTheme { didSet { lineCache.removeAll() } }
    public private(set) var text: Rope
    /// How long the last parse took, and the last line-coloring pass (for the budgets).
    public private(set) var lastParseMilliseconds = 0.0
    /// A first parse of a big file runs in the background; until it lands, lines are plain.
    public private(set) var isReady = false
    /// Told when colors changed beyond the lines just edited (a first parse landing, or an edit
    /// that re-colored lines further away, like opening a block comment).
    public var onInvalidate: (() -> Void)?

    private let parser = Parser()
    private var tree: MutableTree?
    private var lineCache: [Int: [StyleSpan]] = [:]
    /// Files smaller than this get their first parse on the spot; bigger ones in the background.
    public static let synchronousLimit = 1_000_000
    /// Reparses faster than this stay on the main thread (no frame of stale color); slower
    /// ones move to the background. Measured per file, since grammars differ by 50× (Swift's
    /// reuses little on an edit; JavaScript's reuses nearly everything).
    public static let synchronousBudgetMilliseconds = 4.0
    /// About 1,000 lines: the largest file whose worst-case reparse fits the budget.
    public static let synchronousSizeLimit = 32_000
    /// A query cursor steps over a node's children one by one (about 2 µs each): up to this
    /// many is cheap enough to query through.
    static let walkableChildren = 512
    /// Tests: query every line from the root, the slow way the shortcut must agree with.
    nonisolated(unsafe) static var queryFromRoot = false

    private let queue = DispatchQueue(label: "alloy.syntax.parse", qos: .userInitiated)
    private nonisolated(unsafe) let backgroundParser = Parser()
    private var parseInFlight = false
    /// Edits that arrived while a background parse ran: replayed onto its tree when it lands.
    private var editsDuringParse: [InputEdit] = []
    private var needsParse = false

    public init?(fileExtension: String, text: Rope, theme: SyntaxTheme = .side(dark: false)) {
        guard let language = SyntaxLanguage.forExtension(fileExtension) else { return nil }
        self.language = language
        self.theme = theme
        self.text = text
        try? parser.setLanguage(language.language)
        try? backgroundParser.setLanguage(language.language)
        if text.utf16Count <= Self.synchronousLimit {
            let start = CACurrentMediaTime()
            tree = Self.parse(parser, text: text, oldTree: nil)
            lastParseMilliseconds = (CACurrentMediaTime() - start) * 1000
            isReady = true
        } else {
            needsParse = true
            parseInBackground()
        }
    }

    /// Reparses the current text on the parse queue, from the current tree (edited to match,
    /// so the reparse is incremental), and swaps the result in when it lands.
    private func parseInBackground() {
        guard !parseInFlight else { return }
        parseInFlight = true
        needsParse = false
        editsDuringParse = []
        let snapshot = text
        let base = tree?.copy()
        let started = CACurrentMediaTime()
        let parser = backgroundParser
        let box = ParseResult()
        queue.async {
            let old = base?.mutableCopy()
            let parsedTree = Self.parse(parser, text: snapshot, oldTree: old)
            if let parsed = parsedTree {
                box.changed = old.map { parsed.changedRanges(from: $0) }
                box.tree = parsed.copy()
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.backgroundParseLanded(box, started: started) }
            }
        }
    }

    private func backgroundParseLanded(_ result: ParseResult, started: CFTimeInterval) {
        parseInFlight = false
        guard let landed = result.tree?.mutableCopy() else { return }
        let caughtUp = editsDuringParse.isEmpty
        for edit in editsDuringParse { landed.edit(edit) }
        editsDuringParse = []
        tree = landed
        lastParseMilliseconds = (CACurrentMediaTime() - started) * 1000
        if !isReady || !caughtUp || result.changed == nil {
            lineCache.removeAll()
        } else {
            for range in result.changed ?? [] {
                let lower = Int(range.points.lowerBound.row)
                let upper = Int(range.points.upperBound.row)
                for line in lower...max(lower, upper) { lineCache.removeValue(forKey: line) }
            }
        }
        isReady = true
        onInvalidate?()
        // Edits came in meanwhile: their reparse is next.
        if needsParse || !caughtUp { parseInBackground() }
    }

    /// Follows the buffer: edits in the order they were applied, and the text after them.
    public func apply(_ edits: [AppliedEdit], newText: Rope) {
        var working = text
        var inputs: [InputEdit] = []
        var firstChangedLine = Int.max
        var lineDelta = 0
        var lastOldLine = 0
        for edit in edits {
            let start = working.position(of: edit.range.lowerBound)
            let oldEnd = working.position(of: edit.range.upperBound)
            let after = working.replacing(edit.range, with: edit.newText)
            let newEnd = after.position(of: edit.range.lowerBound + edit.newText.utf16.count)
            inputs.append(InputEdit(
                startByte: UInt32(edit.range.lowerBound * 2),
                oldEndByte: UInt32(edit.range.upperBound * 2),
                newEndByte: UInt32((edit.range.lowerBound + edit.newText.utf16.count) * 2),
                startPoint: Point(row: start.line, column: start.column * 2),
                oldEndPoint: Point(row: oldEnd.line, column: oldEnd.column * 2),
                newEndPoint: Point(row: newEnd.line, column: newEnd.column * 2)))
            firstChangedLine = min(firstChangedLine, start.line)
            lastOldLine = max(lastOldLine, oldEnd.line)
            lineDelta += newEnd.line - oldEnd.line
            working = after
        }
        text = newText
        shiftCache(from: firstChangedLine, throughOld: lastOldLine, by: lineDelta, edited: edits.count > 1)
        // The current tree follows the edit at once (cheap), so colors stay on their text
        // until the reparse lands.
        for input in inputs { tree?.edit(input) }

        if parseInFlight {
            editsDuringParse += inputs
            needsParse = true
            return
        }
        // On the main thread only for small files that parse fast: a grammar's reparse cost
        // depends on where the edit is (Swift reuses a lot for an edit at the top, little for one
        // deep in a long body), so the last parse's time alone predicts nothing for a big file.
        guard isReady, let old = tree, text.utf16Count <= Self.synchronousSizeLimit,
              lastParseMilliseconds < Self.synchronousBudgetMilliseconds else {
            needsParse = true
            parseInBackground()
            return
        }
        let start = CACurrentMediaTime()
        let reparsed = Self.parse(parser, text: text, oldTree: old)
        lastParseMilliseconds = (CACurrentMediaTime() - start) * 1000
        guard let reparsed else { return }
        // Lines whose colors the reparse changed, beyond the ones edited.
        var farChange = false
        for range in reparsed.changedRanges(from: old) {
            let lower = Int(range.points.lowerBound.row)
            let upper = Int(range.points.upperBound.row)
            for line in lower...max(lower, upper) where lineCache.removeValue(forKey: line) != nil { farChange = true }
        }
        tree = reparsed
        if farChange { onInvalidate?() }
    }

    /// Replaces the text wholesale (a reload).
    public func reset(_ newText: Rope) {
        text = newText
        lineCache.removeAll()
        tree = nil
        isReady = false
        editsDuringParse = []
        if newText.utf16Count <= Self.synchronousLimit, !parseInFlight {
            let start = CACurrentMediaTime()
            tree = Self.parse(parser, text: newText, oldTree: nil)
            lastParseMilliseconds = (CACurrentMediaTime() - start) * 1000
            isReady = true
        } else {
            needsParse = true
            parseInBackground()
        }
    }

    /// Waits for a background parse to land (tests, and a caller that needs final colors now).
    public func waitForParse(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while (parseInFlight || needsParse), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    /// Cached lines move with the text: lines before the edit keep theirs, lines after it
    /// shift by the change in line count, the edited ones are recolored when next drawn.
    private func shiftCache(from first: Int, throughOld last: Int, by delta: Int, edited multiple: Bool) {
        guard first != .max else { return }
        if multiple { lineCache.removeAll(); return }
        var shifted: [Int: [StyleSpan]] = [:]
        for (line, spans) in lineCache {
            if line < first { shifted[line] = spans }
            else if line > last { shifted[line + delta] = spans }
        }
        lineCache = shifted
    }

    /// Colors for a line, relative to its start, sorted and non-overlapping.
    public func spans(forLine line: Int) -> [StyleSpan] {
        if let cached = lineCache[line] { return cached }
        guard isReady, let tree, let root = tree.rootNode else { return [] }
        let lineRange = text.range(ofLine: line)
        guard !lineRange.isEmpty else { lineCache[line] = []; return [] }
        let length = lineRange.count
        // One color slot per UTF-16 unit; captures paint in precedence order.
        var paint = [Int16](repeating: -1, count: length)
        var palette: [SIMD4<Float>] = []
        var paletteIndex: [String: Int16] = [:]

        let bytes = UInt32(lineRange.lowerBound * 2)..<UInt32(lineRange.upperBound * 2)
        let text = self.text
        let context = Predicate.Context(textProvider: { range, _ in text.substring(range.location..<(range.location + range.length)) })
        var captures: [(lower: Int, upper: Int, pattern: Int, order: Int, name: String)] = []
        var order = 0
        func run(on node: Node) {
            let cursor = language.highlights.execute(node: node, in: tree)
            cursor.setByteRange(range: bytes)
            while let match = cursor.next() {
                guard match.allowed(in: context) else { continue }
                for capture in match.captures {
                    guard let name = capture.name, theme.color(for: name) != nil else { continue }
                    let range = capture.node.range
                    let lower = max(range.location, lineRange.lowerBound)
                    let upper = min(range.location + range.length, lineRange.upperBound)
                    guard lower < upper else { continue }
                    captures.append((lower, upper, match.patternIndex, order, name))
                    order += 1
                }
            }
        }
        /// The container's own patterns, from one of its children: a match counts only if it
        /// starts at that child, as it would have under the container.
        func runCompanions(_ container: ContainerPatterns, on child: Node, allowed: Set<Int>) {
            let cursor = container.query.execute(node: child, in: tree)
            cursor.setByteRange(range: bytes)
            while let match = cursor.next() {
                guard allowed.contains(match.patternIndex), match.allowed(in: context) else { continue }
                let entry = container.entries[match.patternIndex]
                guard child.nodeType == entry.root else { continue }
                for capture in match.captures {
                    // The pattern's root must be this child, not a same-typed node deeper in it.
                    var node: Node? = capture.node
                    while let current = node, current.nodeType != entry.root { node = current.parent }
                    guard let rootNode = node, rootNode.byteRange == child.byteRange else { continue }
                    guard let name = capture.name, theme.color(for: name) != nil else { continue }
                    let range = capture.node.range
                    let lower = max(range.location, lineRange.lowerBound)
                    let upper = min(range.location + range.length, lineRange.upperBound)
                    guard lower < upper else { continue }
                    captures.append((lower, upper, entry.originalIndex, order, name))
                    order += 1
                }
            }
        }
        // Start from the node that holds the line, not the root: a query cursor limited to a
        // range still steps over every sibling before it, which in a body of 40,000
        // statements costs ~80 ms a line. In a container that large, jump to the first child at
        // the line (tree-sitter's byte lookup descends its balanced internals) and query only the
        // children the line touches.
        var holder = Self.queryFromRoot ? root : (root.descendant(in: bytes) ?? root)
        // Patterns often match from a node's parent or grandparent (`(modifiers (attribute))`,
        // a fenced code block around its content): climb a few levels, but never into a
        // container with thousands of children, which is the slow case.
        // Climbing into an ancestor means walking everything under it, so only from a node that
        // is itself walkable; a huge container keeps the per-child path below.
        var climbed = 0
        while holder.childCount <= Self.walkableChildren, climbed < 6, let parent = holder.parent, parent.childCount <= Self.walkableChildren {
            holder = parent
            climbed += 1
        }
        if holder.childCount <= Self.walkableChildren || Self.queryFromRoot {
            run(on: holder)
        } else {
            let cursor = holder.treeCursor
            let containerType = holder.nodeType ?? ""
            let companions = language.containerPatterns?.entries.enumerated().filter { $0.element.container == containerType } ?? []
            if cursor.goToFirstChild(for: bytes.lowerBound) {
                repeat {
                    guard let child = cursor.currentNode else { break }
                    if child.byteRange.lowerBound >= bytes.upperBound { break }
                    run(on: child)
                    if !companions.isEmpty, let container = language.containerPatterns { runCompanions(container, on: child, allowed: Set(companions.map(\.offset))) }
                } while cursor.gotoNextSibling()
            }
        }
        // Outer before inner (inner nodes win), then pattern order (later patterns win).
        captures.sort { a, b in
            let aStart = a.lower, bStart = b.lower
            let aLength = a.upper - a.lower, bLength = b.upper - b.lower
            if aLength != bLength { return aLength > bLength }
            if aStart != bStart { return aStart < bStart }
            if a.pattern != b.pattern { return a.pattern < b.pattern }
            return a.order < b.order
        }
        for capture in captures {
            guard let color = theme.color(for: capture.name) else { continue }
            let index: Int16
            if let existing = paletteIndex[capture.name] { index = existing } else {
                index = Int16(palette.count)
                palette.append(color)
                paletteIndex[capture.name] = index
            }
            for unit in (capture.lower - lineRange.lowerBound)..<(capture.upper - lineRange.lowerBound) { paint[unit] = index }
        }
        var spans: [StyleSpan] = []
        var start = 0
        while start < length {
            let value = paint[start]
            var end = start + 1
            while end < length, paint[end] == value { end += 1 }
            if value >= 0 { spans.append(StyleSpan(range: start..<end, color: palette[Int(value)])) }
            start = end
        }
        lineCache[line] = spans
        return spans
    }

    /// The whole document's root node kind (tests, diagnostics).
    public var rootKind: String? { tree?.rootNode?.nodeType }

    /// An S-expression of the tree (tests).
    public var treeDescription: String { tree?.rootNode?.sExpressionString ?? "" }

    nonisolated static func parse(_ parser: Parser, text: Rope, oldTree: MutableTree?) -> MutableTree? {
        let total = text.utf16Count
        // UTF-16 (little-endian) input, the parser's default: byte offsets are UTF-16 offsets × 2.
        return parser.parse(tree: oldTree) { byteOffset, _ in
            let start = byteOffset / 2
            guard start < total else { return nil }
            let chunk = text.substring(start..<min(total, start + 4096))
            var units = Array(chunk.utf16)
            guard !units.isEmpty else { return nil }
            return Data(bytes: &units, count: units.count * 2)
        }
    }
}

private final class ParseResult: @unchecked Sendable {
    var tree: Tree?
    var changed: [TSRange]?
}
