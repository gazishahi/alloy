import AlloyCore
import XCTest
@testable import AlloySyntax

/// The outline from the syntax tree, in each language Alloy knows.
@MainActor
final class SyntaxSymbolsTests: XCTestCase {
    private func outline(_ ext: String, _ source: String) throws -> [String] {
        let highlighter = try XCTUnwrap(SyntaxHighlighter(fileExtension: ext, text: Rope(source)))
        highlighter.waitForParse()
        let symbols = try XCTUnwrap(highlighter.symbolSource()).symbols()
        func flatten(_ list: [SyntaxSymbol], _ depth: Int) -> [String] {
            list.flatMap { [String(repeating: "  ", count: depth) + "\($0.kind.rawValue) \($0.name)"] + flatten($0.children, depth + 1) }
        }
        return flatten(symbols, 0)
    }

    func testSwift() throws {
        XCTAssertEqual(try outline("swift", """
        struct Point {
            let x: Int
            init(x: Int) { self.x = x }
            func moved() -> Point { let local = 1; return self }
        }
        protocol Shape { func area() -> Double }
        func top() {}
        extension Point { enum Axis { case x } }
        """), ["struct Point", "  property x", "  constructor init", "  function moved", "protocol Shape", "  method area", "function top", "extension Point", "  enum Axis"])
    }

    func testTypeScript() throws {
        XCTAssertEqual(try outline("ts", """
        export interface User { name: string }
        export class Store {
          count = 0
          add(n: number) { const local = n; return local }
        }
        export const helper = () => 1
        function main() { const inner = 2 }
        type Id = string
        """), ["interface User", "  property name", "class Store", "  property count", "  method add", "variable helper", "function main", "type Id"])
    }

    func testPythonRustGo() throws {
        XCTAssertEqual(try outline("py", "class A:\n    def b(self):\n        pass\ndef c():\n    pass\n"), ["class A", "  function b", "function c"])
        XCTAssertEqual(try outline("rs", "struct S { a: i32 }\nimpl S { fn new() -> S { S { a: 1 } } }\nconst MAX: i32 = 3;\n"),
                       ["struct S", "extension S", "  function new", "constant MAX"])
        XCTAssertEqual(try outline("go", "package p\ntype T struct{}\nfunc (t T) M() {}\nfunc F() {}\n"), ["type T", "method M", "function F"])
    }

    func testCRubyMarkdownJSON() throws {
        XCTAssertEqual(try outline("c", "struct point { int x; };\nint add(int a, int b) { return a + b; }\nstatic char *name(void) { return 0; }\n"),
                       ["struct point", "function add", "function name"])
        XCTAssertEqual(try outline("rb", "module M\n  class C\n    def run; end\n  end\nend\n"), ["module M", "  class C", "    method run"])
        XCTAssertEqual(try outline("md", "# Title\n\ntext\n\n## Part two\n"), ["heading Title", "heading Part two"])
        XCTAssertEqual(try outline("json", "{\"name\": \"x\", \"scripts\": {\"build\": \"y\"}}"), ["key name", "key scripts", "  key build"])
    }

    func testTheGrammarsAddedIn050() throws {
        XCTAssertEqual(try outline("yaml", "name: side\njobs:\n  build:\n    runs-on: mac\n"), ["key name", "key jobs", "  key build", "    key runs-on"])
        XCTAssertEqual(try outline("toml", "[package]\nname = \"x\"\n[dependencies]\n"), ["module package", "module dependencies"])
        XCTAssertEqual(try outline("css", ".a, .b { color: red; }\n@keyframes spin { }\n"), ["key .a, .b", "key spin"])
        XCTAssertEqual(try outline("sh", "build() { echo hi; }\nfunction test { :; }\n"), ["function build", "function test"])
        XCTAssertEqual(try outline("java", "class A {\n  int count;\n  A() {}\n  void run() {}\n}\ninterface B {}\n"),
                       ["class A", "  property count", "  constructor A", "  method run", "interface B"])
        XCTAssertEqual(try outline("php", "<?php\nclass A { function run() {} }\nfunction f() {}\n"), ["class A", "  method run", "function f"])
        XCTAssertEqual(try outline("dockerfile", "FROM swift:6 AS build\nRUN make\nFROM alpine\n"), ["module build", "module alpine"])
        XCTAssertEqual(try outline("mk", "all: build\n\techo\nbuild:\n\tswift build\n"), ["function all", "function build"])
        XCTAssertEqual(try outline("sql", "CREATE TABLE users (id int);\nCREATE VIEW active AS SELECT * FROM users;\n"), ["struct users", "type active"])
    }

    func testABigFileIsQuick() throws {
        let source = (0..<20_000).map { "func f\($0)() {\n    let a = \($0)\n}\n" }.joined()
        let highlighter = try XCTUnwrap(SyntaxHighlighter(fileExtension: "swift", text: Rope(source)))
        highlighter.waitForParse()
        let start = Date()
        let symbols = try XCTUnwrap(highlighter.symbolSource()).symbols()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(symbols.count, 20_000)
        XCTAssertLessThan(elapsed, 2, "20,000 functions: \(elapsed) s (debug build)")
    }
}
