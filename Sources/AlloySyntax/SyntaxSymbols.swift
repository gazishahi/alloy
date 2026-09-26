import AlloyCore
import Foundation
import SwiftTreeSitter

/// A declaration in a document, found in its syntax tree: an outline for files with no language
/// server, in every language Alloy highlights.
public struct SyntaxSymbol: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case `class`, `struct`, `enum`, interface, `protocol`, `extension`, function, method, constructor
        case property, variable, constant, module, type, heading, key
    }
    public let name: String
    public let kind: Kind
    /// The whole declaration, and its name, in UTF-16 offsets.
    public let range: Range<Int>
    public let nameRange: Range<Int>
    public let children: [SyntaxSymbol]

    public init(name: String, kind: Kind, range: Range<Int>, nameRange: Range<Int>, children: [SyntaxSymbol] = []) {
        self.name = name
        self.kind = kind
        self.range = range
        self.nameRange = nameRange
        self.children = children
    }
}

/// A tree to find symbols in: a copy, so it can be walked on any thread while the editor goes on.
public struct SyntaxSymbolSource: @unchecked Sendable {
    let tree: Tree
    let text: Rope
    let languageName: String

    /// The outline, declarations nested in what contains them. Locals inside functions aren't
    /// in it; a function's nested functions are.
    public func symbols() -> [SyntaxSymbol] {
        guard let root = tree.rootNode, let rules = SymbolRules.rules[languageName] else { return [] }
        var budget = 200_000   // nodes: a pathological file stops, rather than stalls
        return walk(root, rules: rules, insideFunction: false, budget: &budget)
    }

    private func walk(_ node: Node, rules: [String: SymbolRules.Rule], insideFunction: Bool, budget: inout Int) -> [SyntaxSymbol] {
        var found: [SyntaxSymbol] = []
        for index in 0..<node.namedChildCount {
            budget -= 1
            guard budget > 0, let child = node.namedChild(at: index), let type = child.nodeType else { continue }
            if let rule = rules[type], !(rule.onlyOutsideFunctions && insideFunction), let symbol = symbol(child, rule: rule, rules: rules, budget: &budget) {
                found.append(symbol)
            } else {
                found += walk(child, rules: rules, insideFunction: insideFunction, budget: &budget)
            }
        }
        return found
    }

    private func symbol(_ node: Node, rule: SymbolRules.Rule, rules: [String: SymbolRules.Rule], budget: inout Int) -> SyntaxSymbol? {
        guard let nameNode = rule.name(node) else { return nil }
        let nameRange = Self.utf16(nameNode.range)
        var name = text.substring(nameRange).trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.kind == .key { name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        if let first = name.split(separator: "\n").first { name = String(first) }
        guard !name.isEmpty else { return nil }
        var kind = rule.kind
        if !rule.keywordKinds.isEmpty, let keyword = node.child(byFieldName: "declaration_kind") ?? node.child(at: 0) {
            kind = rule.keywordKinds[text.substring(Self.utf16(keyword.range))] ?? kind
        }
        let isFunction = [.function, .method, .constructor].contains(kind)
        let children = rule.hasChildren ? walk(node, rules: rules, insideFunction: isFunction, budget: &budget) : []
        return SyntaxSymbol(name: name, kind: kind, range: Self.utf16(node.range), nameRange: nameRange, children: children)
    }

    private static func utf16(_ range: NSRange) -> Range<Int> { range.location..<(range.location + range.length) }
}

extension SyntaxHighlighter {
    /// The tree as it stands, for `SyntaxSymbolSource.symbols()` off the main thread; nil
    /// before the first parse lands.
    public func symbolSource() -> SyntaxSymbolSource? {
        guard isReady, let copy = currentTreeCopy() else { return nil }
        return SyntaxSymbolSource(tree: copy, text: text, languageName: language.name)
    }
}

/// Which nodes are declarations in each language, and where their names are.
enum SymbolRules {
    struct Rule: Sendable {
        let kind: SyntaxSymbol.Kind
        let name: @Sendable (Node) -> Node?
        var hasChildren = true
        /// Variables count only outside functions (a module's constants, not a loop's index).
        var onlyOutsideFunctions = false
        /// A kind read from the declaration's keyword (Swift's `class_declaration` is also its
        /// structs, enums, actors and extensions).
        var keywordKinds: [String: SyntaxSymbol.Kind] = [:]
    }

