import AlloyCore
import AlloyRender
import AppKit
import CoreText
import Metal
import QuartzCore

/// The editor Make embeds (docs/DESIGN.md): a `TextBuffer`, drawn by `TextRenderer` on the
/// display link, edited through `AlloyTextView` (the first responder).
///
/// Scrolling is AppKit's own: an `NSScrollView` over a document view as tall as the text, so
/// momentum, rubber-banding, scroll bars and accessibility of the scroll position all behave as
/// everywhere else on the Mac. The Metal layer floats over the visible area and draws whatever
/// the clip view shows.
@MainActor
public final class AlloyEditorView: NSView {
    public let scrollView = NSScrollView()
    public private(set) var buffer: TextBuffer
    public private(set) var documentLayout: DocumentLayout
    public var theme: RenderTheme = .light { didSet { setNeedsRender() } }
    public var styles: ((Int) -> [StyleSpan])? { didSet { setNeedsRender() } }
    /// Wrap to the view's width (Make's default), or not.
    public var wrapsLines = true { didSet { updateWrapWidth() } }
    public weak var delegate: AlloyEditorDelegate?
    /// Marks to draw (diagnostics, a matched bracket).
    public var decorations: [Decoration] = [] { didSet { setNeedsRender() } }
    /// The view that takes focus, reports its geometry in document points, and hosts overlays
    /// that scroll with the text.
    public var textView: AlloyTextView { documentView }
    /// Line numbers and marks; the owner places it beside the editor.
    public let gutter = AlloyGutterView()
    /// False: the text can be read and selected but not changed.
    public var isEditable = true
    /// After an undo (false) or redo (true) through the Edit menu or ⌘Z.
    public var onUndoRedo: ((Bool) -> Void)?
    /// What VoiceOver calls the editor ("Editor", or the file's name).
    public var accessibilityName: String? = nil

    private let documentView = AlloyTextView()
    private var isFocused = false
    private var caretOn = true
    private var blinkTimer: Timer?
    private let canvas = MetalCanvas()
    private let renderer: TextRenderer
    private var displayLink: CADisplayLink?
    private var needsRender = true
    private var needsRenderWasSet = false

    /// Scrolling health, measured on the display link: frames it drew, and frames where the
    /// gap since the last one was more than 1.5 display intervals.
    public private(set) var framesDrawn = 0
    public private(set) var framesDropped = 0
    public private(set) var worstFrameMilliseconds = 0.0
    private var lastFrameTimestamp: CFTimeInterval?

