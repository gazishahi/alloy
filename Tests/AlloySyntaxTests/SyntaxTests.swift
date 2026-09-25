import AlloyCore
import AlloyRender
import XCTest
@testable import AlloySyntax

@MainActor
final class SyntaxTests: XCTestCase {
    let theme = SyntaxTheme.side(dark: false)

    /// Every language Side highlights loads, which also proves its query compiles against its
    /// grammar (a query naming a node the grammar doesn't have fails here).
    func testEveryLanguageLoadsAndHighlights() throws {
        let samples: [String: String] = [
            "swift": "struct A { let x = 1 } // c", "ts": "const x: number = 1 // c", "tsx": "const a = <div id=\"x\">hi</div>",
            "js": "function f() { return 'x' } // c", "py": "def f():\n    return 'x'  # c", "rs": "fn main() { let x = \"s\"; } // c",
            "go": "package main\nfunc f() string { return \"x\" } // c", "lua": "local x = 'y' -- c", "rb": "def f\n  'x' # c\nend",
            "c": "int main(void) { return 0; } // c", "cpp": "class A { public: int x = 0; }; // c", "json": "{\"a\": 1, \"b\": true}",
            "md": "# Title\n\nSome `code` text.",
        ]
        for (ext, source) in samples {
            let highlighter = try XCTUnwrap(SyntaxHighlighter(fileExtension: ext, text: Rope(source), theme: theme), "\(ext) loads")
            let colored = (0..<Rope(source).lineCount).flatMap { highlighter.spans(forLine: $0) }
            XCTAssertFalse(colored.isEmpty, "\(ext) colors something: \(highlighter.treeDescription.prefix(200))")
        }
        XCTAssertNil(SyntaxHighlighter(fileExtension: "txt", text: Rope("plain")), "plain text isn't highlighted")
        // Alloy's split of each query into patterns agrees with tree-sitter's count, which the
        // container companions' precedence depends on.
        for ext in ["swift", "ts", "tsx", "js", "py", "rs", "go", "lua", "rb", "c", "cpp", "json", "md"] {
            let language = try XCTUnwrap(SyntaxLanguage.forExtension(ext))
            XCTAssertEqual(language.splitPatternCount, language.highlights.patternCount, ext)
        }
        XCTAssertEqual(SyntaxLanguage.forExtension("swift")?.containerPatterns?.entries.map(\.container), ["class_body"])
        // Lua's second one (`(table_constructor ["{" "}"] @constructor)`) has two children and
        // can't be stripped: a table of more than 512 entries loses only its braces' color.
        XCTAssertEqual(SyntaxLanguage.forExtension("lua")?.containerPatterns?.entries.map(\.container), ["table_constructor"])
    }

    private func color(_ highlighter: SyntaxHighlighter, line: Int, at column: Int) -> SIMD4<Float>? {
        highlighter.spans(forLine: line).first { $0.range.contains(column) }?.color
    }

    func testSwiftColorsLandOnTheirTokens() throws {
        let source = "struct Greeting {\n    let text = \"hello\" // note\n    func say() -> Int { 42 }\n}"
        let h = try XCTUnwrap(SyntaxHighlighter(fileExtension: "swift", text: Rope(source), theme: theme))
        XCTAssertEqual(color(h, line: 0, at: 0), theme.color(for: "keyword"), "struct")
        XCTAssertEqual(color(h, line: 0, at: 7), theme.color(for: "type"), "Greeting")
        XCTAssertEqual(color(h, line: 1, at: 16), theme.color(for: "string"), "\"hello\"")
        XCTAssertEqual(color(h, line: 1, at: 26), theme.color(for: "comment"), "// note")
        XCTAssertEqual(color(h, line: 2, at: 9), theme.color(for: "function"), "say")
        XCTAssertEqual(color(h, line: 2, at: 24), theme.color(for: "number"), "42")
        XCTAssertLessThan(h.lastParseMilliseconds, 50)
    }

