import AlloyCore
import CoreGraphics
import CoreText
import Metal
import QuartzCore
import simd

/// Colors a frame is drawn with. Components are premultiplied-ready RGBA in 0…1.
public struct RenderTheme: Sendable {
    public var background: SIMD4<Float>
    public var text: SIMD4<Float>
    public var selection: SIMD4<Float>
    public var caret: SIMD4<Float>
    public var currentLine: SIMD4<Float>

    public init(background: SIMD4<Float>, text: SIMD4<Float>, selection: SIMD4<Float>, caret: SIMD4<Float>, currentLine: SIMD4<Float>) {
        self.background = background
        self.text = text
        self.selection = selection
        self.caret = caret
        self.currentLine = currentLine
    }

    public static let light = RenderTheme(background: [0.957, 0.957, 0.965, 1], text: [0.1, 0.1, 0.12, 1],
                                          selection: [0.70, 0.83, 1.0, 1], caret: [0.0, 0.48, 1.0, 1], currentLine: [0, 0, 0, 0.05])
    public static let dark = RenderTheme(background: [0.082, 0.090, 0.102, 1], text: [0.92, 0.92, 0.94, 1],
                                         selection: [0.20, 0.33, 0.55, 1], caret: [0.25, 0.6, 1.0, 1], currentLine: [1, 1, 1, 0.045])
}

/// A color for a UTF-16 range of a line (syntax highlighting, step 4).
public struct StyleSpan: Sendable {
    public var range: Range<Int>
    public var color: SIMD4<Float>
    public init(range: Range<Int>, color: SIMD4<Float>) {
        self.range = range
        self.color = color
    }
}

/// A mark over a document range: an underline (diagnostics, text being composed) or a
/// background tint (a matched bracket).
public struct Decoration: Sendable {
    public enum Style: Sendable { case underline, dottedUnderline, background }
    public var range: Range<Int>
    public var color: SIMD4<Float>
    public var style: Style
    public init(range: Range<Int>, color: SIMD4<Float>, style: Style) {
        self.range = range
        self.color = color
        self.style = style
    }
}

/// What one frame shows.
public struct RenderFrame {
    /// The top of the viewport in document points.
    public var scrollY: CGFloat
    /// The viewport's size in points.
    public var size: CGSize
    public var scale: CGFloat
    public var selections: [Selection]
    public var caretVisible: Bool
    public var theme: RenderTheme
    /// Colors for a line, relative to its start; nil draws it in the text color.
    public var styles: ((Int) -> [StyleSpan])?
    public var decorations: [Decoration] = []

    public init(scrollY: CGFloat, size: CGSize, scale: CGFloat, selections: [Selection], caretVisible: Bool = true,
                theme: RenderTheme, styles: ((Int) -> [StyleSpan])? = nil) {
        self.scrollY = scrollY
        self.size = size
        self.scale = scale
        self.selections = selections
        self.caretVisible = caretVisible
        self.theme = theme
        self.styles = styles
    }
}

/// What building a frame cost, for the budgets.
public struct FrameStats: Sendable {
    public var cpuMilliseconds: Double = 0
    public var quads = 0
    public var visibleLines = 0
    public var atlasGlyphs = 0
}