    public init(buffer: TextBuffer, font: CTFont) throws {
        self.buffer = buffer
        documentLayout = DocumentLayout(text: buffer.text, font: font)
        renderer = try TextRenderer()
        super.init(frame: .zero)
        documentView.editor = self
        gutter.editor = self
        canvas.metalLayer.device = renderer.device
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Beneath the clip view (which, like the document view, draws nothing), covering it
        // (see `drawingRect`): text flows under chrome that floats over the editor, insets never
        // shift it, and views the owner adds to the text view (proposal cards) draw on top of it
        // and scroll with it.
        scrollView.addSubview(canvas, positioned: .below, relativeTo: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        buffer.onChange = { [weak self] change in self?.textChanged(change) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows another buffer (a tab switch).
    public func setBuffer(_ buffer: TextBuffer) {
        self.buffer.onChange = nil
        self.buffer = buffer
        buffer.onChange = { [weak self] change in self?.textChanged(change) }
        documentLayout.reset(buffer.text)
        updateDocumentHeight()
        setNeedsRender()
    }

    /// Every change to the buffer, as it happens (syntax highlighting follows these).
    public var onTextChange: ((TextChange) -> Void)?

    private func textChanged(_ change: TextChange) {
        onTextChange?(change)
        documentLayout.update(buffer.text, edits: change.edits)
        updateDocumentHeight()
        restartBlink()
        setNeedsRender()
        gutter.needsDisplay = true
        documentView.postAccessibilityChange(value: true)
        // A replacement is the owner's own doing, not an edit to report back to it.
        guard change.reason != .replace else { return }
        delegate?.editorTextDidChange(self)
        delegate?.editorSelectionDidChange(self)
    }

    /// After undo, redo, or a composition step: the text view has already changed the buffer.
    func textInputChanged() {
        restartBlink()
        setNeedsRender()
    }

    func selectionChanged() {
        restartBlink()
        setNeedsRender()
        documentView.postAccessibilityChange(value: false)
        delegate?.editorSelectionDidChange(self)
    }

    /// Keeps the first caret on screen after a move or an edit.
    func revealCarets() {
        guard let head = buffer.selections.last?.head else { return }
        let rect = documentLayout.caretRect(at: head).insetBy(dx: -4, dy: 0)
        if !documentView.visibleRect.contains(rect) { documentView.scrollToVisible(rect) }
    }

    func focusChanged(_ focused: Bool) {
        isFocused = focused
        restartBlink()
        setNeedsRender()
    }

    /// The caret shows solid while typing and blinks when idle, and only in the focused editor.
    /// Blinking follows the same defaults NSTextView reads (`NSTextInsertionPointBlinkPeriodOn`
    /// and `...Off`, in milliseconds), so a person who has turned blinking off, or slowed it,
    /// gets that here too.
    private func restartBlink() {
        caretOn = true
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard isFocused, let (on, off) = Self.blinkPeriods else { return }
        scheduleBlink(after: on, then: off)
    }

    private func scheduleBlink(after interval: TimeInterval, then next: TimeInterval) {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.caretOn.toggle()
                self.setNeedsRender()
                self.scheduleBlink(after: next, then: interval)
            }
        }
    }

    /// Seconds on and off, or nil for a caret that doesn't blink.
    static var blinkPeriods: (on: TimeInterval, off: TimeInterval)? {
        let defaults = UserDefaults.standard
        let on = defaults.object(forKey: "NSTextInsertionPointBlinkPeriodOn") as? Double ?? 530
        let off = defaults.object(forKey: "NSTextInsertionPointBlinkPeriodOff") as? Double ?? 530
        // A zero off period, or an on period of a minute or more, is how blinking is turned off.
        guard off > 0, on > 0, on < 60_000 else { return nil }
        return (on / 1000, off / 1000)
    }

    /// The document point range a UTF-16 range covers (its first row), for popovers and panels.
    public func rect(forCharacterRange range: Range<Int>) -> CGRect {
        let start = documentLayout.caretRect(at: range.lowerBound)
        let end = documentLayout.caretRect(at: range.upperBound)
        return CGRect(x: start.minX, y: start.minY, width: max(1, end.minY == start.minY ? end.minX - start.minX : 1), height: start.height)
    }

    /// Asks for a frame. Mid-motion the display link draws it on the next vsync. From idle it's
    /// drawn as soon as this turn of the run loop ends: an idle ProMotion display drops to its
    /// lowest refresh rate and the display link with it, so waiting for the next tick put the first
    /// frame after a pause (a file opened, the first key) 30–100 ms late.
    public func setNeedsRender() {
        needsRender = true
        wake()
        guard !immediateRenderScheduled, CACurrentMediaTime() - lastRenderTime > displayInterval * 1.5 else { return }
        immediateRenderScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.immediateRenderScheduled = false
                guard self.needsRender, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
                // The frame is drawn before AppKit's own layout pass would run: bring sizes current.
                self.window?.layoutIfNeeded()
                self.render()
            }
        }
    }
    private var immediateRenderScheduled = false
    /// Display-link ticks in a row with nothing to draw. Past a few, the link pauses: an idle
    /// editor shouldn't wake the app 120 times a second.
    private var idleTicks = 0

    private func wake() {
        idleTicks = 0
        if displayLink?.isPaused == true { displayLink?.isPaused = false }
    }
    private var lastRenderTime: CFTimeInterval = 0

    public override func layout() {
        super.layout()
        updateWrapWidth()
        updateDocumentHeight()
        setNeedsRender()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        canvas.metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsRender()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        canvas.metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        setNeedsRender()
    }

    private func updateWrapWidth() {
        let width = scrollView.contentView.bounds.width - documentLayout.insets.width * 2
        documentLayout.setWrapWidth(wrapsLines && width > 0 ? width : nil)
    }

    private func updateDocumentHeight() {
        let insets = scrollView.contentView.contentInsets
        let height = max(documentLayout.contentHeight, scrollView.contentView.bounds.height - insets.top - insets.bottom)
        let width = scrollView.contentView.bounds.width
        if documentView.frame.size != CGSize(width: width, height: height) {
            documentView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        }
    }

    @objc private func scrolled() {
        setNeedsRender()
        gutter.needsDisplay = true
    }

    /// Selects, as the user would (the delegate hears about it); doesn't scroll.
    public func setSelections(_ selections: [Selection]) {
        buffer.setSelections(selections)
        selectionChanged()
    }

    /// The buffer's text was replaced outside the edit path (`TextBuffer.reset`): lay it out again.
    public func reloadText() {
        documentLayout.reset(buffer.text)
        updateDocumentHeight()
        gutter.needsDisplay = true
        setNeedsRender()
    }

    /// Light or dark changed: colors that depend on it need resolving again.
    public var onEffectiveAppearanceChange: (() -> Void)?

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
        gutter.needsDisplay = true
        setNeedsRender()
    }

    /// Lays the text out in another font (the editor text size changed).
    public func setFont(_ font: CTFont) {
        let insets = documentLayout.insets
        documentLayout = DocumentLayout(text: buffer.text, font: font)
        documentLayout.insets = insets
        updateWrapWidth()
        updateDocumentHeight()
        gutter.needsDisplay = true
        setNeedsRender()
    }

    /// Scrolls so a UTF-16 offset is on screen.
    public func scrollToVisible(offset: Int) {
        let rect = documentLayout.caretRect(at: offset).insetBy(dx: 0, dy: -documentLayout.lineHeight)
        documentView.scrollToVisible(rect)
        setNeedsRender()
    }

    /// The part of the document on screen and not under an inset (the Find bar, floating
    /// chrome), in document points: what's drawn. The document view sits at the clip view's
    /// origin, so clip coordinates are document coordinates.
    /// What's drawn: the whole clip view in document points, its content insets included, so the
    /// text scrolls on under chrome floating over the editor (Make's tab strip and bottom bar)
    /// instead of stopping at its edge. Above the document's top this starts at a negative y.
    var drawingRect: CGRect { scrollView.contentView.bounds }

    var viewport: CGRect {
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let bounds = clip.bounds
        return CGRect(x: bounds.minX, y: bounds.minY + insets.top, width: bounds.width,
                      height: max(0, bounds.height - insets.top - insets.bottom))
    }

    /// The document y at the top of the viewport.
    public var scrollY: CGFloat {
        get { viewport.minY }
        set {
            let insets = scrollView.contentView.contentInsets
            let visible = scrollView.contentView.bounds.height - insets.top - insets.bottom
            let y = max(0, min(newValue, documentView.frame.height - visible))
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: y - insets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// When each dropped frame happened (seconds since the counters were reset), and every
    /// frame's CPU time, for finding out why.
    public private(set) var dropTimes: [Double] = []
    public private(set) var frameMilliseconds: [Double] = []
    private var countersStart = CACurrentMediaTime()

    /// Runs at the start of every display frame, before drawing (animations, tests).
    public var onFrame: ((CADisplayLink) -> Void)? { didSet { if onFrame != nil { wake() } } }

    /// When frames actually reached the screen (Metal's presented times): the honest measure of
    /// dropped frames, since a frame that's drawn can still miss its vsync.
    private final class PresentedTimes: @unchecked Sendable {
        let lock = NSLock()
        var times: [CFTimeInterval] = []
        func append(_ time: CFTimeInterval) { lock.lock(); times.append(time); lock.unlock() }
        func take() -> [CFTimeInterval] { lock.lock(); defer { lock.unlock() }; let t = times; times = []; return t }
    }
    private let presented = PresentedTimes()
    public private(set) var displayInterval: CFTimeInterval = 1.0 / 60

    /// Frames that missed their vsync since the counters were reset, from presented times, and
    /// how many were presented.
    public func presentedFrameCounts() -> (presented: Int, missed: Int) {
        let times = presented.take().filter { $0 > 0 }.sorted()
        var missed = 0
        for (a, b) in zip(times, times.dropFirst()) where b - a > displayInterval * 1.5 {
            missed += Int(((b - a) / displayInterval).rounded()) - 1
        }
        return (times.count, missed)
    }

    /// Per frame: the whole tick, and how long `nextDrawable` waited.
    public private(set) var tickMilliseconds: [Double] = []
    public private(set) var drawableWaitMilliseconds: [Double] = []

    @objc private func tick(_ link: CADisplayLink) {
        let tickStart = CACurrentMediaTime()
        defer { if needsRenderWasSet { tickMilliseconds.append((CACurrentMediaTime() - tickStart) * 1000) } }
        needsRenderWasSet = false
        displayInterval = link.targetTimestamp - link.timestamp
        onFrame?(link)
        if let last = lastFrameTimestamp, needsRender {
            let interval = link.targetTimestamp - link.timestamp
            let gap = link.timestamp - last
            if interval > 0, gap > interval * 1.5 {
                framesDropped += 1
                dropTimes.append(link.timestamp - countersStart)
            }
        }
        guard needsRender else {
            lastFrameTimestamp = nil
            idleTicks += 1
            if idleTicks > 30, onFrame == nil { link.isPaused = true }
            return
        }
        idleTicks = 0
        lastFrameTimestamp = link.timestamp
        render()
    }

    /// Draws now.
    public func render() {
        needsRender = false
        let visible = drawingRect
        let size = visible.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = canvas.metalLayer.contentsScale
        // Only when they change: setting a Metal layer's drawable size, even to the same
        // value, can make Core Animation reallocate its drawables and stall the next frame.
        let clip = scrollView.contentView
        let frameRect = clip.convert(visible, to: scrollView)
        if canvas.frame != frameRect { canvas.frame = frameRect }
        let drawableSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if canvas.metalLayer.drawableSize != drawableSize { canvas.metalLayer.drawableSize = drawableSize }
        needsRenderWasSet = true
        let waitStart = CACurrentMediaTime()
        guard let drawable = canvas.metalLayer.nextDrawable() else { needsRender = true; return }
        drawableWaitMilliseconds.append((CACurrentMediaTime() - waitStart) * 1000)
        var frame = RenderFrame(scrollY: visible.minY, size: size, scale: scale, selections: buffer.selections,
                                caretVisible: isFocused && caretOn, theme: theme, styles: styles)
        frame.decorations = decorations
        if let marked = documentView.composingRange {
            frame.decorations.append(Decoration(range: marked, color: theme.text, style: .underline))
        }
        let presented = self.presented
        drawable.addPresentedHandler { presented.append($0.presentedTime) }
        renderer.draw(frame, layout: documentLayout, into: drawable.texture, drawable: drawable)
        framesDrawn += 1
        lastRenderTime = CACurrentMediaTime()
        worstFrameMilliseconds = max(worstFrameMilliseconds, renderer.lastStats.cpuMilliseconds)
        frameMilliseconds.append(renderer.lastStats.cpuMilliseconds)
        // The document height can change while drawing (wrapped lines got measured).
        updateDocumentHeight()
    }

    public var lastFrameStats: FrameStats { renderer.lastStats }
    /// Where the drawing surface sits in the scroll view (tests).
    public var canvasFrame: CGRect { canvas.frame }

    public func resetFrameCounters() {
        framesDrawn = 0
        framesDropped = 0
        worstFrameMilliseconds = 0
        lastFrameTimestamp = nil
        dropTimes = []
        frameMilliseconds = []
        _ = presented.take()
        tickMilliseconds = []
        drawableWaitMilliseconds = []
        countersStart = CACurrentMediaTime()
    }
}

/// A view backed by a CAMetalLayer that the editor draws into.
private final class MetalCanvas: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.displaySyncEnabled = true
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var isFlipped: Bool { true }
    // Clicks and scrolls go to the scroll view beneath, until step 3 gives the editor input.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
