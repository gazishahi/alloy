import Foundation

/// A rope as an `NSString`, without copying it: `length` is the rope's UTF-16 count and
/// characters are read from its leaves, one leaf cached at a time. For code written against
/// NSString (line ranges, bracket scans, the word before the caret) that reads a little of a big
/// document. Joining the rope into a `String` costs the whole file; this costs what's read.
///
/// A snapshot: it holds the rope it was made from, so later edits don't change it.
public final class RopeString: NSString, @unchecked Sendable {
    // No initializers of its own: NSString's required ones (literals among them) can't be
    // overridden from Swift, so the rope is set once, in `make`.
    public private(set) var rope = Rope()
    private var leaf: [unichar] = []
    private var leafStart = 0

    public static func make(_ rope: Rope) -> RopeString {
        let string = RopeString()
        string.rope = rope
        return string
    }

    public override var length: Int { rope.utf16Count }

    public override func character(at index: Int) -> unichar {
        if index < leafStart || index >= leafStart + leaf.count { load(index) }
        return leaf[index - leafStart]
    }

    public override func getCharacters(_ buffer: UnsafeMutablePointer<unichar>, range: NSRange) {
        var written = 0
        var index = range.location
        while written < range.length {
            if index < leafStart || index >= leafStart + leaf.count { load(index) }
            let from = index - leafStart
            let count = min(leaf.count - from, range.length - written)
            leaf.withUnsafeBufferPointer { (buffer + written).update(from: $0.baseAddress! + from, count: count) }
            written += count
            index += count
        }
    }

    public override func substring(with range: NSRange) -> String {
        rope.substring(range.location..<(range.location + range.length))
    }

    /// Joining is what `String(self)` and bridging do; the rope does it chunk by chunk.
    public override func copy(with zone: NSZone? = nil) -> Any { rope.string as NSString }

    private func load(_ index: Int) {
        precondition(index >= 0 && index < rope.utf16Count, "index \(index) beyond \(rope.utf16Count)")
        let (text, start) = rope.leaf(containing: index)
        leaf = Array(text.utf16)
        leafStart = start
    }
}
