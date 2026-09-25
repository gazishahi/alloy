import AlloyCore
import Foundation

// AlloyCore's numbers against the budgets in README.md. Run optimized:
//   swift run -c release AlloyBenchmarks

func measure(_ name: String, iterations: Int = 1, _ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { body() }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    let per = seconds / Double(iterations)
    let text = per < 1e-3 ? String(format: "%.2f µs", per * 1e6) : String(format: "%.2f ms", per * 1e3)
    print(name.padding(toLength: 44, withPad: " ", startingAt: 0), text, iterations > 1 ? "(each, \(iterations) runs)" : "")
    return per
}

let swiftLine = "        let value = try await client.fetch(request, retries: 3) // 😀 note\n"
let code = String(repeating: swiftLine, count: 100_000)
let logLine = "2026-09-24T12:00:00Z INFO request id=abc123 path=/api/v1/items status=200 took=12ms\n"
let log = String(repeating: logLine, count: 20_000_000 / logLine.utf8.count)

print("100,000-line Swift file (\(code.utf8.count / 1_000_000) MB), 20 MB log\n")
var rope = Rope()
_ = measure("build rope: 100k lines") { rope = Rope(code) }
var big = Rope()
_ = measure("build rope: 20 MB") { big = Rope(log) }
print("  height \(rope.height) / \(big.height), \(rope.chunks.count) / \(big.chunks.count) leaves")

var generator = SystemRandomNumberGenerator()
_ = measure("insert a character (random place)", iterations: 100_000) {
    rope.insert("x", at: Int.random(in: 0...rope.utf16Count, using: &generator))
}
_ = measure("delete a character (random place)", iterations: 100_000) {
    let at = Int.random(in: 0..<rope.utf16Count, using: &generator)
    rope.delete(at..<(at + 1))
}
_ = measure("line containing (random offset)", iterations: 100_000) {
    _ = big.line(containing: Int.random(in: 0...big.utf16Count, using: &generator))
}
_ = measure("line start (random line)", iterations: 100_000) {
    _ = big.offset(ofLine: Int.random(in: 0..<big.lineCount, using: &generator))
}
_ = measure("read a screenful (60 lines)", iterations: 10_000) {
    let first = Int.random(in: 0..<(big.lineCount - 60), using: &generator)
    _ = big.substring(big.offset(ofLine: first)..<big.offset(ofLine: first + 60))
}
_ = measure("snapshot and edit a copy (undo's cost)", iterations: 100_000) {
    var copy = big
    copy.insert("y", at: 1_000_000)
}

let buffer = TextBuffer(code)
buffer.setSelections((0..<1_000).map { Selection(caret: buffer.text.offset(ofLine: $0 * 100)) })
_ = measure("type with 1,000 cursors", iterations: 100) { buffer.insert("z") }
_ = measure("undo it all", iterations: 1) { while buffer.undo() {} }