    static func field(_ name: String) -> @Sendable (Node) -> Node? { { $0.child(byFieldName: name) } }
    /// The first named child of one of `types`, searched breadth-first a few levels down (C's
    /// declarators nest the name inside pointer and function declarators).
    static func first(_ types: Set<String>, depth: Int = 4) -> @Sendable (Node) -> Node? {
        { node in
            var level = [node]
            for _ in 0..<depth {
                var next: [Node] = []
                for n in level {
                    for i in 0..<n.namedChildCount {
                        guard let c = n.namedChild(at: i) else { continue }
                        if let t = c.nodeType, types.contains(t) { return c }
                        next.append(c)
                    }
                }
                level = next
            }
            return nil
        }
    }
    static func either(_ a: @escaping @Sendable (Node) -> Node?, _ b: @escaping @Sendable (Node) -> Node?) -> @Sendable (Node) -> Node? { { a($0) ?? b($0) } }

    static let jsRules: [String: Rule] = [
        "class_declaration": Rule(kind: .class, name: field("name")),
        "abstract_class_declaration": Rule(kind: .class, name: field("name")),
        "function_declaration": Rule(kind: .function, name: field("name")),
        "generator_function_declaration": Rule(kind: .function, name: field("name")),
        "method_definition": Rule(kind: .method, name: field("name")),
        "method_signature": Rule(kind: .method, name: field("name"), hasChildren: false),
        "interface_declaration": Rule(kind: .interface, name: field("name")),
        "type_alias_declaration": Rule(kind: .type, name: field("name"), hasChildren: false),
        "enum_declaration": Rule(kind: .enum, name: field("name")),
        "public_field_definition": Rule(kind: .property, name: field("name"), hasChildren: false),
        "field_definition": Rule(kind: .property, name: field("property"), hasChildren: false),
        "property_signature": Rule(kind: .property, name: field("name"), hasChildren: false),
        "internal_module": Rule(kind: .module, name: field("name")),
        "variable_declarator": Rule(kind: .variable, name: field("name"), onlyOutsideFunctions: true),
    ]

    static let cRules: [String: Rule] = [
        "function_definition": Rule(kind: .function, name: first(["identifier", "field_identifier", "qualified_identifier", "destructor_name", "operator_name"]), hasChildren: false),
        "struct_specifier": Rule(kind: .struct, name: field("name")),
        "enum_specifier": Rule(kind: .enum, name: field("name")),
        "union_specifier": Rule(kind: .struct, name: field("name")),
        "type_definition": Rule(kind: .type, name: field("declarator"), hasChildren: false),
    ]

