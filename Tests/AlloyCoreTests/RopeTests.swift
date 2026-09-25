import XCTest
@testable import AlloyCore

final class RopeTests: XCTestCase {
    func testEmptyAndSmall() {
        let empty = Rope()
        XCTAssertEqual(empty.string, "")
        XCTAssertEqual(empty.lineCount, 1)
        XCTAssertEqual(empty.offset(ofLine: 0), 0)
        var rope = Rope("hello\nworld")
        XCTAssertEqual(rope.lineCount, 2)
        XCTAssertEqual(rope.range(ofLine: 1), 6..<11)
        rope.insert(", there", at: 5)
        XCTAssertEqual(rope.string, "hello, there\nworld")
        rope.delete(0..<7)
        XCTAssertEqual(rope.string, "there\nworld")
    }

    func testLinesAndPositions() {
        let rope = Rope("a\nbc\n\nd")
        XCTAssertEqual(rope.lineCount, 4)
        XCTAssertEqual((0..<4).map { rope.offset(ofLine: $0) }, [0, 2, 5, 6])
        XCTAssertEqual((0...7).map { rope.line(containing: $0) }, [0, 0, 1, 1, 1, 2, 3, 3])
        XCTAssertEqual(rope.range(ofLine: 2), 5..<5)
        XCTAssertTrue(rope.position(of: 4) == (1, 2))
        XCTAssertEqual(rope.offset(line: 1, column: 99), 4, "a column past the line's end clamps to it")
        XCTAssertEqual(rope.offset(ofLine: 99), 7)
        XCTAssertEqual(Rope("a\r\nb").lineCount, 2, "\\r\\n is one break")
    }

    func testSurrogatePairsAndUTF8() {
        var rope = Rope("a😀b")  // 😀 is two UTF-16 units, four UTF-8 bytes
        XCTAssertEqual(rope.utf16Count, 4)
        XCTAssertEqual(rope.utf8Count, 6)
        XCTAssertEqual(rope.utf8Offset(ofUTF16: 3), 5)
        XCTAssertEqual(rope.utf16Offset(ofUTF8: 5), 3)
        XCTAssertEqual(rope.utf8Offset(ofUTF16: 2), 1, "an offset inside the pair rounds down to its start")
        var inserted = rope
        inserted.insert("x", at: 2)
        XCTAssertEqual(inserted.string, "ax😀b", "inserting inside the pair lands before it")
        rope.replace(2..<3, with: "x")
        XCTAssertEqual(rope.string, "axb", "replacing half the pair takes the whole pair: never half a character")
    }

    func testLargeTextBuildsABalancedTree() {
        let line = "let value = computeSomething(from: input) // 😀 comment\n"
        let text = String(repeating: line, count: 50_000)
        let rope = Rope(text)
        XCTAssertEqual(rope.utf16Count, text.utf16.count)
        XCTAssertEqual(rope.lineCount, 50_001)
        XCTAssertLessThanOrEqual(rope.height, 4, "about 2.8 MB fits in four levels")
        XCTAssertEqual(rope.string, text)
        let lineLength = line.utf16.count
        XCTAssertEqual(rope.offset(ofLine: 12_345), 12_345 * lineLength)
        XCTAssertEqual(rope.line(containing: 12_345 * lineLength + 3), 12_345)
        XCTAssertEqual(rope.substring(rope.range(ofLine: 40_000)) + "\n", line)
        for chunk in rope.chunks { XCTAssertLessThanOrEqual(chunk.utf8.count, Rope.maxLeafBytes) }
    }

    func testSnapshotsDontChange() {
        let original = Rope(String(repeating: "abc\n", count: 5_000))
        var edited = original
        edited.insert("NEW", at: 10_000)
        XCTAssertEqual(original.utf16Count, 20_000)
        XCTAssertEqual(edited.utf16Count, 20_003)
        XCTAssertFalse(original.string.contains("NEW"))
    }

    /// Every operation against a plain model of the same text, across random edits of text with
    /// emoji, accents, CRLF and long lines, so chunks split and merge everywhere.
    func testRandomEditsMatchAPlainModel() {
        var generator = SplitMix(seed: 42)
        let pieces = ["a", "bc", "\n", "\r\n", "😀", "é", "e\u{301}", "    ", String(repeating: "x", count: 700), "日本語", "\t{}\n"]
        var rope = Rope()
        var model: [UInt16] = []
        for step in 0..<4_000 {
            let length = model.count
            var lower = Int(generator.next() % UInt64(length + 1))
            var upper = min(length, lower + Int(generator.next() % 40))
            // The model can't split a surrogate pair either: round both ends down like the rope.
            lower = Self.roundDown(lower, in: model)
            upper = max(lower, Self.roundDown(upper, in: model))
            let deleting = generator.next() % 3 == 0
            var insertion = ""
            if !deleting { for _ in 0..<(1 + Int(generator.next() % 3)) { insertion += pieces[Int(generator.next() % UInt64(pieces.count))] } }
            rope.replace(lower..<upper, with: insertion)
            model.replaceSubrange(lower..<upper, with: Array(insertion.utf16))

            XCTAssertEqual(rope.utf16Count, model.count, "length after step \(step)")
            if step % 97 == 0 {
                let modelString = String(decoding: model, as: UTF16.self)
                XCTAssertEqual(rope.string, modelString, "text after step \(step)")
                let newlines = model.enumerated().filter { $0.element == 0x0A }.map(\.offset)
                XCTAssertEqual(rope.lineCount, newlines.count + 1)
                for (index, position) in newlines.enumerated().prefix(20) {
                    XCTAssertEqual(rope.offset(ofLine: index + 1), position + 1)
                    XCTAssertEqual(rope.line(containing: position + 1), index + 1)
                }
                let a = Self.roundDown(Int(generator.next() % UInt64(model.count + 1)), in: model)
                let b = max(a, Self.roundDown(min(model.count, a + 200), in: model))
                XCTAssertEqual(rope.substring(a..<b), String(decoding: model[a..<b], as: UTF16.self))
                XCTAssertEqual(rope.utf8Count, modelString.utf8.count)
            }
        }
    }

    static func roundDown(_ offset: Int, in units: [UInt16]) -> Int {
        guard offset > 0, offset < units.count else { return offset }
        return UTF16.isTrailSurrogate(units[offset]) && UTF16.isLeadSurrogate(units[offset - 1]) ? offset - 1 : offset
    }
}

/// A deterministic generator, so a failure reproduces.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
