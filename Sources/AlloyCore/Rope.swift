/// Counts a stretch of text carries: its UTF-8 and UTF-16 lengths and how many line breaks it
/// holds. Every rope node caches the sum for its subtree, so offsets and lines resolve by
/// descending the tree instead of scanning the text.
public struct TextSummary: Equatable, Sendable {
    public var utf8 = 0
    public var utf16 = 0
    /// Count of "\n". A line is what "\n" ends; "\r\n" is one break. A lone "\r" isn't one.
    public var newlines = 0

    public init() {}

    init(_ text: String) {
        utf8 = text.utf8.count
        utf16 = text.utf16.count
        var count = 0
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        newlines = count
    }

    static func + (a: TextSummary, b: TextSummary) -> TextSummary {
        var sum = a
        sum.utf8 += b.utf8
        sum.utf16 += b.utf16
        sum.newlines += b.newlines
        return sum
    }
}

/// An immutable node: a leaf holding a chunk of text, or an interior node holding children of
/// one lower height. Nodes are never changed after creation, so an edit builds a new path from
/// the root to the changed leaf and shares everything else with the version before.
final class RopeNode: @unchecked Sendable {
    let height: Int
    let summary: TextSummary
    let text: String
    let children: [RopeNode]

    init(leaf text: String) {
        height = 0
        summary = TextSummary(text)
        self.text = text
        children = []
    }

    init(children: [RopeNode]) {
        precondition(!children.isEmpty)
        height = children[0].height + 1
        var sum = TextSummary()
        for child in children { sum = sum + child.summary }
        summary = sum
        text = ""
        self.children = children
    }
}

/// Text as a balanced tree of chunks (docs/DESIGN.md, A2). Value semantics: copying a rope
/// is free and the copy never changes, which is what undo snapshots and background highlighting
/// rely on. Offsets are UTF-16 code units, matching AppKit and LSP.
public struct Rope: Sendable, Equatable {
    /// Leaves hold at most this many UTF-8 bytes; interior nodes at most this many children.
    static let maxLeafBytes = 1024
    static let maxChildren = 16

    private(set) var root: RopeNode

    public init() { root = RopeNode(leaf: "") }

    public init(_ text: String) {
        let leaves = Self.chunk(text).map(RopeNode.init(leaf:))
        root = Self.build(leaves)
    }

    public static func == (a: Rope, b: Rope) -> Bool {
        a.root === b.root || (a.summary == b.summary && a.string == b.string)
    }

    public var summary: TextSummary { root.summary }
    public var utf16Count: Int { root.summary.utf16 }
    public var utf8Count: Int { root.summary.utf8 }
    /// Lines, counting the one after the last "\n" (so "" has one line and "a\n" has two).
    public var lineCount: Int { root.summary.newlines + 1 }
    public var isEmpty: Bool { root.summary.utf16 == 0 }
    /// Tree height; a leaf-only rope is 0.
    public var height: Int { root.height }

    public var string: String {
        var out = ""
        out.reserveCapacity(root.summary.utf8)
        for chunk in chunks { out += chunk }
        return out
    }

    /// The text's chunks, in order. Drawing and highlighting read these without joining them.
    public var chunks: [String] {
        var out: [String] = []
        Self.collect(root) { out.append($0.text) }
        return out
    }

    // MARK: Editing

    /// Replaces a UTF-16 range. A range boundary inside a surrogate pair rounds down to the
    /// pair's start, so the rope never holds half a character.
    public mutating func replace(_ range: Range<Int>, with text: String) {
        let lower = max(0, min(range.lowerBound, utf16Count))
        let upper = max(lower, min(range.upperBound, utf16Count))
        guard lower != upper || !text.isEmpty else { return }
        var nodes = Self.replace(root, lower, upper, text)
        while nodes.count > 1 { nodes = Self.pack(nodes) }
        var newRoot = nodes.first ?? RopeNode(leaf: "")
        while newRoot.height > 0, newRoot.children.count == 1 { newRoot = newRoot.children[0] }
        root = newRoot
    }

    public mutating func insert(_ text: String, at offset: Int) { replace(offset..<offset, with: text) }
    public mutating func delete(_ range: Range<Int>) { replace(range, with: "") }

    public func replacing(_ range: Range<Int>, with text: String) -> Rope {
        var copy = self
        copy.replace(range, with: text)
        return copy
    }

    // MARK: Reading

