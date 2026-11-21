import AlloyRender
import CoreText
import Foundation
import Metal
import QuartzCore

/// The faces a terminal draws with, made from one monospaced font: bold, italic and bold italic
/// come from CoreText's traits, falling back to the regular face where the family has none. A
/// variable font set at a weight of its own (SF Mono at 450) has no bold face by traits: its
/// bold is 300 heavier on its weight axis, as CSS's `bolder` steps.
public struct TerminalFont: @unchecked Sendable {
    // @unchecked: CTFont is immutable and thread-safe.
    public let regular: CTFont
    public let bold: CTFont
    public let italic: CTFont
    public let boldItalic: CTFont
    /// Whether runs of text are shaped together, for a font's ligatures and contextual
    /// alternates (Fira Code's `=>`, JetBrains Mono's `!=`). Off: a glyph a cell, as before.
    public var ligatures = true

    /// Whether each face (regular, bold, italic, bold italic) can draw a run of plain text other
    /// than glyph by glyph: ligatures or contextual alternates. A face that can't (Side's
    /// default, MesloLGS NF) draws the same either way, so its text skips CoreText's shaping,
    /// most of a frame's CPU (results/2026-11-13-tier1).
    let substitutes: [Bool]

    /// Whether `style`'s face has ligatures or contextual alternates to apply.
    func shapesRuns(_ style: TerminalCell.Style) -> Bool {
        ligatures && substitutes[(style.contains(.bold) ? 1 : 0) + (style.contains(.italic) ? 2 : 0)]
    }

    /// A face's substitutions that change plain text, as the shaper applies them by default:
    /// OpenType's (GSUB) standard and contextual ligatures and contextual alternates, or Apple's
    /// (morx) ligatures as CoreText lists them (Menlo, Monaco).
    static func substitutesInText(_ font: CTFont) -> Bool {
        let wanted: Set<String> = ["liga", "clig", "rlig", "calt"]
        if let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableGSUB), []) as Data?, table.count >= 10 {
            func u16(_ offset: Int) -> Int { offset + 1 < table.count ? Int(table[offset]) << 8 | Int(table[offset + 1]) : 0 }
            let list = u16(6)   // the FeatureList's offset, after the version and the ScriptList's
            if list > 0 {
                for i in 0..<u16(list) {
                    let record = list + 2 + i * 6
                    guard record + 4 <= table.count else { break }
                    if let tag = String(bytes: table[record..<record + 4], encoding: .ascii), wanted.contains(tag) { return true }
                }
            }
        }
        let features = (CTFontCopyFeatures(font) as? [[String: Any]]) ?? []
        return features.contains { ($0[kCTFontFeatureTypeIdentifierKey as String] as? Int) == 1 } // kLigaturesType
    }

    public init(name: String, size: CGFloat) {
        self.init(CTFontCreateWithName(name as CFString, size, nil))
    }

    public init(_ font: CTFont) {
        let size = CTFontGetSize(font)
        regular = font
        func styled(_ traits: CTFontSymbolicTraits) -> CTFont? {
            guard let made = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits),
                  CTFontGetSymbolicTraits(made).contains(traits) else { return nil }
            return made
        }
        let realBold = styled(.traitBold), realItalic = styled(.traitItalic)
        italic = realItalic ?? font
        if let weight = Self.weight(font), let axis = Self.weightAxis(font), (realBold.map { Self.weight($0) ?? .infinity } ?? -.infinity) <= weight {
            let heavier = min(axis.upperBound, weight + 300)
            bold = Self.font(font, weight: heavier)
            boldItalic = Self.font(italic, weight: heavier)
        } else {
            bold = realBold ?? font
            boldItalic = styled([.traitBold, .traitItalic]) ?? realItalic ?? realBold ?? font
        }
        substitutes = [regular, bold, italic, boldItalic].map(Self.substitutesInText)
    }

    /// OpenType's weight axis, 'wght'.
    static let weightTag = 0x7767_6874
    /// A variable font's weight, where it's set on the weight axis.
    static func weight(_ font: CTFont) -> Double? {
        (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?[NSNumber(value: weightTag)]?.doubleValue
    }
    static func weightAxis(_ font: CTFont) -> ClosedRange<Double>? {
        let axes = (CTFontCopyVariationAxes(font) as? [[CFString: Any]]) ?? []
        guard let axis = axes.first(where: { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == weightTag }),
              let low = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue,
              let high = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue, low <= high else { return nil }
        return low...high
    }
    static func font(_ font: CTFont, weight: Double) -> CTFont {
        let descriptor = CTFontDescriptorCreateCopyWithVariation(CTFontCopyFontDescriptor(font), weightTag as CFNumber, CGFloat(weight))
        return CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(font), nil)
    }

    /// What a style's face has to draw synthetically (Ghostty's font-synthetic-style): what the
    /// face itself lacks of the style. A family with no bold is its regular stroked heavier; with
    /// no italic, slanted.
    func synthetic(_ style: TerminalCell.Style) -> SyntheticStyle {
        let face = self.face(style)
        let traits = CTFontGetSymbolicTraits(face)
        var synthetic: SyntheticStyle = []
        if style.contains(.bold), !traits.contains(.traitBold) { synthetic.insert(.bold) }
        if style.contains(.italic), !traits.contains(.traitItalic) { synthetic.insert(.italic) }
        return synthetic
    }

    /// One cell, in points: the advance of "M" by the line's height (ascent, descent, leading).
    public var cellSize: CGSize {
        var glyph: CGGlyph = 0
        var m = UniChar(UInt8(ascii: "M"))
        CTFontGetGlyphsForCharacters(regular, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        return CGSize(width: advance.width, height: ceil(CTFontGetAscent(regular) + CTFontGetDescent(regular) + CTFontGetLeading(regular)))
    }

    func face(_ style: TerminalCell.Style) -> CTFont {
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }
}

/// The colors the renderer adds of its own: the default background (its alpha is the view's
/// opacity) and the cursor's.
public struct TerminalTheme: Sendable, Equatable {
    /// RGBA, 0…1, not premultiplied.
    public var background: SIMD4<Float>
    /// 0xRRGGBB.
    public var cursor: UInt32
    /// RGBA, 0…1, not premultiplied: laid over selected cells.
    public var selection: SIMD4<Float>
    /// 0xRRGGBB: a search match's background and text, and the selected match's background, as
    /// Ghostty draws them (its search-background, search-foreground and
    /// search-selected-background defaults).
    public var searchMatch: UInt32
    public var searchText: UInt32
    public var searchSelected: UInt32