    /// The incrementally updated tree colors every line exactly as a fresh parse of the same
    /// text does, across random edits.
    func testIncrementalHighlightingMatchesAFreshParse() throws {
        var generator = SplitMix(seed: 7)
        let pieces = ["let ", "x", " = ", "\"s\"", "// c\n", "\n", "{", "}", "/* ", " */", "func f() ", "42", "\"unterminated", "😀"]
        let buffer = TextBuffer(String(repeating: "struct S {\n    let a = 1 // one\n    func f() -> String { \"x\" }\n}\n", count: 20))
        let h = try XCTUnwrap(SyntaxHighlighter(fileExtension: "swift", text: buffer.text, theme: theme))
        buffer.onChange = { h.apply($0.edits, newText: buffer.text) }
        for step in 0..<150 {
            let length = buffer.text.utf16Count
            let at = Int(generator.next() % UInt64(length + 1))
            let end = min(length, at + Int(generator.next() % 12))
            let text = generator.next() % 4 == 0 ? "" : pieces[Int(generator.next() % UInt64(pieces.count))]
            buffer.apply([TextEdit(range: at..<end, text: text)])
            // Read a few lines each step, so the cache is exercised between edits.
            for line in stride(from: 0, to: buffer.text.lineCount, by: 17) { _ = h.spans(forLine: line) }
            if step % 25 == 24 {
                h.waitForParse()
                let fresh = try XCTUnwrap(SyntaxHighlighter(fileExtension: "swift", text: buffer.text, theme: theme))
                for line in 0..<buffer.text.lineCount {
                    XCTAssertEqual(h.spans(forLine: line).map(\.range), fresh.spans(forLine: line).map(\.range), "line \(line) after step \(step)")
                }
            }
        }
    }

    func testOpeningABlockCommentRecolorsLinesBelow() throws {
        let buffer = TextBuffer("let a = 1\nlet b = 2\nlet c = 3 */\nlet d = 4\n")
        let h = try XCTUnwrap(SyntaxHighlighter(fileExtension: "swift", text: buffer.text, theme: theme))
        var invalidated = 0
        h.onInvalidate = { invalidated += 1 }
        buffer.onChange = { h.apply($0.edits, newText: buffer.text) }
        XCTAssertEqual(color(h, line: 1, at: 0), theme.color(for: "keyword"))
        buffer.apply([TextEdit(range: 0..<0, text: "/* ")])
        h.waitForParse()
        XCTAssertEqual(color(h, line: 1, at: 0), theme.color(for: "comment"), "the lines up to the */ are one comment now")
        XCTAssertEqual(color(h, line: 3, at: 0), theme.color(for: "keyword"), "and after it, code again")
        XCTAssertGreaterThan(invalidated, 0, "the editor is told to redraw lines beyond the edit")
    }

