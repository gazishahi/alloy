/// Where a document can fold: a line whose following lines are indented deeper starts a region,
/// and the region runs to the last of them. Indentation works in every language, with or without
/// a grammar; a closing brace at the opening line's depth stays outside, visible.
public enum Folding {
    /// Regions as `header...last`: folding one hides `header + 1 ... last`.
    public static func ranges(in text: Rope, tabSize: Int = 4) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        // Open regions: their header and its depth, innermost last.
        var open: [(header: Int, depth: Int)] = []
        var lastNonBlank = -1
        // One pass over the text's UTF-16, each line's indentation read as it goes: copying
        // every line out first cost most of the time on a big file.
        var line = 0, column = 0, inIndent = true
        func lineHasText(depth: Int) {
            while let top = open.last, top.depth >= depth {
                open.removeLast()
                if lastNonBlank > top.header { result.append(top.header...lastNonBlank) }
            }
            open.append((line, depth))
            lastNonBlank = line
        }
        for unit in text.string.utf16 {
            if unit == 0x0A {
                line += 1
                column = 0
                inIndent = true
                continue
            }
            guard inIndent else { continue }
            switch unit {
            case 0x20: column += 1
            case 0x09: column += tabSize - column % tabSize
            case 0x0D: break
            default:
                inIndent = false
                lineHasText(depth: column)
            }
        }
        for region in open.reversed() where lastNonBlank > region.header {
            result.append(region.header...lastNonBlank)
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Columns of leading whitespace, a tab to the next stop; nil for a blank line.
    static func indentation(of line: String, tabSize: Int) -> Int? {
        var column = 0
        for unit in line.utf16 {
            switch unit {
            case 0x20: column += 1
            case 0x09: column += tabSize - column % tabSize
            case 0x0D, 0x0A: return nil
            default: return column
            }
        }
        return nil
    }
}