    public init(background: SIMD4<Float>, cursor: UInt32, selection: SIMD4<Float> = SIMD4(0.35, 0.55, 1, 0.4),
                searchMatch: UInt32 = 0xFFE082, searchText: UInt32 = 0x000000, searchSelected: UInt32 = 0xF2A57E) {
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.searchMatch = searchMatch
        self.searchText = searchText
        self.searchSelected = searchSelected
    }
}

/// Draws a `TerminalGrid` with Alloy's glyph atlas and quad shaders: backgrounds, decorations,
/// the cursor and glyphs as instanced quads in one draw call, a row's quads rebuilt only when that
/// row changed. Confined to one thread, the render thread (`AlloyTerminalView` keeps it on its
/// own): it owns a glyph atlas of its own, apart from the editors' on the main actor.
public final class TerminalRenderer {
    public let device: MTLDevice
    public let font: TerminalFont
    public var theme: TerminalTheme
    /// Frames drawn, for tests and measurements.
    public private(set) var frames = 0
    /// Text an input method is composing (marked text), drawn at the cursor over the grid,
    /// underlined, until it's committed or cancelled. Empty: none.
    public var preedit = ""
    /// Whether the terminal has the keyboard. Unfocused, the cursor is a hollow block, as
    /// Ghostty and Terminal draw it, and doesn't blink.
    public var focused = true
    /// The blink's phase: false hides a blinking cursor. The view's timer flips it.
    public var blinkOn = true
    /// The link under the pointer, underlined in its text's colors (⌘ held, as Ghostty shows it).
    public var highlightedLink: [TerminalSpan] = []
    /// A search's matches in the viewport, and the selected one: drawn in the theme's search
    /// colors, the selected match in its own.
    public var searchMatches: [TerminalSpan] = [] { didSet { rowsToRebuild.formUnion((oldValue + searchMatches).map(\.row)) } }
    public var selectedMatch: [TerminalSpan] = [] { didSet { rowsToRebuild.formUnion((oldValue + selectedMatch).map(\.row)) } }
    /// Rows whose highlights changed though their cells didn't.
    private var rowsToRebuild = Set<Int>()

    /// For each column of a row: 0, or 1 in a match, 2 in the selected match.
    private func searchKinds(row y: Int, columns: Int) -> [UInt8]? {
        guard !searchMatches.isEmpty || !selectedMatch.isEmpty else { return nil }
        var kinds: [UInt8]?
        for (spans, kind) in [(searchMatches, UInt8(1)), (selectedMatch, UInt8(2))] {
            for span in spans where span.row == y {
                if kinds == nil { kinds = Array(repeating: 0, count: columns) }
                for x in span.columns where x >= 0 && x < columns { kinds![x] = max(kinds![x], kind) }
            }
        }
        return kinds
    }

    private let gpu: QuadPipeline
    private let atlas: GlyphAtlas
    private let cell: CGSize
    private let ascent: CGFloat
    /// The font's own underline: how far below the baseline, and how thick, in points.
    private let underlineOffset: CGFloat
    private let underlineThickness: CGFloat

    /// One quad, laid out as AlloyRender's shaders read it (TextRenderer.shaders): a rectangle in
    /// pixels, its atlas region, a color and a kind (0 solid, 1 tinted glyph, 2 color glyph).
    struct Quad {
        var rect: SIMD4<Float>
        var uv: SIMD4<Float>
        var color: SIMD4<Float>
        var kind: Float
        var padding: SIMD3<Float> = .zero
    }

    private var backgroundQuads: [[Quad]] = []
    private var glyphQuads: [[Quad]] = []
    /// Blinking cells' glyphs, kept apart: drawn or left out by the blink's phase each frame,
    /// without rebuilding their rows.
    private var blinkingGlyphQuads: [[Quad]] = []
    /// Whether anything on screen blinks: the view's blink timer runs for it.
    public var hasBlinkingText: Bool { blinkingGlyphQuads.contains { !$0.isEmpty } }
    private var builtScale: CGFloat = 0
    private var builtRows = 0
    private var atlasGeneration = 0

    private struct GlyphKey: Hashable { let scalar: UInt32; let cluster: String?; let style: TerminalCell.Style }
    private struct Placed { let entry: AtlasEntry; let dx: CGFloat }
    private var glyphCache: [GlyphKey: [Placed]] = [:]

    /// Where the assembled quads' text begins, after the backgrounds: images under text go
    /// between.
    private var textStart = 0

    // MARK: Images (kitty graphics)

