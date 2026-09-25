import AlloyAppKit
import AlloyCore
import AlloyRender
import AlloySyntax
import AppKit
import CoreText

// A window with an Alloy editor, for looking at it and measuring it.
//   swift run -c release AlloyPlayground <file> [--scroll-test] [--dark] [--screenshot <png>]
// --scroll-test scrolls through the file on every display frame for five seconds and prints
// frames drawn, frames dropped and the slowest frame's CPU time, then quits.

@MainActor
final class Playground: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var editor: AlloyEditorView!
    var highlighter: SyntaxHighlighter?
    let arguments = CommandLine.arguments

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = arguments.dropFirst().first { !$0.hasPrefix("--") }
        let text = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "No file given.\n"
        // The system monospaced font, as Make uses (DS.Text.editor).
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
        editor = try! AlloyEditorView(buffer: TextBuffer(text), font: font)
        if arguments.contains("--dark") { editor.theme = .dark }
        if let path, let highlighter = SyntaxHighlighter(fileExtension: (path as NSString).pathExtension, text: editor.buffer.text,
                                                         theme: .side(dark: arguments.contains("--dark"))) {
            self.highlighter = highlighter
            editor.styles = { [unowned highlighter] line in highlighter.spans(forLine: line) }
            editor.onTextChange = { [unowned self, unowned highlighter] change in highlighter.apply(change.edits, newText: self.editor.buffer.text) }
            highlighter.onInvalidate = { [unowned self] in self.editor.setNeedsRender() }
        }
        if !arguments.contains("--no-selection") { editor.buffer.setSelections([Selection(anchor: 30, head: 120), Selection(caret: 200)]) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Alloy \u{00B7} " + (path.map { ($0 as NSString).lastPathComponent } ?? "empty")
        // As Make lays it out: the gutter beside the editor.
        let container = NSView()
        for view in [editor.gutter, editor as NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            editor.gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor), editor.gutter.widthAnchor.constraint(equalToConstant: AlloyGutterView.width),
            editor.gutter.topAnchor.constraint(equalTo: container.topAnchor), editor.gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: editor.gutter.trailingAnchor), editor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.topAnchor.constraint(equalTo: container.topAnchor), editor.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if arguments.contains("--dark") { editor.gutter.backgroundColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1); window.appearance = NSAppearance(named: .darkAqua) }
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor.textView)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainMenu = Self.menu()
        if arguments.contains("--scroll-test") { scrollTest() }
        if let index = arguments.firstIndex(of: "--screenshot"), index + 1 < arguments.count {
            let out = arguments[index + 1]
            let delay = Double(arguments.firstIndex(of: "--delay").map { arguments[$0 + 1] } ?? "1.5") ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-l", "\(self.window.windowNumber)", out]
                try? task.run()
                task.waitUntilExit()
                NSApp.terminate(nil)
            }
        }
    }

    /// Enough of a menu bar for the standard shortcuts (copy, paste, undo, find) to reach the editor.
    static func menu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let find = edit.addItem(withTitle: "Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        editItem.submenu = edit
        main.addItem(appItem); main.addItem(editItem)
        return main
    }

    func scrollTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.editor.resetFrameCounters()
            let start = CACurrentMediaTime()
            let speed: CGFloat = 3_000  // points per second: fast flick scrolling
            self.scrollStart = start
            self.scrollSpeed = speed
            // Scroll from the editor's own frame callback, so each frame scrolls then draws.
            self.editor.onFrame = { [weak self] link in self?.step(link) }
        }
    }

    var scrollStart: CFTimeInterval = 0
    var scrollSpeed: CGFloat = 0
    var scrollLink: CADisplayLink?

    func step(_ link: CADisplayLink) {
        let elapsed = link.targetTimestamp - scrollStart
        editor.scrollY = CGFloat(elapsed) * scrollSpeed
        if elapsed > 5 {
            editor.onFrame = nil
            let counts = editor.presentedFrameCounts()
            print("presented \(counts.presented) frames, \(counts.missed) missed a vsync")
            let rate = 1 / max(0.001, link.targetTimestamp - link.timestamp)
            print(String(format: "display %.0f Hz; %d frames drawn, %d dropped; slowest frame %.2f ms CPU; last frame %d quads, %d lines, %d glyphs in atlas",
                         rate, editor.framesDrawn, editor.framesDropped, editor.worstFrameMilliseconds,
                         editor.lastFrameStats.quads, editor.lastFrameStats.visibleLines, editor.lastFrameStats.atlasGlyphs))
            let sorted = editor.frameMilliseconds.sorted()
            if !sorted.isEmpty {
                print(String(format: "CPU per frame: median %.2f ms, p99 %.2f ms", sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 99 / 100)]))
            }
            func stats(_ values: [Double]) -> String {
                let v = values.sorted(); guard !v.isEmpty else { return "none" }
                return String(format: "median %.2f, p99 %.2f, max %.2f ms", v[v.count / 2], v[min(v.count - 1, v.count * 99 / 100)], v.last!)
            }
            print("whole frame:", stats(editor.tickMilliseconds), "| waiting for a drawable:", stats(editor.drawableWaitMilliseconds))
            print("drops at (s):", editor.dropTimes.map { String(format: "%.2f", $0) }.joined(separator: " "))
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Playground()
app.delegate = delegate
app.run()