    /// The text in a UTF-16 range.
    public func substring(_ range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, utf16Count))
        let upper = max(lower, min(range.upperBound, utf16Count))
        guard lower < upper else { return "" }
        var out = ""
        Self.substring(root, lower, upper, into: &out)
        return out
    }

    /// The zero-based line holding a UTF-16 offset.
    public func line(containing offset: Int) -> Int {
        var node = root
        var remaining = max(0, min(offset, utf16Count))
        var line = 0
        while node.height > 0 {
            var index = 0
            while index < node.children.count - 1, remaining >= node.children[index].summary.utf16 {
                remaining -= node.children[index].summary.utf16
                line += node.children[index].summary.newlines
                index += 1
            }
            node = node.children[index]
        }
        var count = 0
        for unit in node.text.utf16.prefix(remaining) where unit == 0x0A { count += 1 }
        return line + count
    }

    /// The UTF-16 offset where a zero-based line starts; past the last line, the end.
    public func offset(ofLine line: Int) -> Int {
        guard line > 0 else { return 0 }
        guard line <= root.summary.newlines else { return utf16Count }
        // The position just after the `line`-th "\n".
        var node = root
        var remaining = line
        var offset = 0
        while node.height > 0 {
            var index = 0
            while index < node.children.count - 1, remaining > node.children[index].summary.newlines {
                remaining -= node.children[index].summary.newlines
                offset += node.children[index].summary.utf16
                index += 1
            }
            node = node.children[index]
        }
        var position = 0
        for unit in node.text.utf16 {
            position += 1
            if unit == 0x0A {
                remaining -= 1
                if remaining == 0 { break }
            }
        }
        return offset + position
    }

    /// A line's UTF-16 range, without its "\n".
    public func range(ofLine line: Int) -> Range<Int> {
        let start = offset(ofLine: line)
        let next = line + 1 < lineCount ? offset(ofLine: line + 1) - 1 : utf16Count
        return start..<max(start, next)
    }

    /// Zero-based line and UTF-16 column, the pair LSP positions use.
    public func position(of offset: Int) -> (line: Int, column: Int) {
        let line = line(containing: offset)
        return (line, max(0, min(offset, utf16Count)) - self.offset(ofLine: line))
    }

    public func offset(line: Int, column: Int) -> Int {
        let range = range(ofLine: line)
        return min(range.lowerBound + max(0, column), range.upperBound)
    }

    /// The UTF-8 offset of a UTF-16 offset: tree-sitter speaks bytes.
    public func utf8Offset(ofUTF16 offset: Int) -> Int {
        var node = root
        var remaining = max(0, min(offset, utf16Count))
        var bytes = 0
        while node.height > 0 {
            var index = 0
            while index < node.children.count - 1, remaining >= node.children[index].summary.utf16 {
                remaining -= node.children[index].summary.utf16
                bytes += node.children[index].summary.utf8
                index += 1
            }
            node = node.children[index]
        }
        let index = Self.scalarIndex(node.text, utf16: remaining)
        return bytes + node.text.utf8.distance(from: node.text.startIndex, to: index)
    }

    public func utf16Offset(ofUTF8 offset: Int) -> Int {
        var node = root
        var remaining = max(0, min(offset, utf8Count))
        var units = 0
        while node.height > 0 {
            var index = 0
            while index < node.children.count - 1, remaining >= node.children[index].summary.utf8 {
                remaining -= node.children[index].summary.utf8
                units += node.children[index].summary.utf16
                index += 1
            }
            node = node.children[index]
        }
        let utf8 = node.text.utf8
        var index = utf8.index(utf8.startIndex, offsetBy: remaining, limitedBy: utf8.endIndex) ?? utf8.endIndex
        while index > utf8.startIndex, index.samePosition(in: node.text.unicodeScalars) == nil { index = utf8.index(before: index) }
        return units + node.text.utf16.distance(from: node.text.startIndex, to: index)
    }

    // MARK: Tree

    /// Splits text into leaf-sized chunks on scalar boundaries, never between "\r" and "\n".
    static func chunk(_ text: String) -> [String] {
        guard text.utf8.count > maxLeafBytes else { return [text] }
        var result: [String] = []
        let scalars = text.unicodeScalars
        let utf8 = text.utf8
        var start = text.startIndex
        while start < text.endIndex {
            var end = utf8.index(start, offsetBy: maxLeafBytes, limitedBy: text.endIndex) ?? text.endIndex
            while end < text.endIndex, end.samePosition(in: scalars) == nil { end = utf8.index(before: end) }
            if end < text.endIndex, end > start, utf8[end] == 0x0A, utf8[utf8.index(before: end)] == 0x0D {
                end = utf8.index(before: end)
            }
            if end == start { end = scalars.index(after: start) }
            result.append(String(scalars[start..<end]))
            start = end
        }
        return result
    }

    static func build(_ leaves: [RopeNode]) -> RopeNode {
        guard !leaves.isEmpty else { return RopeNode(leaf: "") }
        var level = leaves
        while level.count > 1 { level = pack(level) }
        return level[0]
    }

    /// Groups nodes of one height under parents of the next, as evenly as `maxChildren` allows.
    static func pack(_ nodes: [RopeNode]) -> [RopeNode] {
        let groups = (nodes.count + maxChildren - 1) / maxChildren
        let size = (nodes.count + groups - 1) / groups
        return stride(from: 0, to: nodes.count, by: size).map {
            RopeNode(children: Array(nodes[$0..<min($0 + size, nodes.count)]))
        }
    }

    /// Replaces [lower, upper) (local to `node`) and returns what takes its place: zero or more
    /// nodes of the same height. Interior nodes can be underfull; only overflow splits, so the
    /// tree never gets taller than its largest size needed.
    private static func replace(_ node: RopeNode, _ lower: Int, _ upper: Int, _ text: String) -> [RopeNode] {
        if node.height == 0 {
            let old = node.text
            let a = scalarIndex(old, utf16: lower)
            let b = scalarIndex(old, utf16: upper)
            var scalars = old.unicodeScalars
            scalars.replaceSubrange(a..<b, with: text.unicodeScalars)
            let updated = String(scalars)
            if updated.isEmpty { return [] }
            return chunk(updated).map(RopeNode.init(leaf:))
        }
        var children = node.children
        var i = 0
        var iStart = 0
        while i < children.count - 1, iStart + children[i].summary.utf16 < lower {
            iStart += children[i].summary.utf16
            i += 1
        }
        var j = i
        var jStart = iStart
        while j < children.count - 1, jStart + children[j].summary.utf16 < upper {
            jStart += children[j].summary.utf16
            j += 1
        }
        let replacement: [RopeNode]
        if i == j {
            replacement = replace(children[i], lower - iStart, upper - iStart, text)
        } else {
            replacement = replace(children[i], lower - iStart, children[i].summary.utf16, text)
                + replace(children[j], 0, upper - jStart, "")
        }
        children.replaceSubrange(i...j, with: replacement)
        guard !children.isEmpty else { return [] }
        return children.count <= maxChildren ? [RopeNode(children: children)] : pack(children)
    }

    private static func substring(_ node: RopeNode, _ lower: Int, _ upper: Int, into out: inout String) {
        if node.height == 0 {
            let a = scalarIndex(node.text, utf16: lower)
            let b = scalarIndex(node.text, utf16: upper)
            out += String(node.text.unicodeScalars[a..<b])
            return
        }
        var start = 0
        for child in node.children {
            let end = start + child.summary.utf16
            if end > lower, start < upper {
                substring(child, max(0, lower - start), min(child.summary.utf16, upper - start), into: &out)
            }
            if end >= upper { break }
            start = end
        }
    }

    /// The leaf holding a UTF-16 offset (the last leaf for the end), and where it starts.
    func leaf(containing offset: Int) -> (text: String, start: Int) {
        var node = root
        var start = 0
        var remaining = max(0, min(offset, utf16Count))
        while node.height > 0 {
            let children = node.children
            for (index, child) in children.enumerated() {
                if remaining < child.summary.utf16 || index == children.count - 1 { node = child; break }
                remaining -= child.summary.utf16
                start += child.summary.utf16
            }
        }
        return (node.text, start)
    }

    private static func collect(_ node: RopeNode, _ body: (RopeNode) -> Void) {
        if node.height == 0 { body(node); return }
        for child in node.children { collect(child, body) }
    }

    /// The index for a UTF-16 offset, rounded down to a scalar boundary.
    static func scalarIndex(_ text: String, utf16 offset: Int) -> String.Index {
        let utf16 = text.utf16
        var index = utf16.index(utf16.startIndex, offsetBy: max(0, offset), limitedBy: utf16.endIndex) ?? utf16.endIndex
        while index > utf16.startIndex, index.samePosition(in: text.unicodeScalars) == nil { index = utf16.index(before: index) }
        return index
    }
}