    static let rules: [String: [String: Rule]] = [
        "swift": [
            "class_declaration": Rule(kind: .class, name: either(field("name"), first(["user_type", "type_identifier"], depth: 1)),
                                      keywordKinds: ["struct": .struct, "enum": .enum, "extension": .extension, "actor": .class, "class": .class]),
            "protocol_declaration": Rule(kind: .protocol, name: field("name")),
            "function_declaration": Rule(kind: .function, name: field("name")),
            "protocol_function_declaration": Rule(kind: .method, name: field("name"), hasChildren: false),
            "init_declaration": Rule(kind: .constructor, name: { $0.child(at: 0) }),
            "property_declaration": Rule(kind: .property, name: first(["simple_identifier"], depth: 3), hasChildren: false, onlyOutsideFunctions: true),
            "typealias_declaration": Rule(kind: .type, name: field("name"), hasChildren: false),
        ],
        "typescript": jsRules, "tsx": jsRules, "javascript": jsRules,
        "python": [
            "class_definition": Rule(kind: .class, name: field("name")),
            "function_definition": Rule(kind: .function, name: field("name")),
        ],
        "rust": [
            "struct_item": Rule(kind: .struct, name: field("name")),
            "enum_item": Rule(kind: .enum, name: field("name")),
            "union_item": Rule(kind: .struct, name: field("name")),
            "trait_item": Rule(kind: .interface, name: field("name")),
            "impl_item": Rule(kind: .extension, name: field("type")),
            "function_item": Rule(kind: .function, name: field("name")),
            "function_signature_item": Rule(kind: .method, name: field("name"), hasChildren: false),
            "mod_item": Rule(kind: .module, name: field("name")),
            "const_item": Rule(kind: .constant, name: field("name"), hasChildren: false),
            "static_item": Rule(kind: .constant, name: field("name"), hasChildren: false),
            "type_item": Rule(kind: .type, name: field("name"), hasChildren: false),
            "macro_definition": Rule(kind: .function, name: field("name"), hasChildren: false),
        ],
        "go": [
            "function_declaration": Rule(kind: .function, name: field("name")),
            "method_declaration": Rule(kind: .method, name: field("name")),
            "type_spec": Rule(kind: .type, name: field("name")),
            "const_spec": Rule(kind: .constant, name: field("name"), hasChildren: false, onlyOutsideFunctions: true),
        ],
        "lua": [
            "function_declaration": Rule(kind: .function, name: field("name")),
        ],
        "ruby": [
            "class": Rule(kind: .class, name: field("name")),
            "module": Rule(kind: .module, name: field("name")),
            "method": Rule(kind: .method, name: field("name")),
            "singleton_method": Rule(kind: .method, name: field("name")),
        ],
        "c": cRules,
        "cpp": cRules.merging([
            "class_specifier": Rule(kind: .class, name: field("name")),
            "namespace_definition": Rule(kind: .module, name: field("name")),
        ]) { $1 },
        "json": [
            "pair": Rule(kind: .key, name: field("key")),
        ],
        "yaml": [
            "block_mapping_pair": Rule(kind: .key, name: field("key")),
        ],
        "toml": [
            "table": Rule(kind: .module, name: first(["bare_key", "dotted_key", "quoted_key"], depth: 1)),
            "table_array_element": Rule(kind: .module, name: first(["bare_key", "dotted_key", "quoted_key"], depth: 1)),
        ],
        "css": [
            "rule_set": Rule(kind: .key, name: first(["selectors"], depth: 1), hasChildren: false),
            "keyframes_statement": Rule(kind: .key, name: first(["keyframes_name"], depth: 1), hasChildren: false),
        ],
        "scss": [
            "rule_set": Rule(kind: .key, name: first(["selectors"], depth: 1)),
            "mixin_statement": Rule(kind: .function, name: field("name")),
        ],
        "bash": [
            "function_definition": Rule(kind: .function, name: field("name")),
        ],
        "java": [
            "class_declaration": Rule(kind: .class, name: field("name")),
            "interface_declaration": Rule(kind: .interface, name: field("name")),
            "enum_declaration": Rule(kind: .enum, name: field("name")),
            "record_declaration": Rule(kind: .struct, name: field("name")),
            "method_declaration": Rule(kind: .method, name: field("name")),
            "constructor_declaration": Rule(kind: .constructor, name: field("name")),
            "field_declaration": Rule(kind: .property, name: first(["identifier"], depth: 2), hasChildren: false),
        ],
        "php": [
            "class_declaration": Rule(kind: .class, name: field("name")),
            "interface_declaration": Rule(kind: .interface, name: field("name")),
            "trait_declaration": Rule(kind: .interface, name: field("name")),
            "enum_declaration": Rule(kind: .enum, name: field("name")),
            "function_definition": Rule(kind: .function, name: field("name")),
            "method_declaration": Rule(kind: .method, name: field("name")),
        ],
        "dockerfile": [
            "from_instruction": Rule(kind: .module, name: either(field("as"), first(["image_spec"], depth: 1)), hasChildren: false),
        ],
        "make": [
            "rule": Rule(kind: .function, name: first(["targets"], depth: 1), hasChildren: false),
        ],
        "sql": [
            "create_table": Rule(kind: .struct, name: first(["object_reference"], depth: 1), hasChildren: false),
            "create_view": Rule(kind: .type, name: first(["object_reference"], depth: 1), hasChildren: false),
            "create_function": Rule(kind: .function, name: first(["object_reference"], depth: 1), hasChildren: false),
            "create_index": Rule(kind: .key, name: first(["identifier"], depth: 1), hasChildren: false),
        ],
        "markdown": [
            "atx_heading": Rule(kind: .heading, name: either(first(["inline", "heading_content"], depth: 1), { $0.namedChild(at: 1) }), hasChildren: false),
            "setext_heading": Rule(kind: .heading, name: { $0.namedChild(at: 0) }, hasChildren: false),
        ],
    ]
}
