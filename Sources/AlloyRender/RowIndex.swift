/// How many visual rows each line takes (1 unless it wraps), as a Fenwick tree: the row a line
/// starts at, and the line at a given row, both in O(log n). This is what lets a 100,000-line
/// file scroll without laying out every line: unmeasured lines count as one row until drawn.
struct RowIndex {
    private var tree: [Int]
    private(set) var rows: [Int]

    init(lineCount: Int) {
        rows = Array(repeating: 1, count: max(1, lineCount))
        tree = []
        rebuild()
    }

    init(rows: [Int]) {
        self.rows = rows.isEmpty ? [1] : rows
        tree = []
        rebuild()
    }

    var lineCount: Int { rows.count }
    var totalRows: Int { prefix(rows.count) }

    private mutating func rebuild() {
        tree = [0] + rows
        let n = rows.count
        var i = 1
        while i <= n {
            let parent = i + (i & -i)
            if parent <= n { tree[parent] += tree[i] }
            i += 1
        }
    }

    mutating func set(line: Int, rows count: Int) {
        guard rows.indices.contains(line), rows[line] != count else { return }
        let delta = count - rows[line]
        rows[line] = count
        var i = line + 1
        while i < tree.count {
            tree[i] += delta
            i += i & -i
        }
    }

    /// Rows before `line`.
    func prefix(_ line: Int) -> Int {
        var sum = 0
        var i = min(line, rows.count)
        while i > 0 {
            sum += tree[i]
            i -= i & -i
        }
        return sum
    }

    /// The line a row falls on, and which of that line's rows it is.
    func line(atRow row: Int) -> (line: Int, rowInLine: Int) {
        guard row > 0 else { return (0, 0) }
        var position = 0
        var remaining = row
        var step = 1
        while step * 2 <= rows.count { step *= 2 }
        while step > 0 {
            let next = position + step
            if next <= rows.count, tree[next] <= remaining {
                position = next
                remaining -= tree[next]
            }
            step /= 2
        }
        guard position < rows.count else { return (rows.count - 1, rows[rows.count - 1] - 1) }
        return (position, remaining)
    }

    /// After an edit replaced lines `start ..< start + oldCount` with `newCount` lines: those
    /// are unmeasured (one row each) until drawn again.
    mutating func replaceLines(start: Int, oldCount: Int, newCount: Int) {
        let lower = min(start, rows.count)
        let upper = min(rows.count, lower + oldCount)
        if upper - lower == newCount {
            // The common case (typing within lines): no lines come or go, so no rebuild.
            for line in lower..<upper { set(line: line, rows: 1) }
            return
        }
        rows.replaceSubrange(lower..<upper, with: Array(repeating: 1, count: newCount))
        if rows.isEmpty { rows = [1] }
        rebuild()
    }
}