    /// Querying from the node that holds a line gives exactly what querying from the root does,
    /// on real files in several languages.
    func testTheQueryShortcutMatchesTheRootQuery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let checkouts = root.appendingPathComponent(".build/checkouts")
        let files: [(String, URL)] = [
            ("swift", root.appendingPathComponent("Sources/AlloyAppKit/AlloyTextView.swift")),
            ("swift", root.appendingPathComponent("Sources/AlloyCore/Rope.swift")),
            ("js", checkouts.appendingPathComponent("tree-sitter-javascript/grammar.js")),
            ("py", checkouts.appendingPathComponent("tree-sitter-python/setup.py")),
            ("md", root.appendingPathComponent("docs/DESIGN.md")),
            ("c", checkouts.appendingPathComponent("tree-sitter-c/src/tree_sitter/parser.h")),
        ]
        // A body big enough (2,000 members) to take the per-child path.
        let member = "    @MainActor weak var editor: Editor? = nil // note\n    func say(_ x: Int) -> String { \"x\\(x)\" }\n"
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-big-\(UUID().uuidString).swift")
        try ("final class Big {\n" + String(repeating: member, count: 1_000) + "}\n").write(to: big, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: big) }
        for (ext, url) in files + [("swift", big)] {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { XCTFail("missing \(url.lastPathComponent)"); continue }
            let rope = Rope(source)
            let fast = try XCTUnwrap(SyntaxHighlighter(fileExtension: ext, text: rope, theme: theme))
            SyntaxHighlighter.queryFromRoot = true
            let slow = try XCTUnwrap(SyntaxHighlighter(fileExtension: ext, text: rope, theme: theme))
            var differing = 0
            for line in 0..<rope.lineCount {
                SyntaxHighlighter.queryFromRoot = true
                let expected = slow.spans(forLine: line)
                SyntaxHighlighter.queryFromRoot = false
                let got = fast.spans(forLine: line)
                if got != expected {
                    if differing < 3 {
                        let lineText = rope.substring(rope.range(ofLine: line))
                        func show(_ spans: [StyleSpan]) -> String { spans.map { s in "\(s.range)=\(lineText.utf16Substring(s.range))" }.joined(separator: " ") }
                        print("DIFF \(url.lastPathComponent):\(line) \(lineText.trimmingCharacters(in: .whitespaces).prefix(60))\n   root: \(show(expected))\n   fast: \(show(got))")
                    }
                    differing += 1
                }
            }
            SyntaxHighlighter.queryFromRoot = false
            XCTAssertEqual(differing, 0, "\(url.lastPathComponent): \(differing) of \(rope.lineCount) lines differ")
        }
    }

    func testIncrementalCost() throws {
        for (ext, open, line) in [("swift", "struct Big {\n", "    let value = compute(input) // note\n"), ("js", "function big() {\n", "  const value = compute(input) // note\n"),
                                  ("swift", "", "let value = compute(input) // note\n")] {
        for count in [1_000, 5_000, 20_000] {
            let buffer = TextBuffer(open + String(repeating: line, count: count) + (open.isEmpty ? "" : "}\n"))
            let start = CACurrentMediaTime()
            let h = try XCTUnwrap(SyntaxHighlighter(fileExtension: ext, text: buffer.text, theme: theme))
            let full = (CACurrentMediaTime() - start) * 1000
            buffer.onChange = { h.apply($0.edits, newText: buffer.text) }
            buffer.setSelections([Selection(caret: buffer.text.offset(ofLine: count / 2) + 20)])
            let keyStart = CACurrentMediaTime()
            buffer.insert("x")
            let onMain = (CACurrentMediaTime() - keyStart) * 1000
            h.waitForParse()
            print(String(format: "%@ %@ lines %d: full %.1f ms, keystroke on main %.2f ms, reparse %.2f ms", ext, open.isEmpty ? "top-level" : "in a block", count, full, onMain, h.lastParseMilliseconds))
        }
        }
    }

    func testABigFileParsesInTheBackgroundAndCatchesUpOnEdits() throws {
        let line = "    let value = compute(input) // 😀 note\n"
        let buffer = TextBuffer("struct Big {\n" + String(repeating: line, count: 40_000) + "}\n")
        XCTAssertGreaterThan(buffer.text.utf16Count, SyntaxHighlighter.synchronousLimit)
        let h = try XCTUnwrap(SyntaxHighlighter(fileExtension: "swift", text: buffer.text, theme: theme))
        buffer.onChange = { h.apply($0.edits, newText: buffer.text) }
        XCTAssertFalse(h.isReady)
        XCTAssertEqual(h.spans(forLine: 1), [], "plain until the parse lands")
        buffer.apply([TextEdit(range: 0..<0, text: "// top\n")])
        var landings = 0
        h.onInvalidate = { landings += 1 }
        h.waitForParse(timeout: 30)
        XCTAssertTrue(h.isReady)
        XCTAssertGreaterThanOrEqual(landings, 1, "the editor is told when colors arrive")
        XCTAssertEqual(color(h, line: 0, at: 0), theme.color(for: "comment"), "the edit made during the parse is in the tree")
        XCTAssertEqual(color(h, line: 2, at: 4), theme.color(for: "keyword"), "let, on its shifted line")
        print("background parse of \(buffer.text.utf16Count / 1_000_000) M units: \(String(format: "%.0f", h.lastParseMilliseconds)) ms")
        for trial in 0..<3 {
            let t = CACurrentMediaTime()
            _ = h.spans(forLine: 30_000 + trial)
            print(String(format: "coloring a line of the freshly parsed tree: %.2f ms", (CACurrentMediaTime() - t) * 1000))
        }
        // A keystroke: what typing waits for is the main-thread part (edit the tree, shift the
        // cache); the reparse runs in the background.
        buffer.setSelections([Selection(caret: buffer.text.offset(ofLine: 20_000) + 4)])
        let start = CACurrentMediaTime()
        buffer.insert("x")
        let keystroke = (CACurrentMediaTime() - start) * 1000
        let colorStart = CACurrentMediaTime()
        _ = h.spans(forLine: 20_000)
        let recolor = (CACurrentMediaTime() - colorStart) * 1000
        h.waitForParse()
        print(String(format: "keystroke on the main thread %.2f ms; re-coloring its line %.2f ms; background reparse %.0f ms", keystroke, recolor, h.lastParseMilliseconds))
        XCTAssertLessThan(keystroke, 8, "the keystroke budget")
        XCTAssertLessThan(recolor, 2, "the re-highlight budget")
        XCTAssertEqual(color(h, line: 20_000, at: 4), nil, "\"xlet\" is an identifier now, not a keyword")
    }
}

extension StyleSpan: Equatable {
    public static func == (a: StyleSpan, b: StyleSpan) -> Bool { a.range == b.range && a.color == b.color }
}

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

extension String {
    func utf16Substring(_ range: Range<Int>) -> String {
        let units = Array(utf16)
        return String(decoding: units[max(0, range.lowerBound)..<min(units.count, range.upperBound)], as: UTF16.self)
    }
}
