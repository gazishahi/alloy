import Foundation
import XCTest
@testable import AlloyCore

final class RopeStringTests: XCTestCase {
    /// Many leaves, with emoji and CRLF so surrogate pairs and line ends land on leaf edges.
    private let text = (0..<3_000).map { "line \($0) 👍🏽 é\($0 % 7 == 0 ? "\r\n" : "\n")" }.joined()

    func testReadsLikeTheString() {
        let rope = Rope(text)
        XCTAssertGreaterThan(rope.chunks.count, 20)
        let reference = text as NSString
        let string = RopeString.make(rope)
        XCTAssertEqual(string.length, reference.length)
        for index in stride(from: 0, to: reference.length, by: 7) {
            XCTAssertEqual(string.character(at: index), reference.character(at: index), "at \(index)")
        }
        XCTAssertEqual(string.character(at: reference.length - 1), reference.character(at: reference.length - 1))
        for location in [0, 1_000, 20_000, reference.length - 50] {
            let range = NSRange(location: location, length: 50)
            XCTAssertEqual(string.lineRange(for: range), reference.lineRange(for: range))
            XCTAssertEqual(string.substring(with: string.lineRange(for: range)), reference.substring(with: reference.lineRange(for: range)))
            XCTAssertEqual(string.range(of: "👍🏽", range: range), reference.range(of: "👍🏽", range: range))
        }
        XCTAssertEqual(string as String, text)
    }

    func testLeafLookupAtTheEdges() {
        let rope = Rope(text)
        var start = 0
        for chunk in rope.chunks {
            XCTAssertEqual(rope.leaf(containing: start).start, start)
            XCTAssertEqual(rope.leaf(containing: start).text, chunk)
            start += chunk.utf16.count
        }
        XCTAssertEqual(rope.leaf(containing: rope.utf16Count).text, rope.chunks.last)
        XCTAssertEqual(RopeString.make(Rope("")).length, 0)
    }

    func testASnapshotDoesNotChange() {
        let buffer = TextBuffer("abc")
        let snapshot = RopeString.make(buffer.text)
        buffer.apply([TextEdit(range: 0..<0, text: "x")], kind: .typing)
        XCTAssertEqual(snapshot as String, "abc")
    }
}
