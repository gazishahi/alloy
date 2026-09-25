import Foundation
import SwiftTreeSitter

/// Highlight patterns rooted at a node that can hold a great many children, rewritten to run
/// from those children (see `SyntaxHighlighter.spans(forLine:)`).
///
/// Coloring a line queries from the node that holds it, because a query cursor steps over every
/// sibling before its range and a body of 40,000 statements makes that ~80 ms a line. In a body
/// that large the query runs on each child the line touches instead, which can't see a pattern
/// rooted at the body itself, like Swift's `(class_body (property_declaration ...))`. Those few
/// patterns (three across Side's thirteen languages) are stripped of their container here and
/// run as a companion query on the children, keeping their original pattern index so
/// precedence is unchanged.
final class ContainerPatterns: @unchecked Sendable {
    struct Entry {
        /// The container's node type, and the stripped pattern's root node type.
        let container: String
        let root: String
        /// The pattern's index in the language's full highlight query.
        let originalIndex: Int
    }

    let query: Query
    let entries: [Entry]

    /// Container node types that can grow without bound (bodies, lists, top levels).
    static let containers: Set<String> = [
        "class_body", "protocol_body", "enum_class_body", "source_file", "program", "module", "translation_unit",
        "document", "block", "statements", "compound_statement", "declaration_list", "field_declaration_list",
        "chunk", "statement_block", "table_constructor", "object", "array", "body_statement",
    ]

    init?(language: Language, source: String, patternCount: Int) {
        let patterns = Self.topLevelPatterns(source)
        // Precedence rides on pattern indices: if this split disagrees with tree-sitter's own
        // count, don't guess.
        guard patterns.count == patternCount else { return nil }
        var stripped: [String] = []
        var entries: [Entry] = []
        for (index, pattern) in patterns.enumerated() {
            guard let (container, inner, root) = Self.strip(pattern), Self.containers.contains(container) else { continue }
            stripped.append(inner)
            entries.append(Entry(container: container, root: root, originalIndex: index))
        }
        guard !stripped.isEmpty, let query = try? Query(language: language, data: Data(stripped.joined(separator: "\n").utf8)) else { return nil }
        self.query = query
        self.entries = entries
    }

    /// Splits a query into its top-level patterns, in order: each opens at depth zero with `(`,
    /// `[` or a string, and takes the captures and quantifiers after it.
    static func topLevelPatterns(_ source: String) -> [String] {
        var patterns: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var escaped = false
        var inComment = false
        for character in source {
            if inComment {
                if character == "\n" { inComment = false }
                continue
            }
            if inString {
                current.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case ";":
                inComment = true
            case "\"":
                // A string at the top level is a pattern of its own (`"func" @keyword`).
                if depth == 0, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    patterns.append(current)
                    current = ""
                }
                inString = true
                current.append(character)
            case "(", "[":
                if depth == 0, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    patterns.append(current)
                    current = ""
                }
                depth += 1
                current.append(character)
            case ")", "]":
                depth -= 1
                current.append(character)
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { patterns.append(current) }
        return patterns
    }

    /// `(T child)` → (T, child, child's root type), when the container holds exactly one child
    /// pattern (predicates aside).
    static func strip(_ pattern: String) -> (container: String, inner: String, root: String)? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("(") else { return nil }
        let scalars = Array(trimmed)
        var index = 1
        var name = ""
        while index < scalars.count, scalars[index].isLetter || scalars[index] == "_" || scalars[index].isNumber { name.append(scalars[index]); index += 1 }
        guard !name.isEmpty else { return nil }
        // The container's closing parenthesis.
        var depth = 1
        var close = index
        var inString = false
        while close < scalars.count, depth > 0 {
            let c = scalars[close]
            if inString { if c == "\"" { inString = false } } else if c == "\"" { inString = true } else if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { depth -= 1 }
            if depth > 0 { close += 1 }
        }
        guard close < scalars.count else { return nil }
        let body = String(scalars[index..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Children of the container pattern: exactly one node pattern; predicates travel with it.
        let children = topLevelPatterns(body).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let nodes = children.filter { !$0.hasPrefix("(#") }
        guard nodes.count == 1, nodes[0].hasPrefix("(") else { return nil }
        let predicates = children.filter { $0.hasPrefix("(#") }
        let child = nodes[0]
        var rootName = ""
        for c in child.dropFirst() {
            if c.isLetter || c == "_" || c.isNumber { rootName.append(c) } else { break }
        }
        guard !rootName.isEmpty else { return nil }
        let inner = predicates.isEmpty ? child : "(" + child + " " + predicates.joined(separator: " ") + ")"
        return (name, inner, rootName)
    }
}