    private struct ImageDraw {
        let layer: TerminalImage.Layer
        let texture: MTLTexture
        let quad: Quad
    }
    /// Each image's texture, kept while the image is on screen.
    private var imageTextures: [TerminalImage.Key: MTLTexture] = [:]
    /// Images are scaled to their place, so they're sampled smoothly, unlike glyphs.
    private lazy var imageSampler: MTLSamplerState? = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        return device.makeSamplerState(descriptor: descriptor)
    }()
    /// How many image textures are held, for tests.
    public var imageTextureCount: Int { imageTextures.count }

    /// Takes the grid's new pixels, lets go of images no longer on screen, and places the ones
    /// that are: in pixels, sorted by layer and z, and clipped to the grid by the GPU's scissor.
    private func imageDraws(_ grid: TerminalGrid, scale: CGFloat, size: (width: Int, height: Int)) -> [ImageDraw] {
        for pixels in grid.newImagePixels {
            if let texture = makeTexture(pixels) { imageTextures[pixels.key] = texture }
        }
        grid.newImagePixels.removeAll()
        if !imageTextures.isEmpty {
            let onScreen = Set(grid.images.map(\.key))
            imageTextures = imageTextures.filter { onScreen.contains($0.key) }
        }
        guard !grid.images.isEmpty else { return [] }
        let m = metrics(scale)
        var draws: [ImageDraw] = []
        for image in grid.images.sorted(by: { ($0.layer, $0.z) < ($1.layer, $1.z) }) {
            guard let texture = imageTextures[image.key], image.width > 0, image.height > 0 else { continue }
            let w = Float(texture.width), h = Float(texture.height)
            let source = SIMD4(Float(image.sourceX) / w, Float(image.sourceY) / h,
                               Float(image.sourceWidth > 0 ? image.sourceWidth : Double(w)) / w,
                               Float(image.sourceHeight > 0 ? image.sourceHeight : Double(h)) / h)
            let rect = SIMD4(Float(image.x) * m.width, Float(image.y) * m.height, Float(image.width) * m.width, Float(image.height) * m.height)
            draws.append(ImageDraw(layer: image.layer, texture: texture, quad: Quad(rect: rect, uv: source, color: .zero, kind: 2)))
        }
        imageClip = MTLScissorRect(x: 0, y: 0, width: min(size.width, Int((Float(grid.columns) * m.width).rounded(.up))),
                                   height: min(size.height, Int(Float(grid.rows) * m.height)))
        imageTarget = size
        return draws
    }
    private var imageClip = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
    private var imageTarget = (width: 0, height: 0)

    private func drawImages(_ draws: [ImageDraw], layer: TerminalImage.Layer, encoder: MTLRenderCommandEncoder) {
        let these = draws.filter { $0.layer == layer }
        guard !these.isEmpty, imageClip.width > 0, imageClip.height > 0, let sampler = imageSampler else { return }
        var one: Float = 1
        encoder.setRenderPipelineState(gpu.pipeline)
        encoder.setScissorRect(imageClip)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&one, length: MemoryLayout<Float>.size, index: 0)
        for draw in these {
            var quad = draw.quad
            encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
            encoder.setFragmentTexture(draw.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: imageTarget.width, height: imageTarget.height))
    }

    /// A texture for an image's pixels: premultiplied, as the quads blend.
    private func makeTexture(_ pixels: TerminalImage.Pixels) -> MTLTexture? {
        let width = pixels.width, height = pixels.height
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, pixels.rgba.count >= width * height * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var premultiplied = pixels.rgba
        premultiplied.withUnsafeMutableBufferPointer { p in
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                let a = UInt16(p[i + 3])
                guard a < 255 else { continue }
                for c in 0..<3 { p[i + c] = UInt8((UInt16(p[i + c]) * a + 127) / 255) }
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: premultiplied, bytesPerRow: width * 4)
        return texture
    }

    private var ring: [MTLBuffer] = []
    private var ringIndex = 0
    private let framesInFlight = DispatchSemaphore(value: 3)

    public init(device: MTLDevice, font: TerminalFont, theme: TerminalTheme, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        self.font = font
        self.theme = theme
        gpu = try QuadPipeline.shared(device: device, pixelFormat: pixelFormat)
        atlas = GlyphAtlas(device: device)
        cell = font.cellSize
        ascent = CTFontGetAscent(font.regular)
        underlineOffset = -CTFontGetUnderlinePosition(font.regular)
        underlineThickness = CTFontGetUnderlineThickness(font.regular)
    }

    /// Encodes `grid` into `target`, presents `drawable` if given, and commits. Rows the grid
    /// marks dirty are rebuilt and marked clean.
    @discardableResult
    public func draw(_ grid: TerminalGrid, scale: CGFloat, into target: MTLTexture, drawable: CAMetalDrawable? = nil,
                     completion: (@Sendable (MTLCommandBuffer) -> Void)? = nil) -> MTLCommandBuffer? {
        let quads = assemble(grid, scale: scale, size: (Float(target.width), Float(target.height)))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = theme.background
        // Premultiplied, as the layer composites it and the quads blend.
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x * bg.w), green: Double(bg.y * bg.w), blue: Double(bg.z * bg.w), alpha: Double(bg.w))
        framesInFlight.wait()
        guard let buffer = gpu.queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            framesInFlight.signal()
            return nil
        }
        let inFlight = framesInFlight
        buffer.addCompletedHandler { _ in inFlight.signal() }
        let images = imageDraws(grid, scale: scale, size: (target.width, target.height))
        var viewport = SIMD2<Float>(Float(target.width), Float(target.height))
        encoder.setRenderPipelineState(gpu.pipeline)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        // Under the cells' backgrounds: over the window's (the clear), as Ghostty layers them.
        drawImages(images, layer: .belowBackground, encoder: encoder)
        if !quads.isEmpty {
            let length = quads.count * MemoryLayout<Quad>.stride
            if ring.count < 3 {
                ring.append(device.makeBuffer(length: max(length, 1 << 20), options: .storageModeShared)!)
                ringIndex = ring.count - 1
            } else {
                ringIndex = (ringIndex + 1) % ring.count
            }
            if ring[ringIndex].length < length { ring[ringIndex] = device.makeBuffer(length: length * 2, options: .storageModeShared)! }
            quads.withUnsafeBytes { ring[ringIndex].contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
            var atlasSize = Float(atlas.size)
            // Backgrounds, then the images under text, then the rest: two draws when there are
            // such images, one otherwise.
            let split = images.contains { $0.layer == .belowText } ? textStart : quads.count
            for range in [0..<split, split..<quads.count] where !range.isEmpty {
                encoder.setRenderPipelineState(gpu.pipeline)
                encoder.setVertexBuffer(ring[ringIndex], offset: 0, index: 0)
                encoder.setFragmentTexture(atlas.texture, index: 0)
                encoder.setFragmentSamplerState(gpu.sampler, index: 0)
                encoder.setFragmentBytes(&atlasSize, length: MemoryLayout<Float>.size, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: range.count, baseInstance: range.lowerBound)
                if range.lowerBound == 0 { drawImages(images, layer: .belowText, encoder: encoder) }
            }
        } else {
            drawImages(images, layer: .belowText, encoder: encoder)
        }
        drawImages(images, layer: .aboveText, encoder: encoder)
        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        if let completion { buffer.addCompletedHandler(completion) }
        buffer.commit()
        frames += 1
        return buffer
    }

    // MARK: - Building quads

    func assemble(_ grid: TerminalGrid, scale: CGFloat, size: (width: Float, height: Float) = (0, 0)) -> [Quad] {
        // A new scale or size invalidates every row; a restarted atlas, every cached glyph too.
        if scale != builtScale || grid.rows != builtRows || atlas.generation != atlasGeneration {
            if scale != builtScale || atlas.generation != atlasGeneration { glyphCache.removeAll(); runCache.removeAll(); rightToLeftCache.removeAll() }
            builtScale = scale
            builtRows = grid.rows
            atlasGeneration = atlas.generation
            backgroundQuads = Array(repeating: [], count: grid.rows)
            glyphQuads = Array(repeating: [], count: grid.rows)
            blinkingGlyphQuads = Array(repeating: [], count: grid.rows)
            for y in 0..<grid.rows { grid.dirty[y] = true }
        }
        for y in rowsToRebuild where y >= 0 && y < grid.rows { grid.dirty[y] = true }
        if rebuildAllRows {
            rebuildAllRows = false
            for y in 0..<grid.rows { grid.dirty[y] = true }
        }
        rowsToRebuild.removeAll()
        for y in 0..<grid.rows where grid.dirty[y] {
            rebuild(row: y, of: grid, scale: scale)
            grid.dirty[y] = false
        }
        // An atlas that filled while rebuilding dropped entries rows already hold.
        if atlas.generation != atlasGeneration {
            atlasGeneration = atlas.generation
            glyphCache.removeAll()
            runCache.removeAll()
            rightToLeftCache.removeAll()
            for y in 0..<grid.rows { rebuild(row: y, of: grid, scale: scale) }
        }
        var quads: [Quad] = []
        quads.reserveCapacity(grid.columns * grid.rows / 2 + 64)
        for row in backgroundQuads { quads += row }
        if paddingColor == .extend { quads += paddingQuads(grid, scale: scale, size: size) }
        textStart = quads.count
        for row in glyphQuads { quads += row }
        // Blinking text shows in the blink's on phase, and always while unfocused (no blink then).
        if blinkOn || !focused { for row in blinkingGlyphQuads { quads += row } }
        quads += linkQuads(grid, scale: scale)
        // The cursor over the text: a block covers its cell and redraws the character in the
        // background's color, as terminals draw it; a bar or underline just sits there.
        // A cursor outside the grid isn't drawn: the emulator can be bigger than the grid for a
        // frame (the view's placeholder grid before layout, or a resize the emulator hasn't had).
        let cursorInGrid = (0..<grid.columns).contains(grid.cursor.column) && (0..<grid.rows).contains(grid.cursor.row)
        if preedit.isEmpty, cursorInGrid, let shape = cursorShape(grid.cursor) {
            quads += cursorQuads(grid, shape: shape, scale: scale)
            if shape == .block { quads += cursorGlyph(grid, scale: scale) }
        }
        if !preedit.isEmpty { quads += preeditQuads(grid, scale: scale) }
        return quads
    }

    private func color(_ rgb: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float((rgb >> 16) & 0xFF) / 255, Float((rgb >> 8) & 0xFF) / 255, Float(rgb & 0xFF) / 255, alpha)
    }

    private func metrics(_ scale: CGFloat) -> (width: Float, height: Float, baseline: Float) {
        (Float(cell.width * scale), Float((cell.height * scale).rounded()), Float((ascent * scale).rounded()))
    }

    /// The composing text at the cursor: the theme's background under it (hiding the cells it
    /// covers), its glyphs, and an underline, as macOS draws marked text.
    private func preeditQuads(_ grid: TerminalGrid, scale: CGFloat) -> [Quad] {
        let (cw, ch, baselineOffset) = metrics(scale)
        let row = min(max(0, grid.cursor.row), grid.rows - 1)
        let top = Float(row) * ch, baseline = top + baselineOffset
        let line = Float(max(1, scale.rounded()))
        var x = min(max(0, grid.cursor.column), grid.columns - 1)
        var background: [Quad] = [], glyphs: [Quad] = []
        let ink = color(theme.cursor)
        for character in preedit {
            let scalars = character.unicodeScalars
            let wide = scalars.first.map { Self.isWide($0.value) } ?? false
            let width = wide ? 2 : 1
            let left = (Float(x) * cw).rounded(.down), span = (Float(width) * cw).rounded(.up)
            background.append(Quad(rect: SIMD4(left, top, span, ch), uv: .zero, color: SIMD4(theme.background.x, theme.background.y, theme.background.z, 1), kind: 0))
            background.append(Quad(rect: SIMD4(left, baseline + line, span, line), uv: .zero, color: ink, kind: 0))
            var cell = TerminalCell(scalar: scalars.first?.value ?? 0, foreground: theme.cursor)
            if wide { cell.style.insert(.wide) }
            for p in placed(cell, cluster: scalars.count > 1 ? String(character) : nil, scale: scale) where p.entry.region.width > 0 {
                let r = p.entry.region
                glyphs.append(Quad(rect: SIMD4(left + Float(p.dx * scale + p.entry.offset.x), baseline + Float(p.entry.offset.y), Float(r.width), Float(r.height)),
                                   uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                                   color: p.entry.isColor ? SIMD4(1, 1, 1, 1) : ink, kind: p.entry.isColor ? 2 : 1))
            }
            x += width
        }
        return background + glyphs
    }

    /// East Asian wide and fullwidth characters, and emoji: two cells, for composing text that the
    /// terminal hasn't laid out yet.
    static func isWide(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD: true
        default: false
        }
    }

    /// The character under a block cursor, in the background's color.
    private func cursorGlyph(_ grid: TerminalGrid, scale: CGFloat) -> [Quad] {
        let c = grid[grid.cursor.column, grid.cursor.row]
        let cluster = c.style.contains(.cluster) ? grid.rowClusters[grid.cursor.row][grid.cursor.column] : nil
        guard !c.style.contains(.spacer), c.scalar > 32 || cluster != nil else { return [] }
        let (cw, ch, baselineOffset) = metrics(scale)
        let left = (Float(grid.cursor.column) * cw).rounded(.down)
        let baseline = Float(grid.cursor.row) * ch + baselineOffset
        let ink = SIMD4<Float>(theme.background.x, theme.background.y, theme.background.z, 1)
        return placed(c, cluster: cluster, scale: scale).filter { $0.entry.region.width > 0 }.map { p in
            let r = p.entry.region
            return Quad(rect: SIMD4(left + Float(p.dx * scale + p.entry.offset.x), baseline + Float(p.entry.offset.y), Float(r.width), Float(r.height)),
                        uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                        color: p.entry.isColor ? SIMD4(1, 1, 1, 1) : ink, kind: p.entry.isColor ? 2 : 1)
        }
    }

    /// What fills the strip right of and below the grid, where whole cells don't fit (Ghostty's
    /// window-padding-color): the theme's background, or the edge cells' backgrounds carried to
    /// the edge, so a program's status bar or full-screen color reaches it.
    public enum PaddingColor: Sendable { case background, extend }
    public var paddingColor = PaddingColor.background

    /// Ghostty's minimum-contrast: text whose contrast ratio with its cell's background (WCAG's,
    /// 1 to 21) is below this is drawn black or white, whichever stands out more. 1, the
    /// default as in Ghostty, changes nothing. Rows are cached, so a new value rebuilds them all.
    public var minimumContrast: Float = 1 { didSet { if minimumContrast != oldValue { rebuildAllRows = true } } }
    private var rebuildAllRows = false

    /// `foreground` as drawn over `background` (nil: the theme's), with the minimum contrast.
    func contrasted(_ foreground: UInt32, over background: UInt32?) -> UInt32 {
        guard minimumContrast > 1 else { return foreground }
        let bg = background ?? (UInt32((theme.background.x * 255).rounded()) << 16 | UInt32((theme.background.y * 255).rounded()) << 8
            | UInt32((theme.background.z * 255).rounded()))
        guard Self.contrast(foreground, bg) < minimumContrast else { return foreground }
        return Self.contrast(0xFFFFFF, bg) > Self.contrast(0x000000, bg) ? 0xFFFFFF : 0x000000
    }

    /// WCAG's contrast ratio of two sRGB colors: (lighter + 0.05) / (darker + 0.05) of their
    /// relative luminances.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Float {
        func luminance(_ rgb: UInt32) -> Float {
            func linear(_ c: UInt32) -> Float {
                let v = Float(c & 0xFF) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb >> 16) + 0.7152 * linear(rgb >> 8) + 0.0722 * linear(rgb)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The edge cells' backgrounds, extended into the padding: each row's last cell to the right
    /// edge, the last row's cells to the bottom, and the corner from the last cell.
    private func paddingQuads(_ grid: TerminalGrid, scale: CGFloat, size: (width: Float, height: Float)) -> [Quad] {
        let (cw, ch, _) = metrics(scale)
        let gridRight = (Float(grid.columns) * cw).rounded(.down), gridBottom = Float(grid.rows) * ch
        var quads: [Quad] = []
        func background(_ x: Int, _ y: Int) -> UInt32? {
            let cell = grid[x, y]
            // The right half of a wide character has its left half's color.
            if cell.style.contains(.spacer), x > 0 { return grid[x - 1, y].background }
            return cell.background
        }
        if size.width > gridRight {
            for y in 0..<grid.rows {
                guard let bg = background(grid.columns - 1, y) else { continue }
                quads.append(Quad(rect: SIMD4(gridRight, Float(y) * ch, size.width - gridRight, y == grid.rows - 1 ? max(ch, size.height - Float(y) * ch) : ch),
                                  uv: .zero, color: color(bg), kind: 0))
            }
        }
        if size.height > gridBottom {
            let y = grid.rows - 1
            var x = 0
            while x < grid.columns {
                guard let bg = background(x, y) else { x += 1; continue }
                var end = x + 1
                while end < grid.columns, background(end, y) == bg { end += 1 }
                let left = (Float(x) * cw).rounded(.down), right = (Float(end) * cw).rounded(.down)
                quads.append(Quad(rect: SIMD4(left, gridBottom, right - left, size.height - gridBottom), uv: .zero, color: color(bg), kind: 0))
                x = end
            }
        }
        return quads
    }

    /// An underline under each cell of the hovered link, in that cell's color.
    private func linkQuads(_ grid: TerminalGrid, scale: CGFloat) -> [Quad] {
        guard !highlightedLink.isEmpty else { return [] }
        let (cw, ch, baselineOffset) = metrics(scale)
        let y = Float((underlineOffset * scale).rounded()), height = Float(max(1, (underlineThickness * scale).rounded()))
        var quads: [Quad] = []
        for span in highlightedLink where span.row >= 0 && span.row < grid.rows {
            let baseline = Float(span.row) * ch + baselineOffset
            for x in span.columns where x >= 0 && x < grid.columns {
                let left = (Float(x) * cw).rounded(.down), right = (Float(x + 1) * cw).rounded(.down)
                quads.append(Quad(rect: SIMD4(left, baseline + y, right - left, height), uv: .zero, color: color(grid[x, span.row].foreground), kind: 0))
            }
        }
        return quads
    }

    /// The shape drawn this frame, or nil for none: hidden by the program, off the grid, or
    /// blinked off. Unfocused, a hollow block that doesn't blink.
    func cursorShape(_ cursor: TerminalCursor) -> TerminalCursor.Shape? {
        guard cursor.visible else { return nil }
        if !focused { return .hollowBlock }
        if cursor.blinking, !blinkOn { return nil }
        return cursor.shape
    }

    private func cursorQuads(_ grid: TerminalGrid, shape: TerminalCursor.Shape, scale: CGFloat) -> [Quad] {
        let cursor = grid.cursor
        guard cursor.row >= 0, cursor.row < grid.rows, cursor.column >= 0, cursor.column < grid.columns else { return [] }
        let (cw, ch, _) = metrics(scale)
        let x = (Float(cursor.column) * cw).rounded(.down), y = Float(cursor.row) * ch
        // A wide character's cell is two wide, and so is the block over it.
        let w = (grid[cursor.column, cursor.row].style.contains(.wide) ? cw * 2 : cw).rounded(.up)
        let thickness = Float(max(1, (scale * 1.5).rounded()))
        let ink = color(cursor.color ?? theme.cursor)
        let rects: [SIMD4<Float>] = switch shape {
        case .block: [SIMD4(x, y, w, ch)]
        case .bar: [SIMD4(x, y, thickness, ch)]
        case .underline: [SIMD4(x, y + ch - thickness, w, thickness)]
        case .hollowBlock:
            // An outline as thick as an underline, inside the cell.
            { let t = Float(max(1, (underlineThickness * scale).rounded()))
              return [SIMD4(x, y, w, t), SIMD4(x, y + ch - t, w, t), SIMD4(x, y + t, t, ch - 2 * t), SIMD4(x + w - t, y + t, t, ch - 2 * t)] }()
        }
        return rects.map { Quad(rect: $0, uv: .zero, color: ink, kind: 0) }
    }

    private func rebuild(row y: Int, of grid: TerminalGrid, scale: CGFloat) {
        var backgrounds: [Quad] = [], glyphs: [Quad] = [], blinking: [Quad] = []
        /// A cell's glyph quads, apart for a blinking cell.
        func emit(_ quads: [Quad], for cell: TerminalCell) {
            if cell.style.contains(.blink) { blinking += quads } else { glyphs += quads }
        }
        func emit(_ quad: Quad, for cell: TerminalCell) {
            if cell.style.contains(.blink) { blinking.append(quad) } else { glyphs.append(quad) }
        }
        let (cw, ch, baselineOffset) = metrics(scale)
        let top = Float(y) * ch
        let baseline = top + baselineOffset
        let line = Float(max(1, scale.rounded()))
        let rowStart = y * grid.columns
        let underlineY = Float((underlineOffset * scale).rounded()), underlineHeight = Float(max(1, (underlineThickness * scale).rounded()))
        // Backgrounds: one quad per run of cells with the same explicit color.
        var x = 0
        while x < grid.columns {
            guard let bg = grid.cells[rowStart + x].background else { x += 1; continue }
            var end = x + 1
            while end < grid.columns, grid.cells[rowStart + end].background == bg { end += 1 }
            let left = (Float(x) * cw).rounded(.down), right = (Float(end) * cw).rounded(.down)
            backgrounds.append(Quad(rect: SIMD4(left, top, right - left, ch), uv: .zero, color: color(bg), kind: 0))
            x = end
        }
        // The selection: one quad per run of selected cells, over their backgrounds.
        x = 0
        while x < grid.columns {
            guard grid.cells[rowStart + x].style.contains(.selected) else { x += 1; continue }
            var end = x + 1
            while end < grid.columns, grid.cells[rowStart + end].style.contains(.selected) { end += 1 }
            let left = (Float(x) * cw).rounded(.down), right = (Float(end) * cw).rounded(.down)
            backgrounds.append(Quad(rect: SIMD4(left, top, right - left, ch), uv: .zero, color: theme.selection, kind: 0))
            x = end
        }
        // Search matches: a run of cells in one kind of match, over everything else beneath the
        // text, and the text in the theme's search color.
        let search = searchKinds(row: y, columns: grid.columns)
        if let search {
            x = 0
            while x < grid.columns {
                let kind = search[x]
                guard kind != 0 else { x += 1; continue }
                var end = x + 1
                while end < grid.columns, search[end] == kind { end += 1 }
                let left = (Float(x) * cw).rounded(.down), right = (Float(end) * cw).rounded(.down)
                backgrounds.append(Quad(rect: SIMD4(left, top, right - left, ch), uv: .zero,
                                        color: color(kind == 2 ? theme.searchSelected : theme.searchMatch), kind: 0))
                x = end
            }
        }
        /// A cell's text color: its own, or the search's over a match.
        func ink(_ column: Int, _ cell: TerminalCell) -> SIMD4<Float> {
            if let search, search[column] != 0 { return color(theme.searchText) }
            return color(contrasted(cell.foreground, over: cell.background))
        }
        for x in 0..<grid.columns {
            let c = grid.cells[rowStart + x]
            let left = (Float(x) * cw).rounded(.down)
            let span = c.style.contains(.wide) ? cw * 2 : cw
            if c.underline != .none {
                underline(c.underline, color: color(c.underlineColor ?? c.foreground), left: left, width: span.rounded(.up),
                          y: baseline + underlineY, thickness: underlineHeight, cellBottom: top + ch, into: &backgrounds)
            }
            if c.style.contains(.overline) {
                backgrounds.append(Quad(rect: SIMD4(left, top, span.rounded(.up), underlineHeight), uv: .zero, color: color(c.foreground), kind: 0))
            }
            if c.style.contains(.strikethrough) {
                let middle = top + (baselineOffset * 0.65).rounded()
                backgrounds.append(Quad(rect: SIMD4(left, middle, span.rounded(.up), line), uv: .zero, color: color(c.foreground), kind: 0))
            }
        }
        /// One cell's glyphs, on their own: a character drawn to the cell, or the face's glyph (or a
        /// fallback font's, or a cluster's).
        func drawCell(_ x: Int) {
            let c = grid.cells[rowStart + x]
            let left = (Float(x) * cw).rounded(.down)
            let span = c.style.contains(.wide) ? cw * 2 : cw
            let cluster = c.style.contains(.cluster) ? grid.rowClusters[y][x] : nil
            guard !c.style.contains(.spacer), c.scalar > 32 || cluster != nil else { return }
            if cluster == nil, let drawn = sprite(c.scalar, left: left, top: top, width: span, height: ch,
                                                    line: underlineHeight, color: ink(x, c)) {
                emit(drawn, for: c)
                return
            }
            for p in placed(c, cluster: cluster, scale: scale) where p.entry.region.width > 0 {
                let r = p.entry.region
                emit(Quad(rect: SIMD4(left + Float(p.dx * scale + p.entry.offset.x), baseline + Float(p.entry.offset.y), Float(r.width), Float(r.height)),
                          uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                          color: p.entry.isColor ? SIMD4(1, 1, 1, 1) : ink(x, c), kind: p.entry.isColor ? 2 : 1), for: c)
            }
        }
        // Glyphs: runs of plain text shaped together (ligatures, contextual alternates), and the
        // rest a cell at a time.
        x = 0
        while x < grid.columns {
            let c = grid.cells[rowStart + x]
            // Right-to-left text (Arabic, Hebrew): its run laid out as it reads, letters joined.
            if drawsRightToLeftRuns, Self.isRightToLeft(c.scalar), !c.style.contains(.spacer) {
                let end = rightToLeftRunEnd(grid, row: y, from: x)
                drawRightToLeft(grid, row: y, cells: x..<end, scale: scale, left: (Float(x) * cw).rounded(.down), baseline: baseline,
                                cellWidth: cw, emit: { quad, cell in emit(quad, for: cell) }, ink: ink, drawCell: drawCell)
                x = end
                continue
            }
            if font.shapesRuns(c.style), Self.shapeable(c), c.scalar > 32 {
                // The run: plain text in one face, spaces included, trailing spaces left off.
                let face = c.style.intersection([.bold, .italic])
                var end = x + 1
                while end < grid.columns, Self.shapeable(grid.cells[rowStart + end]),
                      grid.cells[rowStart + end].style.intersection([.bold, .italic]) == face { end += 1 }
                while end > x + 1, grid.cells[rowStart + end - 1].scalar <= 32 { end -= 1 }
                if end - x > 1 {
                    // Shaped a word at a time: no programming ligature spans a space, words repeat
                    // (so the cache hits while text streams, where whole rows never do), and a
                    // word the face can't draw falls back alone. Checked against whole-row shaping
                    // in Fira Code and Menlo over 130,000 lines: the same glyphs, cells and
                    // offsets, but where a character falls back to another font.
                    var words: [(start: Int, end: Int, text: String)] = []
                    var word = x
                    while word < end {
                        guard grid.cells[rowStart + word].scalar > 32 else { word += 1; continue }
                        var wordEnd = word + 1
                        while wordEnd < end, grid.cells[rowStart + wordEnd].scalar > 32 { wordEnd += 1 }
                        words.append((word, wordEnd, String(String.UnicodeScalarView(grid.cells[(rowStart + word)..<(rowStart + wordEnd)].compactMap { UnicodeScalar($0.scalar) }))))
                        word = wordEnd
                    }
                    var runs: [[RunGlyph]??] = words.map { cachedRun($0.text, face: face) }
                    // Several new words: the run shaped once and cut into words (the same glyphs,
                    // as above), so text that's all new costs one shaping, as a row did before.
                    if runs.lazy.filter({ $0 == nil }).count > 1 {
                        let text = String(String.UnicodeScalarView(grid.cells[(rowStart + x)..<(rowStart + end)].compactMap { UnicodeScalar(max(32, $0.scalar)) }))
                        if let whole = shape(text, face: face, scale: scale) {
                            var cut: [[RunGlyph]] = Array(repeating: [], count: words.count)
                            var w = 0
                            for g in whole {
                                let column = x + g.cell
                                while w < words.count, words[w].end <= column { w += 1 }
                                guard w < words.count, column >= words[w].start else { continue }
                                cut[w].append(RunGlyph(glyph: g.glyph, entry: g.entry, cell: column - words[w].start, dx: g.dx))
                            }
                            for i in words.indices where runs[i] == nil {
                                cacheRun(cut[i], for: words[i].text, face: face)
                                runs[i] = .some(cut[i])
                            }
                        }
                    }
                    for (i, w) in words.enumerated() {
                        let run = runs[i] ?? shaped(w.text, face: face, scale: scale)
                        guard let run else {
                            for column in w.start..<w.end { drawCell(column) }
                            continue
                        }
                        for g in run where g.entry.region.width > 0 {
                            let cell = grid.cells[rowStart + w.start + g.cell]
                            let r = g.entry.region
                            let cellLeft = (Float(w.start + g.cell) * cw).rounded(.down)
                            emit(Quad(rect: SIMD4(cellLeft + Float(g.dx * scale + g.entry.offset.x), baseline + Float(g.entry.offset.y), Float(r.width), Float(r.height)),
                                      uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                                      color: g.entry.isColor ? SIMD4(1, 1, 1, 1) : ink(w.start + g.cell, cell), kind: g.entry.isColor ? 2 : 1), for: cell)
                        }
                    }
                    x = end
                    continue
                }
            }
            drawCell(x)
            x += 1
        }
        backgroundQuads[y] = backgrounds
        glyphQuads[y] = glyphs
        blinkingGlyphQuads[y] = blinking
    }

    /// An underline of one kind across `width` pixels, as solid quads: two lines for double,
    /// squares for dotted, dashes for dashed, and for curly a wave a pixel column at a time.
    private func underline(_ kind: TerminalCell.Underline, color: SIMD4<Float>, left: Float, width: Float, y: Float, thickness t: Float,
                           cellBottom: Float, into quads: inout [Quad]) {
        func bar(_ x: Float, _ y: Float, _ w: Float, _ h: Float) {
            quads.append(Quad(rect: SIMD4(x, y, w, h), uv: .zero, color: color, kind: 0))
        }
        switch kind {
        case .none:
            return
        case .single:
            bar(left, y, width, t)
        case .double:
            // The second line below the first, kept inside the cell.
            let second = min(y + t * 2, cellBottom - t)
            bar(left, max(y - t, second - t * 2), width, t)
            bar(left, second, width, t)
        case .dotted:
            var x = left
            while x < left + width { bar(x, y, min(t, left + width - x), t); x += t * 2 }
        case .dashed:
            let dash = max(t * 3, (width / 3).rounded()), gap = max(t * 2, (width / 6).rounded())
            var x = left
            while x < left + width { bar(x, y, min(dash, left + width - x), t); x += dash + gap }
        case .curly:
            // One full wave per cell width, its height twice the thickness, in pixel columns.
            let amplitude = max(1, t), step: Float = 1
            var x = left
            while x < left + width {
                let phase = (x - left) / max(1, width) * 2 * .pi
                bar(x, (y + amplitude * (1 - cos(phase))).rounded(), step, t)
                x += step
            }
        }
    }

    /// A cell that can join a shaped run: one Basic Multilingual Plane scalar (so a UTF-16 unit
    /// is a cell), narrow, and not a character drawn to the cell. An empty cell counts as a space.
    static func shapeable(_ c: TerminalCell) -> Bool {
        guard !c.style.contains(.cluster), !c.style.contains(.wide), !c.style.contains(.spacer), c.scalar < 0x10000 else { return false }
        switch c.scalar {
        case 0x2500...0x259F, 0x2800...0x28FF, 0xE0B0...0xE0B6: return false
        // Right-to-left scripts: CoreText would reorder them, and a cell's glyph has to stay in
        // its cell. They keep a glyph a cell, as Ghostty does with bidi off.
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return false
        default: return true
        }
    }

    // MARK: Right-to-left text

    /// A strong right-to-left letter: Hebrew, Arabic, Syriac, Thaana, N'Ko and their presentation
    /// forms, and the right-to-left planes beyond the BMP.
    static func isRightToLeft(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: true
        default: false
        }
    }

    /// Where a right-to-left run that starts at `start` ends: its letters, and the spaces, digits
    /// and punctuation between them (not after the last letter, which belong to what follows).
    private func rightToLeftRunEnd(_ grid: TerminalGrid, row: Int, from start: Int) -> Int {
        let rowStart = row * grid.columns
        var end = start + 1, lastLetter = start
        while end < grid.columns {
            let c = grid.cells[rowStart + end]
            if c.style.contains(.wide) || c.style.contains(.spacer) { break }
            if Self.isRightToLeft(c.scalar) { lastLetter = end; end += 1; continue }
            // Neutral between letters: a space, a digit, punctuation.
            guard c.scalar <= 0x7E || (0x2000...0x206F).contains(c.scalar) || (0x0660...0x0669).contains(c.scalar), !c.style.contains(.cluster) else { break }
            end += 1
        }
        return lastLetter + 1
    }

    /// A right-to-left run laid out by CoreText: its glyphs in the order they read, each with its
    /// x in points from the run's left edge and the UTF-16 index it came from; the run's width.
    private struct RightToLeftLayout {
        struct Glyph { let entry: AtlasEntry; let x: CGFloat; let index: Int; let glyph: CGGlyph; let font: CTFont }
        let glyphs: [Glyph]
        let width: CGFloat
    }
    private var rightToLeftCache: [RunKey: RightToLeftLayout] = [:]
    /// Testing: off draws right-to-left text a glyph a cell, as before.
    var drawsRightToLeftRuns = true

    /// Testing: a right-to-left run's glyphs, in drawing order, with the UTF-16 index each came
    /// from, its x in points and its glyph in its font.
    func rightToLeftGlyphsForTesting(_ text: String) -> [(index: Int, x: CGFloat, glyph: CGGlyph, font: CTFont)] {
        rightToLeftLayout(text, face: [], scale: 2).glyphs.map { ($0.index, $0.x, $0.glyph, $0.font) }
    }

    private func rightToLeftLayout(_ text: String, face: TerminalCell.Style, scale: CGFloat) -> RightToLeftLayout {
        let key = RunKey(text: text, face: face)
        if let known = rightToLeftCache[key] { return known }
        if rightToLeftCache.count > 2048 { rightToLeftCache.removeAll() }
        let base = font.face(face)
        let attributed = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: base] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        var glyphs: [RightToLeftLayout.Glyph] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            let synthetic = CFEqual(runFont, base) ? font.synthetic(face) : []
            for i in 0..<count {
                guard let entry = atlas.entry(font: runFont, glyph: ids[i], subpixel: 0, scale: scale, isColor: isColor, synthetic: synthetic) else { continue }
                glyphs.append(.init(entry: entry, x: positions[i].x, index: indices[i], glyph: ids[i], font: runFont))
            }
        }
        let layout = RightToLeftLayout(glyphs: glyphs, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        rightToLeftCache[key] = layout
        return layout
    }

    /// Draws cells `cells` of `row` as one right-to-left run: reordered for reading and joined,
    /// as SwiftTerm and Terminal.app show it, right-aligned in the run's cells and squeezed to
    /// fit them if it's wider. Only what's drawn: the cells, the cursor and selection keep the
    /// program's order. A run CoreText can't lay out falls back to a glyph a cell.
    private func drawRightToLeft(_ grid: TerminalGrid, row: Int, cells: Range<Int>, scale: CGFloat, left: Float, baseline: Float,
                                 cellWidth cw: Float, emit: (Quad, TerminalCell) -> Void, ink: (Int, TerminalCell) -> SIMD4<Float>,
                                 drawCell: (Int) -> Void) {
        let rowStart = row * grid.columns
        // The run's text, and which cell each UTF-16 unit came from.
        var text = "", cellOfUnit: [Int] = []
        for x in cells {
            let c = grid.cells[rowStart + x]
            let piece = c.style.contains(.cluster) ? (grid.rowClusters[row][x] ?? "") : (c.scalar > 0 ? UnicodeScalar(c.scalar).map { String($0) } ?? " " : " ")
            text += piece
            cellOfUnit += Array(repeating: x, count: piece.utf16.count)
        }
        let face = grid.cells[rowStart + cells.lowerBound].style.intersection([.bold, .italic])
        let layout = rightToLeftLayout(text, face: face, scale: scale)
        guard !layout.glyphs.isEmpty, layout.width > 0 else { for x in cells { drawCell(x) }; return }
        let span = (Float(cells.count) * cw).rounded(.down)
        let width = Float(layout.width * scale)
        let squeeze = min(1, span / width)
        let start = left + max(0, span - width)
        for g in layout.glyphs where g.entry.region.width > 0 {
            let x = cellOfUnit.indices.contains(g.index) ? cellOfUnit[g.index] : cells.lowerBound
            let cell = grid.cells[rowStart + x]
            let r = g.entry.region
            let glyphX = start + (Float(g.x * scale) + Float(g.entry.offset.x)) * squeeze
            emit(Quad(rect: SIMD4(glyphX, baseline + Float(g.entry.offset.y), Float(r.width) * squeeze, Float(r.height)),
                      uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                      color: g.entry.isColor ? SIMD4(1, 1, 1, 1) : ink(x, cell), kind: g.entry.isColor ? 2 : 1), cell)
        }
    }

    private struct RunKey: Hashable { let text: String; let face: TerminalCell.Style }
    struct RunGlyph { let glyph: CGGlyph; let entry: AtlasEntry; let cell: Int; let dx: CGFloat }
    /// nil: a run the shaper can't place cell for cell (a fallback font's different advance would
    /// push every glyph after it), drawn a cell at a time instead.
    private var runCache = RunCache()

    /// Shaped words, kept in two generations: a word looked up in the older is carried into the
    /// newer, and when the newer fills, the older (the words not seen since) is dropped. Text
    /// streaming past keeps its common words without the whole cache emptying at once.
    private struct RunCache {
        static let generation = 16_384
        private var current: [RunKey: [RunGlyph]?] = [:]
        private var previous: [RunKey: [RunGlyph]?] = [:]
        mutating func value(_ key: RunKey) -> [RunGlyph]?? {
            if let known = current[key] { return known }
            guard let known = previous[key] else { return nil }
            insert(known, for: key)
            return known
        }
        mutating func insert(_ value: [RunGlyph]?, for key: RunKey) {
            if current.count >= Self.generation {
                previous = current
                current = [:]
                current.reserveCapacity(Self.generation)
            }
            current[key] = value
        }
        mutating func removeAll() { current = [:]; previous = [:] }
    }

    /// A run of text shaped by CoreText, with its ligatures and contextual alternates: each glyph
    /// with the cell it starts at (its string index; a UTF-16 unit is a cell here) and its
    /// offset from that cell in points, near zero but for a glyph a font shifts. Cached by text
    /// and face, as Ghostty's shaper caches its runs.
    func shaped(_ text: String, face: TerminalCell.Style, scale: CGFloat) -> [RunGlyph]? {
        if let known = cachedRun(text, face: face) { return known }
        let result = shape(text, face: face, scale: scale)
        cacheRun(result, for: text, face: face)
        return result
    }

    /// A shaped run in the cache: nil if it isn't there; .some(nil) if it's known unshapeable.
    private func cachedRun(_ text: String, face: TerminalCell.Style) -> [RunGlyph]?? {
        runCache.value(RunKey(text: text, face: face))
    }

    private func cacheRun(_ run: [RunGlyph]?, for text: String, face: TerminalCell.Style) {
        runCache.insert(run, for: RunKey(text: text, face: face))
    }

    /// CoreText's shaping of `text`, uncached; nil when a glyph comes from another font or runs
    /// right to left.
    private func shape(_ text: String, face: TerminalCell.Style, scale: CGFloat) -> [RunGlyph]? {
        let base = font.face(face)
        let attributed = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: base, kCTLigatureAttributeName: 1] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        var result: [RunGlyph] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            guard CFEqual(runFont, base), !CTRunGetStatus(run).contains(.rightToLeft) else { return nil }
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            for i in 0..<count {
                let cell = indices[i]
                guard let entry = atlas.entry(font: runFont, glyph: glyphs[i], subpixel: 0, scale: scale, isColor: isColor,
                                              synthetic: font.synthetic(face)) else { continue }
                result.append(RunGlyph(glyph: glyphs[i], entry: entry, cell: cell, dx: positions[i].x - CGFloat(cell) * self.cell.width))
            }
        }
        return result
    }

    /// One cell's glyphs, cached by text and style: straight from the face when it has the
    /// character, else through CoreText, which falls back to another font and shapes clusters.
    private func placed(_ c: TerminalCell, cluster: String?, scale: CGFloat) -> [Placed] {
        let style = c.style.intersection([.bold, .italic])
        let key = GlyphKey(scalar: c.scalar, cluster: cluster, style: style)
        if let known = glyphCache[key] { return known }
        let face = font.face(style)
        var result: [Placed] = []
        if cluster == nil, c.scalar < 0x10000 {
            var character = UniChar(c.scalar), glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(face, &character, &glyph, 1), glyph != 0 {
                if let entry = atlas.entry(font: face, glyph: glyph, subpixel: 0, scale: scale, isColor: false, synthetic: font.synthetic(style)) {
                    result = [Placed(entry: entry, dx: 0)]
                }
                glyphCache[key] = result
                return result
            }
        }
        let text = cluster ?? UnicodeScalar(c.scalar).map { String(Character($0)) } ?? " "
        let attributed = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: face] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                // The face's own glyphs take its synthetic styles; a fallback font's are its own.
                let synthetic = CFEqual(runFont, face) ? font.synthetic(style) : []
                if let entry = atlas.entry(font: runFont, glyph: glyphs[i], subpixel: 0, scale: scale, isColor: isColor, synthetic: synthetic) {
                    result.append(Placed(entry: entry, dx: positions[i].x))
                }
            }
        }
        glyphCache[key] = result
        return result
    }
}
