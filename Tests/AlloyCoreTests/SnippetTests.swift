import XCTest
@testable import AlloyCore

final class SnippetTests: XCTestCase {
    func testStopsDefaultsChoicesAndTheEnd() {
        let s = Snippet(parsing: "for ${1:item} in ${2|items,list|} {\n\t$0\n}")
        XCTAssertEqual(s.text, "for item in items {\n\t\n}")
        XCTAssertEqual(s.stops, [[4..<8], [12..<17], [21..<21]])
    }

    func testMirrorsNestingEscapesAndVariables() {
        let s = Snippet(parsing: "${1:name} = ${2:${1:name}.copy()} \\$5 ${TM_FILENAME} ${NOPE:x}", variables: ["TM_FILENAME": "a.ts"])
        XCTAssertEqual(s.text, "name = name.copy() $5 a.ts x")
        XCTAssertEqual(s.stops[0], [0..<4, 7..<11], "the stop and its mirror")
        XCTAssertEqual(s.stops[1], [7..<18])
        XCTAssertEqual(s.stops.last, [28..<28], "no $0: the end")
    }

    func testPlainTextHasNoStopsToVisit() {
        XCTAssertFalse(Snippet(parsing: "cost $ 5 {}").hasStops)
        XCTAssertEqual(Snippet(parsing: "cost $ 5 {}").text, "cost $ 5 {}")
        XCTAssertFalse(Snippet(plain: "x").hasStops)
    }

    func testStopsFollowTypingInTheCurrentOneAndMoveAfterIt() {
        // "f(a, b)": stops a (2..<3), b (5..<6), end 7.
        var stops = SnippetStops(stops: [[2..<3], [5..<6], [7..<7]])
        // Replace "a" with "alpha": the current stop grows, the rest move.
        stops.follow([AppliedEdit(range: 2..<3, oldText: "a", newText: "alpha")])
        XCTAssertEqual(stops.stops, [[2..<7], [9..<10], [11..<11]])
        // Typing at the end of the current stop grows it, not the next one.
        stops.follow([AppliedEdit(range: 7..<7, oldText: "", newText: "X")])
        XCTAssertEqual(stops.stops, [[2..<8], [10..<11], [12..<12]])
        XCTAssertEqual(stops.advance(by: 1), [10..<11])
        XCTAssertFalse(stops.isAtLast)
    }
}
