import Metal
import Synchronization

/// The GPU objects every Alloy renderer on one device draws with: a command queue, the compiled
/// quad shaders and the atlas sampler. Metal makes all three safe to use from any thread, so one
/// set serves the editors on the main thread and a terminal drawing on a thread of its own
/// (docs/SIDE_RFC_TERMINAL_ENGINE.md, Phase 1). Compiled once per device and pixel format, and
/// kept while any renderer holds it.
package final class QuadPipeline: @unchecked Sendable {
    // @unchecked: MTLCommandQueue, MTLRenderPipelineState and MTLSamplerState are thread-safe
    // (Metal's own guarantee), and these are never reassigned.
    package let queue: MTLCommandQueue
    package let pipeline: MTLRenderPipelineState
    package let sampler: MTLSamplerState

    private struct Key: Hashable { let device: UInt64; let pixelFormat: UInt }
    private final class Weak: @unchecked Sendable { weak var value: QuadPipeline? }
    private static let cache = Mutex<[Key: Weak]>([:])

    package static func shared(device: MTLDevice, pixelFormat: MTLPixelFormat) throws -> QuadPipeline {
        let key = Key(device: device.registryID, pixelFormat: pixelFormat.rawValue)
        return try cache.withLock { cache in
            if let existing = cache[key]?.value { return existing }
            let made = try QuadPipeline(device: device, pixelFormat: pixelFormat)
            let box = Weak()
            box.value = made
            cache[key] = box
            return made
        }
    }

    private init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard let queue = device.makeCommandQueue() else { throw TextRenderer.RenderError.noDevice }
        self.queue = queue
        let library = try device.makeLibrary(source: TextRenderer.shaders, options: nil)
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
    }
}
