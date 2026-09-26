import XCTest
@testable import AlloyCore

/// Foldable regions from indentation.
final class FoldingTests: XCTestCase {
    func testRegionsFollowIndentation() {
        let source = """
        struct A {
            func b() {
                let c = 1

                print(c)
            }
            var d = 2
        }
        let e = 3
        """
        let regions = Folding.ranges(in: Rope(source))
        XCTAssertEqual(regions, [0...7, 1...5], "each to its closing brace; func past a blank line inside it")
        XCTAssertEqual(Folding.ranges(in: Rope("one\ntwo\nthree")), [], "nothing deeper, nothing to fold")
        XCTAssertEqual(Folding.ranges(in: Rope("a:\n\tb\n\tc\nd")), [0...2], "tabs count as a stop")
    }

    func testABigFileIsQuick() {
        let block = "func f() {\n    if x {\n        y()\n    }\n}\n"
        let text = Rope(String(repeating: block, count: 20_000))
        let start = Date()
        let regions = Folding.ranges(in: text)
        XCTAssertEqual(regions.count, 40_000)
        XCTAssertEqual(regions.first, 0...4, "func to its closing brace")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "100,000 lines, off the main thread in the app")
    }
}