/// Draws a document's viewport with Metal (docs/DESIGN.md, A1): CoreText has shaped each
/// line; this places glyphs from the atlas and rectangles for the current line, selections and
/// carets, all as instanced quads in one draw call.
@MainActor
public final class TextRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    let atlas: GlyphAtlas
    public private(set) var lastStats = FrameStats()

    /// One quad: a rectangle in pixels, its atlas region (for glyphs), a color, and a kind.
    struct Quad {
        var rect: SIMD4<Float>
        var uv: SIMD4<Float>
        var color: SIMD4<Float>
        /// 0 solid, 1 tinted glyph, 2 color glyph.
        var kind: Float
        var padding: SIMD3<Float> = .zero
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shaders, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "quadVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "quadFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
        atlas = GlyphAtlas(device: device)
    }

    public enum RenderError: Error { case noDevice }

    /// Encodes a frame into `target` and commits it; presents `drawable` if given.
    /// Called on Metal's completion queue: made outside any actor (see `AlloyEditorView`'s
    /// `recordPresentation`).
    nonisolated private static func signalWhenDone(_ semaphore: DispatchSemaphore) -> @Sendable (MTLCommandBuffer) -> Void {
        { _ in semaphore.signal() }
    }

    /// Draw nothing but the background: a control for measurements (a frame's cost without the
    /// text). `ALLOY_CLEAR_ONLY=1` sets it at launch.
    public nonisolated(unsafe) static var clearOnly = ProcessInfo.processInfo.environment["ALLOY_CLEAR_ONLY"] == "1"

    @discardableResult
    public func draw(_ frame: RenderFrame, layout: DocumentLayout, into target: MTLTexture, drawable: CAMetalDrawable? = nil,
                     completion: (@Sendable (MTLCommandBuffer) -> Void)? = nil) -> MTLCommandBuffer? {
        let start = CACurrentMediaTime()
        var quads = Self.clearOnly ? [] : buildQuads(frame, layout: layout)
        // An atlas that filled mid-frame dropped entries this frame already used: build again.
        if atlasRestarted { atlasRestarted = false; quads = buildQuads(frame, layout: layout) }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = frame.theme.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w))
        framesInFlight.wait()
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { framesInFlight.signal(); return nil }
        let inFlight = framesInFlight
        buffer.addCompletedHandler(Self.signalWhenDone(inFlight))
        if !quads.isEmpty {
            var viewport = SIMD2<Float>(Float(target.width), Float(target.height))
            var atlasSize = Float(atlas.size)
            encoder.setRenderPipelineState(pipeline)
            let length = quads.count * MemoryLayout<Quad>.stride
            if length <= 4096 {
                encoder.setVertexBytes(&quads, length: length, index: 0)
            } else {
                // A ring of buffers, one per frame in flight, reused instead of allocated.
                let buffer = instanceBuffer(length: length)
                buffer.contents().copyMemory(from: &quads, byteCount: length)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            }
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&atlasSize, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: quads.count)
        }
        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        if let completion { buffer.addCompletedHandler(completion) }
        buffer.commit()
        lastStats.cpuMilliseconds = (CACurrentMediaTime() - start) * 1000
        lastStats.quads = quads.count
        lastStats.atlasGlyphs = atlas.count
        return buffer
    }

    private var atlasRestarted = false
    private var ring: [MTLBuffer] = []
    private var ringIndex = 0
    private let framesInFlight = DispatchSemaphore(value: 3)

    private func instanceBuffer(length: Int) -> MTLBuffer {
        ringIndex = (ringIndex + 1) % 3
        if ring.count < 3 || ring[ringIndex].length < length {
            let buffer = device.makeBuffer(length: max(length, 64 * 1024), options: .storageModeShared)!
            if ring.count < 3 { ring.append(buffer); ringIndex = ring.count - 1 } else { ring[ringIndex] = buffer }
            return buffer
        }
        return ring[ringIndex]
    }

    func buildQuads(_ frame: RenderFrame, layout: DocumentLayout) -> [Quad] {
        let scale = frame.scale
        let generation = atlas.generation
        var solids: [Quad] = []
        var glyphs: [Quad] = []
        var carets: [Quad] = []
        var underlines: [Quad] = []
        let lines = layout.visibleLines(from: frame.scrollY, to: frame.scrollY + frame.size.height)
        lastStats.visibleLines = lines.count
        let text = layout.text
        let lineHeight = layout.lineHeight
        let viewportWidth = frame.size.width

        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> SIMD4<Float> {
            // Snap to device pixels so edges are crisp.
            let x0 = (x * scale).rounded(), y0 = ((y - frame.scrollY) * scale).rounded()
            let x1 = ((x + w) * scale).rounded(), y1 = ((y - frame.scrollY + h) * scale).rounded()
            return [Float(x0), Float(y0), Float(max(1, x1 - x0)), Float(max(1, y1 - y0))]
        }

        // The current-line band: where a caret with no selection sits.
        for selection in frame.selections where selection.isCaret {
            let caret = layout.caretRect(at: selection.head)
            solids.append(Quad(rect: rect(0, caret.minY, viewportWidth, lineHeight), uv: .zero, color: frame.theme.currentLine, kind: 0))
        }

        for (line, top, laid) in lines {
            let lineStart = text.offset(ofLine: line)
            let lineRange = lineStart..<(lineStart + laid.text.utf16.count)
            let spans = frame.styles?(line) ?? []

            // Selections: a band per row they cover, reaching the edge when they continue past it.
            for selection in frame.selections where !selection.isCaret {
                let sel = selection.range
                guard sel.lowerBound <= lineRange.upperBound, sel.upperBound >= lineRange.lowerBound else { continue }
                for (index, row) in laid.rows.enumerated() {
                    let rowRange = (lineStart + row.range.lowerBound)..<(lineStart + row.range.upperBound)
                    let lower = max(sel.lowerBound, rowRange.lowerBound)
                    let upper = min(sel.upperBound, rowRange.upperBound)
                    let continues = sel.upperBound > rowRange.upperBound
                    guard lower < upper || (continues && lower <= upper && sel.lowerBound <= rowRange.upperBound) else { continue }
                    let x0 = laid.caretX(at: lower - lineStart).x
                    let x1 = continues ? viewportWidth - layout.insets.width : laid.caretX(at: upper - lineStart).x
                    solids.append(Quad(rect: rect(layout.insets.width + x0, top + CGFloat(index) * lineHeight, max(2, x1 - x0), lineHeight),
                                       uv: .zero, color: frame.theme.selection, kind: 0))
                }
            }

            // Decorations: a band or a line under each row they touch.
            for decoration in frame.decorations {
                let range = decoration.range
                guard range.lowerBound <= lineRange.upperBound, range.upperBound >= lineRange.lowerBound, !range.isEmpty else { continue }
                for (index, row) in laid.rows.enumerated() {
                    let rowRange = (lineStart + row.range.lowerBound)..<(lineStart + row.range.upperBound)
                    let lower = max(range.lowerBound, rowRange.lowerBound)
                    let upper = min(range.upperBound, rowRange.upperBound)
                    guard lower < upper else { continue }
                    let x0 = laid.caretX(at: lower - lineStart).x
                    let x1 = laid.caretX(at: upper - lineStart).x
                    let rowTop = top + CGFloat(index) * lineHeight
                    switch decoration.style {
                    case .background:
                        solids.append(Quad(rect: rect(layout.insets.width + x0, rowTop, max(1, x1 - x0), lineHeight), uv: .zero, color: decoration.color, kind: 0))
                    case .underline:
                        underlines.append(Quad(rect: rect(layout.insets.width + x0, rowTop + lineHeight - 2, max(1, x1 - x0), 1), uv: .zero, color: decoration.color, kind: 0))
                    case .dottedUnderline:
                        var x = x0
                        while x < x1 {
                            underlines.append(Quad(rect: rect(layout.insets.width + x, rowTop + lineHeight - 2, min(2, x1 - x), 1), uv: .zero, color: decoration.color, kind: 0))
                            x += 4
                        }
                    }
                }
            }

            // Glyphs.
            var spanIndex = 0
            for (index, row) in laid.rows.enumerated() {
                let baseline = top + CGFloat(index) * lineHeight + layout.ascent
                guard baseline - frame.scrollY > -lineHeight, baseline - frame.scrollY < frame.size.height + lineHeight else { continue }
                for run in row.runs {
                    for g in 0..<run.glyphs.count {
                        let penX = (layout.insets.width + run.positions[g].x) * scale
                        let penY = ((baseline - frame.scrollY) - run.positions[g].y) * scale
                        let snappedX = floor(penX)
                        let subpixel = min(GlyphAtlas.subpixelSteps - 1, Int((penX - snappedX) * CGFloat(GlyphAtlas.subpixelSteps)))
                        guard let entry = atlas.entry(font: run.font, glyph: run.glyphs[g], subpixel: subpixel, scale: scale, isColor: run.isColor),
                              entry.region.width > 0 else { continue }
                        var color = frame.theme.text
                        let at = run.indices[g]
                        while spanIndex < spans.count, spans[spanIndex].range.upperBound <= at { spanIndex += 1 }
                        if spanIndex < spans.count, spans[spanIndex].range.contains(at) { color = spans[spanIndex].color }
                        let x = Float(snappedX + entry.offset.x)
                        let y = Float(penY.rounded() + entry.offset.y)
                        glyphs.append(Quad(rect: [x, y, Float(entry.region.width), Float(entry.region.height)],
                                           uv: [Float(entry.region.minX), Float(entry.region.minY), Float(entry.region.width), Float(entry.region.height)],
                                           color: color, kind: entry.isColor ? 2 : 1))
                    }
                }
                spanIndex = 0
            }
        }

        if frame.caretVisible {
            for selection in frame.selections {
                let caret = layout.caretRect(at: selection.head)
                guard caret.maxY >= frame.scrollY, caret.minY <= frame.scrollY + frame.size.height else { continue }
                carets.append(Quad(rect: rect(caret.minX - 0.5, caret.minY + 1, 2 / scale * max(1, scale / 1.5), lineHeight - 2),
                                   uv: .zero, color: frame.theme.caret, kind: 0))
            }
        }
        if atlas.generation != generation { atlasRestarted = true }
        return solids + glyphs + underlines + carets
    }

    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Quad {
        float4 rect;
        float4 uv;
        float4 color;
        float kind;
        float3 padding;
    };

    struct Varyings {
        float4 position [[position]];
        float2 uv;
        float4 color;
        float kind;
    };

    vertex Varyings quadVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device Quad *quads [[buffer(0)]],
                               constant float2 &viewport [[buffer(1)]]) {
        const float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1) };
        Quad q = quads[iid];
        float2 corner = corners[vid];
        float2 pixel = q.rect.xy + corner * q.rect.zw;
        Varyings out;
        out.position = float4(pixel.x / viewport.x * 2.0 - 1.0, 1.0 - pixel.y / viewport.y * 2.0, 0, 1);
        out.uv = q.uv.xy + corner * q.uv.zw;
        out.color = q.color;
        out.kind = q.kind;
        return out;
    }

    fragment float4 quadFragment(Varyings in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                 sampler s [[sampler(0)]], constant float &atlasSize [[buffer(0)]]) {
        if (in.kind < 0.5) {
            return float4(in.color.rgb * in.color.a, in.color.a);
        }
        float4 texel = atlas.sample(s, in.uv / atlasSize);
        if (in.kind < 1.5) {
            float coverage = texel.a;
            return float4(in.color.rgb * in.color.a * coverage, in.color.a * coverage);
        }
        return texel;
    }
    """
}
