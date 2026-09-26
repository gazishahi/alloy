import Foundation
import SwiftTreeSitter
import TreeSitterC
import TreeSitterCPP
import TreeSitterGo
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterLua
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwiftGrammar
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAMLGrammar
import TreeSitterTOMLGrammar
import TreeSitterHTMLGrammar
import TreeSitterCSSGrammar
import TreeSitterSCSSGrammar
import TreeSitterBashGrammar
import TreeSitterJavaGrammar
import TreeSitterPHPGrammar
import TreeSitterDockerfileGrammar
import TreeSitterMakeGrammar
import TreeSitterSQLGrammar

/// A language Alloy highlights: its tree-sitter grammar and its highlight query
/// (docs/DESIGN.md, A3). The queries are the grammars' own, kept in `Queries/` so they load
/// the same way in a package build and in Side's app bundle; TypeScript's and C++'s are layered
/// on JavaScript's and C's, as their authors intend.
public final class SyntaxLanguage: @unchecked Sendable {
    public let name: String
    public let language: Language
    public let highlights: Query
    /// Patterns rooted at big containers, rewritten to run from their children.
    let containerPatterns: ContainerPatterns?
    /// Top-level patterns found by Alloy's own split, and tree-sitter's count (tests).
    let splitPatternCount: Int

    init(name: String, language: OpaquePointer, queryFile: String) throws {
        self.name = name
        self.language = Language(language)
        guard let url = Bundle.module.url(forResource: queryFile, withExtension: "scm", subdirectory: "Queries")
            ?? Bundle.module.url(forResource: queryFile, withExtension: "scm") else {
            throw SyntaxError.missingQuery(queryFile)
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        highlights = try Query(language: self.language, data: Data(source.utf8))
        splitPatternCount = ContainerPatterns.topLevelPatterns(source).count
        containerPatterns = ContainerPatterns(language: self.language, source: source, patternCount: highlights.patternCount)
    }

    public enum SyntaxError: Error { case missingQuery(String) }

    /// The language for a file extension, or nil for plain text. Built once per language.
    public static func forExtension(_ ext: String) -> SyntaxLanguage? {
        guard let key = extensions[ext.lowercased()] else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let spec = specs[key], let language = try? SyntaxLanguage(name: key, language: spec.language(), queryFile: spec.query) else { return nil }
        cache[key] = language
        return language
    }

    /// The language for an extension if it's already built, without building it (building takes
    /// ~100 ms for the larger grammars, so a caller on the main thread builds it elsewhere).
    public static func loaded(forExtension ext: String) -> SyntaxLanguage? {
        guard let key = extensions[ext.lowercased()] else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    /// Whether Alloy highlights this extension at all.
    public static func supports(_ ext: String) -> Bool { extensions[ext.lowercased()] != nil }

    /// The extensions Alloy highlights.
    static let extensions: [String: String] = [
        "swift": "swift",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "tsx",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "py": "python",
        "rs": "rust",
        "go": "go",
        "lua": "lua",
        "rb": "ruby",
        "c": "c", "h": "c",
        "cpp": "cpp", "hpp": "cpp", "cc": "cpp", "cxx": "cpp", "hh": "cpp",
        "json": "json",
        "md": "markdown", "markdown": "markdown",
        "yaml": "yaml", "yml": "yaml",
        "toml": "toml",
        "html": "html", "htm": "html", "xhtml": "html",
        "css": "css",
        "scss": "scss",
        "sh": "bash", "bash": "bash", "zsh": "bash", "command": "bash",
        "java": "java",
        "php": "php",
        "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "mk": "make", "make": "make",
        "sql": "sql",
    ]

    /// Files known by their whole name (they have no extension to go by), as the extension
    /// that stands for them.
    static let fileNames: [String: String] = [
        "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "makefile": "mk", "gnumakefile": "mk",
        ".bashrc": "bash", ".zshrc": "bash", ".bash_profile": "bash", ".profile": "bash", ".zprofile": "bash",
    ]

    /// The extension Alloy (and a language server) goes by for a file: its own, or one standing
    /// for its name (`Dockerfile`, `Makefile`, `Dockerfile.dev`).
    public static func languageExtension(forFileName name: String) -> String {
        let lower = name.lowercased()
        if let byName = fileNames[lower] { return byName }
        if lower.hasPrefix("dockerfile.") || lower.hasSuffix(".dockerfile") { return "dockerfile" }
        return (name as NSString).pathExtension.lowercased()
    }

    private struct Spec {
        let language: @Sendable () -> OpaquePointer
        let query: String
    }

    private static let specs: [String: Spec] = [
        "swift": Spec(language: { alloy_tree_sitter_swift() }, query: "swift"),
        "typescript": Spec(language: { tree_sitter_typescript() }, query: "typescript"),
        "tsx": Spec(language: { tree_sitter_tsx() }, query: "tsx"),
        "javascript": Spec(language: { tree_sitter_javascript() }, query: "javascript"),
        "python": Spec(language: { tree_sitter_python() }, query: "python"),
        "rust": Spec(language: { tree_sitter_rust() }, query: "rust"),
        "go": Spec(language: { tree_sitter_go() }, query: "go"),
        "lua": Spec(language: { tree_sitter_lua() }, query: "lua"),
        "ruby": Spec(language: { tree_sitter_ruby() }, query: "ruby"),
        "c": Spec(language: { tree_sitter_c() }, query: "c"),
        "cpp": Spec(language: { tree_sitter_cpp() }, query: "cpp"),
        "json": Spec(language: { tree_sitter_json() }, query: "json"),
        "markdown": Spec(language: { tree_sitter_markdown() }, query: "markdown"),
        "yaml": Spec(language: { alloy_tree_sitter_yaml() }, query: "yaml"),
        "toml": Spec(language: { alloy_tree_sitter_toml() }, query: "toml"),
        "html": Spec(language: { alloy_tree_sitter_html() }, query: "html"),
        "css": Spec(language: { alloy_tree_sitter_css() }, query: "css"),
        "scss": Spec(language: { alloy_tree_sitter_scss() }, query: "scss"),
        "bash": Spec(language: { alloy_tree_sitter_bash() }, query: "bash"),
        "java": Spec(language: { alloy_tree_sitter_java() }, query: "java"),
        "php": Spec(language: { alloy_tree_sitter_php() }, query: "php"),
        "dockerfile": Spec(language: { alloy_tree_sitter_dockerfile() }, query: "dockerfile"),
        "make": Spec(language: { alloy_tree_sitter_make() }, query: "make"),
        "sql": Spec(language: { alloy_tree_sitter_sql() }, query: "sql"),
    ]

    private nonisolated(unsafe) static var cache: [String: SyntaxLanguage] = [:]
    private static let lock = NSLock()
}
