import Foundation

/// Text with tab stops, in the syntax language servers and VS Code use: `$1`, `${1:default}`,
/// `${1|one,two|}`, `$0` for where the caret ends, `$NAME` / `${NAME:default}` for variables,
/// and `\` before `$`, `}` or `\` to write them plainly. A stop that appears more than once is
/// the same text in each place (a mirror).
public struct Snippet: Equatable, Sendable {
    /// The text as inserted: defaults filled in, choices as their first option.
    public let text: String
    /// Each stop's ranges in `text` (UTF-16), in the order Tab visits them: `$1`, `$2`, …,
    /// then `$0` (or the end of the text, if there's no `$0`).
    public let stops: [[Range<Int>]]

    public init(text: String, stops: [[Range<Int>]]) {
        self.text = text
        self.stops = stops
    }

    /// Plain text: no stops, the caret at the end.
    public init(plain text: String) {
        let end = text.utf16.count
        self.init(text: text, stops: [[end..<end]])
    }

    public init(parsing source: String, variables: [String: String] = [:]) {
        var parser = Parser(units: Array(source.utf16), variables: variables)
        parser.parse(until: nil)
        var byIndex: [Int: [Range<Int>]] = [:]
        for (index, range) in parser.placeholders { byIndex[index, default: []].append(range) }
        var ordered = byIndex.keys.filter { $0 > 0 }.sorted().map { byIndex[$0]! }
        let end = parser.output.count
        ordered.append(byIndex[0] ?? [end..<end])
        self.init(text: String(utf16CodeUnits: parser.output, count: parser.output.count), stops: ordered)
    }

    /// Whether there's anywhere to Tab to before the end.
    public var hasStops: Bool { stops.count > 1 }

    private struct Parser {
        let units: [UInt16]
        let variables: [String: String]
        var i = 0
        var output: [UInt16] = []
        var placeholders: [(Int, Range<Int>)] = []

        static let dollar: UInt16 = 0x24, open: UInt16 = 0x7B, close: UInt16 = 0x7D
        static let backslash: UInt16 = 0x5C, colon: UInt16 = 0x3A, bar: UInt16 = 0x7C, comma: UInt16 = 0x2C

        static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
        static func isNameStart(_ u: UInt16) -> Bool { u == 0x5F || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) }
        static func isName(_ u: UInt16) -> Bool { isNameStart(u) || isDigit(u) }

        /// Reads until `terminator` (a `}` closing the placeholder being read) or the end.
        mutating func parse(until terminator: UInt16?) {
            while i < units.count {
                let u = units[i]
                if let terminator, u == terminator { return }
                if u == Self.backslash, i + 1 < units.count, [Self.dollar, Self.close, Self.backslash].contains(units[i + 1]) {
                    output.append(units[i + 1]); i += 2; continue
                }
                if u == Self.dollar, parseDollar() { continue }
                output.append(u); i += 1
            }
        }

        /// A `$…` at `i`; false (nothing consumed) if it isn't one, so the `$` is plain text.
        mutating func parseDollar() -> Bool {
            let start = i
            guard i + 1 < units.count else { return false }
            let next = units[i + 1]
            if Self.isDigit(next) {
                i += 1
                let index = readNumber()
                placeholders.append((index, output.count..<output.count))
                return true
            }
            if Self.isNameStart(next) {
                i += 1
                let name = readName()
                output += Array((variables[name] ?? "").utf16)
                return true
            }
            guard next == Self.open else { return false }
            i += 2
            if i < units.count, Self.isDigit(units[i]) {
                let index = readNumber()
                let from = output.count
                guard i < units.count else { i = start; return false }
                switch units[i] {
                case Self.close:
                    i += 1
                case Self.colon:
                    i += 1
                    parse(until: Self.close)
                    i += 1
                case Self.bar:
                    i += 1
                    var choice: [UInt16] = [], first: [UInt16]? = nil
                    while i < units.count, units[i] != Self.bar {
                        if units[i] == Self.backslash, i + 1 < units.count { choice.append(units[i + 1]); i += 2; continue }
                        if units[i] == Self.comma { if first == nil { first = choice }; choice = []; i += 1; continue }
                        choice.append(units[i]); i += 1
                    }
                    output += first ?? choice
                    i += 2 // `|}`
                default:
                    i = start
                    return false
                }
                placeholders.append((index, from..<output.count))
                return true
            }
            if i < units.count, Self.isNameStart(units[i]) {
                let name = readName()
                if i < units.count, units[i] == Self.close {
                    i += 1
                    output += Array((variables[name] ?? "").utf16)
                    return true
                }
                if i < units.count, units[i] == Self.colon {
                    i += 1
                    if let value = variables[name] {
                        var skipped = Parser(units: units, variables: variables, i: i)
                        skipped.parse(until: Self.close)
                        i = skipped.i + 1
                        output += Array(value.utf16)
                    } else {
                        parse(until: Self.close)
                        i += 1
                    }
                    return true
                }
                // A transform (`${NAME/…/…/}`) or something else: kept as it was written.
                i = start
                return false
            }
            i = start
            return false
        }

        mutating func readNumber() -> Int {
            var n = 0
            while i < units.count, Self.isDigit(units[i]) { n = n * 10 + Int(units[i] - 0x30); i += 1 }
            return n
        }

        mutating func readName() -> String {
            let from = i
            while i < units.count, Self.isName(units[i]) { i += 1 }
            return String(utf16CodeUnits: Array(units[from..<i]), count: i - from)
        }
    }
}

/// A snippet's stops after it's inserted, followed through the edits that come after: typing in
/// a stop grows it, text before a stop moves it.
public struct SnippetStops: Sendable, Equatable {
    /// Each stop's ranges in the document.
    public private(set) var stops: [[Range<Int>]]
    /// Which stop Tab reached last.
    public private(set) var current = 0

    public init(stops: [[Range<Int>]]) { self.stops = stops }

    public var isAtLast: Bool { current >= stops.count - 1 }
    public var currentRanges: [Range<Int>] { stops[current] }

    public mutating func advance(by step: Int) -> [Range<Int>]? {
        let next = current + step
        guard stops.indices.contains(next) else { return nil }
        current = next
        return stops[current]
    }

    /// Follows edits applied in order, each in the text as it was at that moment.
    public mutating func follow(_ edits: [AppliedEdit]) {
        for edit in edits {
            let start = edit.range.lowerBound, end = edit.range.upperBound
            let delta = edit.newText.utf16.count - edit.range.count
            let inserted = edit.newText.utf16.count
            stops = stops.enumerated().map { index, ranges in
                let growsAtEdges = index == current
                return ranges.map { range in
                    // Typing in the current stop, or at its edges, grows it; everything after an
                    // edit moves by what it added.
                    func mapStart(_ p: Int) -> Int {
                        if p < start || (p == start && growsAtEdges) { return p }
                        if p >= end { return p + delta }
                        return start + inserted
                    }
                    func mapEnd(_ p: Int) -> Int {
                        if p < start { return p }
                        if p == start, !growsAtEdges { return range.isEmpty ? mapStart(p) : p }
                        if p >= end, p > start || !growsAtEdges { return p + delta }
                        return start + inserted
                    }
                    let a = mapStart(range.lowerBound), b = mapEnd(range.upperBound)
                    return a..<max(a, b)
                }
            }
        }
    }

    /// Whether a caret or selection is inside (or at the edge of) the current stop.
    public func contains(_ selection: Selection) -> Bool {
        stops[current].contains { $0.lowerBound <= selection.range.lowerBound && selection.range.upperBound <= $0.upperBound }
    }
}
