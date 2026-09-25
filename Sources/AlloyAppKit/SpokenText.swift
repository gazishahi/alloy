import AlloyCore
import Foundation

/// What VoiceOver reads for a document whose lines carry spoken prefixes (a diff: "added, ",
/// "removed, "), and the mapping between offsets in it and in the buffer, so every query
/// (value, lines, ranges, where a range is on screen) agrees with the text it reads.
/// Lines are the buffer's lines; a prefix never contains a line break.
final class SpokenText {
    let string: NSString
    private let valueStarts: [Int]
    private let bufferStarts: [Int]
    private let prefixLengths: [Int]

    init(_ text: Rope, prefix: (Int) -> String?) {
        var out = ""
        var valueStarts: [Int] = [], bufferStarts: [Int] = [], prefixLengths: [Int] = []
        valueStarts.reserveCapacity(text.lineCount)
        var value = 0
        for line in 0..<text.lineCount {
            let range = text.range(ofLine: line)
            let lineText = text.substring(range)
            let head = prefix(line) ?? ""
            let tail = line + 1 < text.lineCount ? "\n" : ""
            valueStarts.append(value)
            bufferStarts.append(range.lowerBound)
            let headLength = (head as NSString).length
            prefixLengths.append(headLength)
            out += head + lineText + tail
            value += headLength + (lineText as NSString).length + (tail.isEmpty ? 0 : 1)
        }
        string = out as NSString
        self.valueStarts = valueStarts
        self.bufferStarts = bufferStarts
        self.prefixLengths = prefixLengths
    }

    var length: Int { string.length }
    var lineCount: Int { valueStarts.count }

    /// The line a value offset is on.
    func line(ofValue offset: Int) -> Int {
        var low = 0, high = valueStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if valueStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    /// A value offset in the buffer: inside a prefix, the start of the line's text.
    func toBuffer(_ offset: Int) -> Int {
        guard !valueStarts.isEmpty else { return 0 }
        let line = line(ofValue: offset)
        return bufferStarts[line] + max(0, offset - valueStarts[line] - prefixLengths[line])
    }

    func toValue(_ offset: Int, in text: Rope) -> Int {
        guard !valueStarts.isEmpty else { return 0 }
        let line = min(text.line(containing: offset), valueStarts.count - 1)
        return valueStarts[line] + prefixLengths[line] + (offset - bufferStarts[line])
    }

    func rangeOfLine(_ line: Int) -> NSRange {
        let start = valueStarts[line]
        let end = line + 1 < valueStarts.count ? valueStarts[line + 1] : string.length
        return NSRange(location: start, length: end - start)
    }
}
