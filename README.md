# Alloy

Alloy is a GPU text editing engine for macOS, in Swift. It's the editor behind the Make stage of
[Side](https://github.com/gazishahi/side-releases): a document model built for big files and for
agents that edit alongside you, drawn with Metal.

**Status: 0.3.0, pre-release.** It runs Side's editor. The API may still change before 1.0.

## What's in it

| Library | What it is | Depends on |
|---|---|---|
| **AlloyCore** | The document: `Rope` (persistent balanced tree, O(log n) lines and offsets, free copies), `TextBuffer` (multiple selections, grouped undo, change events that replay exactly), `RopeString` (an `NSString` view of a rope, no copy), `Folding` (foldable regions from indentation, one pass) | Foundation |
| **AlloyRender** | Drawing: `DocumentLayout` (CoreText shaping per line, soft wrap), `GlyphAtlas`, `TextRenderer` (Metal, instanced quads, selections, carets, decorations) | AlloyCore, CoreText, Metal |
| **AlloyAppKit** | The view: `AlloyEditorView` and `AlloyTextView` (`NSTextInputClient`, so IME, dictation and marked text work; key bindings; mouse; pasteboard; `NSTextFinder`; VoiceOver as a text area), `AlloyGutterView` (numbers, marks, fold arrows), `AlloyMinimapView` | AlloyCore, AlloyRender, AppKit |
| **AlloySyntax** | `SyntaxHighlighter`: tree-sitter, incremental, parsed in the background, colored a line at a time. Swift, TypeScript, TSX, JavaScript, Python, Rust, Go, Lua, Ruby, C, C++, JSON, Markdown | AlloyCore, AlloyRender, [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) |

Editing: multiple cursors (⌥-click, ⌥⌘↑/↓), column selection (⌥-drag), code folding (the gutter,
or `foldAtCaret`, `unfoldAtCaret`, `foldAll`, `unfoldAll`; a folded region reads as one line, `header { … }`, and
clicking the `… }` opens it; a selection that lands inside opens it too; each document keeps
its folds when the editor switches between them), snippets (`insert(_:replacing:)` with a `Snippet`
parsed from LSP/VS Code syntax: Tab and ⇧Tab move between stops, mirrors are typed once),
pointer hooks for hover cards and ⌘-click (`onPointerMove`, `onPointerExit`, `onCommandClick`),
and a minimap (`editor.minimap`, placed by the owner).

Offsets are UTF-16 throughout, the unit AppKit and LSP use; UTF-8 conversions are there for
tree-sitter.

## Using it

```swift
.package(url: "https://github.com/gazishahi/alloy", from: "0.3.0")
```

```swift
import AlloyAppKit
import AlloyCore
import AlloySyntax

let editor = try AlloyEditorView(buffer: TextBuffer(source), font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont)
if let syntax = SyntaxHighlighter(fileExtension: "swift", text: editor.buffer.text, theme: .side(dark: false)) {
    editor.styles = { line in syntax.spans(forLine: line) }
    editor.onTextChange = { change in syntax.apply(change.edits, newText: editor.buffer.text) }
    syntax.onInvalidate = { editor.setNeedsRender() }
}
window.contentView = editor
```

`Sources/AlloyPlayground` is a complete small app: `swift run -c release AlloyPlayground <file>`.

## Performance

Measured in Side on a MacBook Pro (Apple silicon, 120 Hz), optimized builds:

| Measure | Budget | Measured |
|---|---|---|
| Keystroke to frame, main thread, p99 | ≤ 8 ms | ~3.5 ms |
| Open to first paint, 100,000-line Swift file | ≤ 50 ms | ~20–25 ms |
| Open to first paint, 20 MB log | ≤ 150 ms | ~65–85 ms |
| Re-color an edited line, p99 | ≤ 2 ms | 0.2 ms |
| Memory for a 20 MB file | ≤ 3× the file | ~1.2–1.6× |
| Scrolling at 120 Hz | no dropped frames | as few as a control that draws nothing |
| Foldable regions, 100,000-line file (off the main thread) | ≤ 500 ms | ~30 ms |
| Fold everything, 100,000-line file | ≤ 50 ms | ~8 ms |
| The minimap, a frame while scrolling, p99 | ≤ 4 ms | ~2.5 ms |

How they're met, and the decisions behind the design, are in [docs/DESIGN.md](docs/DESIGN.md).

## Development

```sh
swift test
swift run -c release AlloyBenchmarks
swift run -c release AlloyPlayground <file> --scroll-test
```

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party components
(tree-sitter grammars and queries, including a vendored copy of tree-sitter-swift's generated
parser) are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
