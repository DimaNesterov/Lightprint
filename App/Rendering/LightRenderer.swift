import MetalKit
import ARKit
import LumenCore

/// How the light is drawn. Changing these never changes the light field itself, only its look,
/// and they apply to every splat equally.
struct RenderSettings: Codable, Equatable {
    /// Camera brightness while the light is shown (a darker room lets the light read better).
    var cameraDim: Float = 0.45
    /// Gaussian sigma of every splat, metres.
    var sigma: Float = 0.006
    /// Peak opacity of every splat.
    var opacity: Float = 0.14
    /// Tonemap exposure: 1 − exp(−exposure · accumulated light).
    var exposure: Float = 1.0
    /// Hide splats behind real surfaces using LiDAR depth.
    var occlusion: Bool = true
    /// Show marked windows and lamps while viewing the light.
    var showMarkers: Bool = false
    /// Draw the light in when it appears: rays grow out of their sources, then ambient light fades in.
    var animateReveal: Bool = true
    /// Splats near a moving phone move slightly aside and drift back when it stops.
    var pushParticles: Bool = true

    init() {}

    // Tolerant decoding: settings saved by an older version keep their values, new ones take defaults.
    private enum CodingKeys: String, CodingKey {
        case cameraDim, sigma, opacity, exposure, occlusion, showMarkers, animateReveal, pushParticles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RenderSettings()
        cameraDim = try c.decodeIfPresent(Float.self, forKey: .cameraDim) ?? d.cameraDim
        sigma = try c.decodeIfPresent(Float.self, forKey: .sigma) ?? d.sigma
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? d.opacity
        exposure = try c.decodeIfPresent(Float.self, forKey: .exposure) ?? d.exposure
        occlusion = try c.decodeIfPresent(Bool.self, forKey: .occlusion) ?? d.occlusion
        showMarkers = try c.decodeIfPresent(Bool.self, forKey: .showMarkers) ?? d.showMarkers
        animateReveal = try c.decodeIfPresent(Bool.self, forKey: .animateReveal) ?? d.animateReveal
        pushParticles = try c.decodeIfPresent(Bool.self, forKey: .pushParticles) ?? d.pushParticles
    }
}

/// One marker point (UI only).
struct MarkerPoint {
    var positionSize: SIMD4<Float>
    var color: SIMD4<Float>

    init(_ p: Vec3, size: Float, color: SIMD4<Float>) {
        positionSize = SIMD4<Float>(p.x, p.y, p.z, size)
        self.color = color
    }
}

private struct GPUSplat {
    var positionLayer: SIMD4<Float>
    var color: SIMD4<Float>
}

private struct CameraUniforms {
    var uv0: SIMD2<Float>, uv1: SIMD2<Float>, uv2: SIMD2<Float>, uv3: SIMD2<Float>
    var dim: Float
    var pad: Float = 0
}

private struct SplatUniforms {
    var viewProjection: simd_float4x4
    var view: simd_float4x4
    var worldToCamera: simd_float4x4
    var intrinsics: SIMD4<Float>
    var imageSize: SIMD2<Float>
    var viewport: SIMD2<Float>
    var focalPixels: Float
    var sigma: Float
    var opacity: Float
    var minPixels: Float
    var nearStart: Float
    var nearEnd: Float
    var occlusion: Float
    var layerCount: UInt32
    var cameraPush: SIMD4<Float>    // camera position, w = push strength 0…1 (how fast the phone moves)
    var revealTime: Float           // seconds since the light started to be drawn in; huge = fully drawn
    var revealSpeed: Float          // metres per second of the drawing front along the rays
    var pushRadius: Float           // metres around the phone
    var pushAmount: Float           // largest displacement, metres
}

private struct CompositeUniforms {
    var exposure: Float
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
}

/// Draws the camera image, the light (identical gaussian splats accumulated additively into a float
/// texture, then tonemapped and screen-blended over the camera) and the source markers, all in one Metal view.
final class LightRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cameraPipeline: MTLRenderPipelineState
    private let splatPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let markerPipeline: MTLRenderPipelineState
    private let scanPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let dummyDepth: MTLTexture
    private var lightTexture: MTLTexture?
    private let inFlight = DispatchSemaphore(value: 3)

    /// The light is accumulated at this fraction of the screen resolution (gaussians are smooth).
    let lightScale: CGFloat = 0.5
    static let maxLayers = 512

    weak var session: ARSession?
    var settings = RenderSettings()
    /// Camera brightness for the current mode (1 while marking or capturing).
    var cameraDim: Float = 1
    var showLight = false
    var showMarkers = true
    /// Live preview of the scan in progress.
    var showScan = false

    private var splatBuffer: MTLBuffer?
    private var splatCount = 0
    private var layerWeights: [Float] = [0]
    private var markerBuffer: MTLBuffer?
    private var markerCount = 0

    // Drawing the light in
    private var revealStart: CFTimeInterval?
    static let revealSpeed: Float = 1.2          // m/s along the rays
    static let revealDuration: CFTimeInterval = 9

    // Particles moving aside around the phone
    private var lastCameraPosition: SIMD3<Float>?
    private var lastFrameTime: CFTimeInterval = 0
    private var smoothedSpeed: Float = 0
    private var pushStrength: Float = 0
    private var scanBuffer: MTLBuffer?
    private var scanCount = 0

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue

        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat,
                      blend: ((MTLRenderPipelineColorAttachmentDescriptor) -> Void)?) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            if let blend {
                d.colorAttachments[0].isBlendingEnabled = true
                blend(d.colorAttachments[0])
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        let screen = view.colorPixelFormat
        guard let camera = pipeline("cameraVertex", "cameraFragment", format: screen, blend: nil),
              let splat = pipeline("splatVertex", "splatFragment", format: .rgba16Float, blend: { c in
                  c.rgbBlendOperation = .add
                  c.alphaBlendOperation = .add
                  c.sourceRGBBlendFactor = .one
                  c.destinationRGBBlendFactor = .one
                  c.sourceAlphaBlendFactor = .one
                  c.destinationAlphaBlendFactor = .one
              }),
              let composite = pipeline("fullscreenVertex", "compositeFragment", format: screen, blend: { c in
                  // Screen blend: result = light + camera · (1 − light).
                  c.sourceRGBBlendFactor = .one
                  c.destinationRGBBlendFactor = .oneMinusSourceColor
                  c.sourceAlphaBlendFactor = .one
                  c.destinationAlphaBlendFactor = .zero
              }),
              let marker = pipeline("markerVertex", "markerFragment", format: screen, blend: { c in
                  c.sourceRGBBlendFactor = .sourceAlpha
                  c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                  c.sourceAlphaBlendFactor = .one
                  c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
              }),
              let scan = pipeline("markerVertex", "scanFragment", format: screen, blend: { c in
                  c.sourceRGBBlendFactor = .sourceAlpha
                  c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                  c.sourceAlphaBlendFactor = .one
                  c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
              })
        else { return nil }
        cameraPipeline = camera
        splatPipeline = splat
        compositePipeline = composite
        markerPipeline = marker
        scanPipeline = scan

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        td.usage = .shaderRead
        guard let dummy = device.makeTexture(descriptor: td) else { return nil }
        var zero: Float = 0
        dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        dummyDepth = dummy

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
        super.init()
    }

    // MARK: Data

    func setSplats(_ splats: [Splat]) {
        guard !splats.isEmpty else {
            splatBuffer = nil
            splatCount = 0
            return
        }
        let gpu = splats.map {
            GPUSplat(positionLayer: SIMD4<Float>($0.position.x, $0.position.y, $0.position.z, Float($0.layer)),
                     color: SIMD4<Float>($0.color.x, $0.color.y, $0.color.z, $0.reveal))
        }
        splatBuffer = gpu.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        splatCount = splatBuffer == nil ? 0 : gpu.count
    }

    /// Starts drawing the light in from its sources (if the setting is on, or when asked for explicitly).
    /// With a delay the light disappears at once and starts growing only after `delay` seconds.
    func startReveal(force: Bool = false, delay: CFTimeInterval = 0) {
        revealStart = (settings.animateReveal || force) ? CACurrentMediaTime() + delay : nil
    }

    func setLayerWeights(_ weights: [Float]) {
        layerWeights = weights.isEmpty ? [0] : Array(weights.prefix(Self.maxLayers))
    }

    func setMarkers(_ markers: [MarkerPoint]) {
        guard !markers.isEmpty else {
            markerBuffer = nil
            markerCount = 0
            return
        }
        markerBuffer = markers.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        markerCount = markerBuffer == nil ? 0 : markers.count
    }

    func setScanPoints(_ points: [MarkerPoint]) {
        guard !points.isEmpty else {
            scanBuffer = nil
            scanCount = 0
            return
        }
        scanBuffer = points.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        scanCount = scanBuffer == nil ? 0 : points.count
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lightTexture = nil
    }

    func draw(in view: MTKView) {
        _ = inFlight.wait(timeout: .distantFuture)
        let size = view.drawableSize
        guard size.width > 0, size.height > 0,
              let frame = session?.currentFrame,
              let commandBuffer = queue.makeCommandBuffer(),
              let cache = textureCache,
              let cvY = texture(from: frame.capturedImage, format: .r8Unorm, plane: 0, cache: cache),
              let cvCbCr = texture(from: frame.capturedImage, format: .rg8Unorm, plane: 1, cache: cache),
              let texY = CVMetalTextureGetTexture(cvY),
              let texCbCr = CVMetalTextureGetTexture(cvCbCr) else {
            inFlight.signal()
            return
        }
        var keepAlive: [CVMetalTexture] = [cvY, cvCbCr]
        var depthTexture: MTLTexture = dummyDepth
        if let depthMap = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap,
           let cvDepth = texture(from: depthMap, format: .r32Float, plane: 0, cache: cache),
           let t = CVMetalTextureGetTexture(cvDepth) {
            keepAlive.append(cvDepth)
            depthTexture = t
        }
        let retained = keepAlive   // camera/depth textures must outlive the GPU work

        let orientation = UIInterfaceOrientation.portrait
        let camera = frame.camera
        let viewMatrix = camera.viewMatrix(for: orientation)
        let projection = camera.projectionMatrix(for: orientation, viewportSize: size, zNear: 0.02, zFar: 40)
        let viewProjection = projection * viewMatrix

        // 1. Light: identical gaussians, additive, into a float texture.
        let drawLight = showLight && splatCount > 0
        if drawLight, let splats = splatBuffer, let light = lightTarget(for: size) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = light
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                let viewport = SIMD2<Float>(Float(light.width), Float(light.height))
                let k = camera.intrinsics
                // Drawing-in clock.
                let now = CACurrentMediaTime()
                var revealTime: Float = 1e6
                if let start = revealStart {
                    if now - start < Self.revealDuration { revealTime = Float(now - start) } else { revealStart = nil }
                }
                // How fast the phone moves: splats near it move aside, then drift back when it stops.
                let camPos = SIMD3<Float>(camera.transform.columns.3.x, camera.transform.columns.3.y,
                                          camera.transform.columns.3.z)
                if now - lastFrameTime > 0.25 { lastCameraPosition = nil }     // light was hidden: no jump
                let dt = Float(min(max(now - lastFrameTime, 1.0 / 120), 0.1))
                var speed: Float = 0
                if let last = lastCameraPosition { speed = simd_length(camPos - last) / dt }
                lastCameraPosition = camPos
                lastFrameTime = now
                smoothedSpeed += (speed - smoothedSpeed) * (1 - exp(-dt / 0.12))   // tracking jitter averages out
                let target: Float = settings.pushParticles ? min(max((smoothedSpeed - 0.05) / 0.3, 0), 1) : 0
                let tau: Float = target > pushStrength ? 0.2 : 1.0      // quick to push, slow to settle back
                pushStrength += (target - pushStrength) * (1 - exp(-dt / tau))

                var u = SplatUniforms(
                    viewProjection: viewProjection,
                    view: viewMatrix,
                    worldToCamera: camera.transform.inverse,
                    intrinsics: SIMD4<Float>(k[0][0], k[1][1], k[2][0], k[2][1]),
                    imageSize: SIMD2<Float>(Float(camera.imageResolution.width), Float(camera.imageResolution.height)),
                    viewport: viewport,
                    focalPixels: projection.columns.1.y * viewport.y * 0.5,
                    sigma: settings.sigma,
                    opacity: settings.opacity,
                    minPixels: 0.8,
                    nearStart: 0.3,
                    nearEnd: 0.7,
                    occlusion: settings.occlusion ? 1 : 0,
                    layerCount: UInt32(layerWeights.count),
                    cameraPush: SIMD4<Float>(camPos.x, camPos.y, camPos.z, pushStrength),
                    revealTime: revealTime,
                    revealSpeed: Self.revealSpeed,
                    pushRadius: 1.0,
                    pushAmount: 0.06)
                var weights = layerWeights
                enc.setRenderPipelineState(splatPipeline)
                enc.setVertexBuffer(splats, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<SplatUniforms>.stride, index: 1)
                enc.setVertexBytes(&weights, length: MemoryLayout<Float>.stride * weights.count, index: 2)
                enc.setVertexTexture(depthTexture, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCount)
                enc.endEncoding()
            }
        }

        // 2. Screen: camera, light on top, markers.
        guard let screenPass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
            commandBuffer.addCompletedHandler { [weak self] _ in
                _ = retained
                self?.inFlight.signal()
            }
            commandBuffer.commit()
            return
        }
        screenPass.colorAttachments[0].loadAction = .clear
        screenPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) {
            let toCamera = frame.displayTransform(for: orientation, viewportSize: size).inverted()
            func uv(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> {
                let p = CGPoint(x: x, y: y).applying(toCamera)
                return SIMD2<Float>(Float(p.x), Float(p.y))
            }
            var cu = CameraUniforms(uv0: uv(0, 1), uv1: uv(1, 1), uv2: uv(0, 0), uv3: uv(1, 0),
                                    dim: drawLight ? cameraDim : 1)
            enc.setRenderPipelineState(cameraPipeline)
            enc.setVertexBytes(&cu, length: MemoryLayout<CameraUniforms>.stride, index: 0)
            enc.setFragmentBytes(&cu, length: MemoryLayout<CameraUniforms>.stride, index: 0)
            enc.setFragmentTexture(texY, index: 0)
            enc.setFragmentTexture(texCbCr, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            if drawLight, let light = lightTexture {
                var c = CompositeUniforms(exposure: settings.exposure)
                enc.setRenderPipelineState(compositePipeline)
                enc.setFragmentBytes(&c, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
                enc.setFragmentTexture(light, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            if showScan, scanCount > 0, let scan = scanBuffer {
                var vp = viewProjection
                enc.setRenderPipelineState(scanPipeline)
                enc.setVertexBuffer(scan, offset: 0, index: 0)
                enc.setVertexBytes(&vp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: scanCount)
            }

            if showMarkers, markerCount > 0, let markers = markerBuffer {
                var vp = viewProjection
                enc.setRenderPipelineState(markerPipeline)
                enc.setVertexBuffer(markers, offset: 0, index: 0)
                enc.setVertexBytes(&vp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: markerCount)
            }
            enc.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = retained
            self?.inFlight.signal()
        }
        commandBuffer.commit()
    }

    // MARK: Helpers

    private func lightTarget(for drawableSize: CGSize) -> MTLTexture? {
        let w = max(1, Int(drawableSize.width * lightScale)), h = max(1, Int(drawableSize.height * lightScale))
        if let t = lightTexture, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        lightTexture = device.makeTexture(descriptor: d)
        return lightTexture
    }

    private func texture(from buffer: CVPixelBuffer, format: MTLPixelFormat, plane: Int,
                         cache: CVMetalTextureCache) -> CVMetalTexture? {
        let planar = CVPixelBufferGetPlaneCount(buffer) > 0
        let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var out: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, w, h, planar ? plane : 0, &out)
        return status == kCVReturnSuccess ? out : nil
    }
}
