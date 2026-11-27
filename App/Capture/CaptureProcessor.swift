import Foundation
import ARKit
import CoreVideo
import simd
import LumenCore

/// One frame handed to the background processor.
struct CaptureFrame {
    let image: CVPixelBuffer
    let depth: CVPixelBuffer
    let confidence: CVPixelBuffer?
    let geometry: CameraGeometry
    let exposureScale: Float
    let exposureFromExif: Bool

    init?(frame: ARFrame, fallbackExposureScale: Float) {
        guard let depth = frame.sceneDepth?.depthMap else { return nil }
        image = frame.capturedImage
        self.depth = depth
        confidence = frame.sceneDepth?.confidenceMap
        geometry = CameraGeometry(camera: frame.camera)
        if let s = CameraControl.exposureScale(of: frame) {
            exposureScale = s
            exposureFromExif = true
        } else {
            exposureScale = fallbackExposureScale
            exposureFromExif = false
        }
    }
}

/// What one scan produced.
struct CaptureResult {
    let voxels: [SurfaceVoxel]
    let frames: Int
    let exifFrames: Int
    /// How bright each marked source looked to the camera (90th percentile, same units as surface radiance).
    let sourceLuminance: [UUID: Float]
}

/// Measures how bright one marked source itself looks: camera pixels over the window's rectangle (sky, blinds,
/// street) or around the lamp, skipping pixels where something stands in front of it. Kept as a log histogram.
private struct SourceProbe {
    let id: UUID
    let isLamp: Bool
    let points: [Vec3]
    var histogram = [Int32](repeating: 0, count: 250)   // log10(luminance) from −6 to +4, 25 bins per decade
    var count = 0

    init(source: LightSource) {
        id = source.id
        isLamp = source.kind == .lamp
        if source.kind == .lamp {
            points = [source.points[0]]
        } else if let w = source.windowPlane {
            var pts: [Vec3] = []
            for i in 0..<6 {
                for j in 0..<6 {
                    let u = ((Float(i) + 0.5) / 6 * 2 - 1) * 0.9
                    let v = ((Float(j) + 0.5) / 6 * 2 - 1) * 0.9
                    pts.append(w.center + w.axis * (u * w.halfWidth) + Vec3(0, v * w.halfHeight, 0))
                }
            }
            points = pts
        } else {
            points = []
        }
    }

    mutating func add(_ luminance: Float) {
        let b = Int(((log10(max(luminance, 1e-7)) + 6) * 25).rounded(.down))
        histogram[min(max(b, 0), histogram.count - 1)] += 1
        count += 1
    }

    func percentile(_ q: Float) -> Float? {
        guard count >= 20 else { return nil }
        let target = Int32(Float(count) * q)
        var acc: Int32 = 0
        for (i, n) in histogram.enumerated() {
            acc += n
            if acc > target { return Float(pow(10.0, Double((Float(i) + 0.5) / 25 - 6))) }
        }
        return nil
    }
}

/// Turns the frames of a room scan into surface cells: every high-confidence LiDAR pixel becomes a world point,
/// coloured by the camera pixel under it, linearised and divided by the frame's exposure.
final class CaptureProcessor {
    private let queue = DispatchQueue(label: "lumen.capture", qos: .userInitiated)
    private var accumulator: SurfaceAccumulator
    private var probes: [SourceProbe]
    private var framesProcessed = 0
    private var exifFrames = 0
    private let lock = NSLock()
    private var pending = 0
    /// Depth pixels are visited with this stride (256×192 map → 128×96 samples per frame).
    let depthStride = 2
    /// Frames waiting in the queue hold camera buffers from ARKit's pool: never keep more than this.
    let maxPending = 2

    init(cellSize: Float, sources: [LightSource]) {
        accumulator = SurfaceAccumulator(cellSize: cellSize)
        probes = sources.map(SourceProbe.init(source:))
    }

    /// Whether another frame can be queued now (the frame is dropped otherwise).
    var canAccept: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending < maxPending
    }

    func add(_ frame: CaptureFrame) {
        lock.lock(); pending += 1; lock.unlock()
        queue.async {
            self.process(frame)
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
    }

    /// Surface cells scanned so far as dots coloured by the light falling on them (live preview of the scan),
    /// and the scanned area in m².
    func snapshot(whiteBalanceKelvin: Float, completion: @escaping @MainActor (_ points: [MarkerPoint], _ area: Float) -> Void) {
        queue.async {
            let voxels = self.accumulator.voxels(minSamples: 2)
            let lum = voxels.map { Colorimetry.luminance($0.radiance) }
            let sorted = lum.sorted()
            let reference = sorted.isEmpty ? 1 : max(sorted[Int(Float(sorted.count - 1) * 0.95)], 1e-6)
            var points: [MarkerPoint] = []
            points.reserveCapacity(voxels.count)
            for (v, y) in zip(voxels, lum) {
                let k = Colorimetry.kelvin(ofLinearRGB: v.radiance, whiteBalanceKelvin: whiteBalanceKelvin)
                let c = Colorimetry.displayColor(kelvin: k)
                let alpha = min(max(y / reference, 0.15), 1)
                points.append(MarkerPoint(v.position, size: 7, color: SIMD4<Float>(c.x, c.y, c.z, alpha)))
            }
            let area = Float(voxels.count) * self.accumulator.cellSize * self.accumulator.cellSize
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(points, area) } }
        }
    }

    /// Calls `completion` on the main queue once every queued frame has been processed.
    func finish(completion: @escaping @MainActor (CaptureResult) -> Void) {
        queue.async {
            var sourceLuminance: [UUID: Float] = [:]
            for probe in self.probes {
                if let p90 = probe.percentile(0.9) { sourceLuminance[probe.id] = p90 }
            }
            let result = CaptureResult(voxels: self.accumulator.voxels(minSamples: 2),
                                       frames: self.framesProcessed, exifFrames: self.exifFrames,
                                       sourceLuminance: sourceLuminance)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    private func process(_ f: CaptureFrame) {
        let image = f.image, depth = f.depth
        CVPixelBufferLockBaseAddress(image, .readOnly)
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        if let c = f.confidence { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            if let c = f.confidence { CVPixelBufferUnlockBaseAddress(c, .readOnly) }
        }
        guard CVPixelBufferGetPlaneCount(image) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(image, 1),
              let dBase = CVPixelBufferGetBaseAddress(depth) else { return }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let imgW = CVPixelBufferGetWidthOfPlane(image, 0), imgH = CVPixelBufferGetHeightOfPlane(image, 0)
        let dW = CVPixelBufferGetWidth(depth), dH = CVPixelBufferGetHeight(depth)
        let dStride = CVPixelBufferGetBytesPerRow(depth)
        var confBase: UnsafeMutableRawPointer?
        var confStride = 0
        if let c = f.confidence, CVPixelBufferGetWidth(c) == dW, CVPixelBufferGetHeight(c) == dH {
            confBase = CVPixelBufferGetBaseAddress(c)
            confStride = CVPixelBufferGetBytesPerRow(c)
        }
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let cPtr = cBase.assumingMemoryBound(to: UInt8.self)
        let scale = max(f.exposureScale, 1e-6)
        let sx = Float(imgW) / Float(dW), sy = Float(imgH) / Float(dH)

        var y = 0
        while y < dH {
            let dRow = dBase.advanced(by: y * dStride).assumingMemoryBound(to: Float32.self)
            let cRow = confBase?.advanced(by: y * confStride).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < dW {
                defer { x += depthStride }
                if let cRow, cRow[x] < 2 { continue }            // high confidence only
                let d = dRow[x]
                guard d.isFinite, d > 0.15, d < 6 else { continue }
                let u = (Float(x) + 0.5) * sx, v = (Float(y) + 0.5) * sy
                let ui = min(Int(u), imgW - 1), vi = min(Int(v), imgH - 1)
                let luma = yPtr[vi * yStride + ui]
                let cIndex = (vi / 2) * cStride + (ui / 2) * 2
                let rgb = Colorimetry.rgb(y: luma, cb: cPtr[cIndex], cr: cPtr[cIndex + 1])
                let clipped = luma >= 250 || rgb.x >= 0.995 || rgb.y >= 0.995 || rgb.z >= 0.995
                let linear = Vec3(Colorimetry.linearize(rgb.x), Colorimetry.linearize(rgb.y), Colorimetry.linearize(rgb.z))
                let world = f.geometry.unproject(pixel: SIMD2<Float>(u, v), depth: d)
                accumulator.add(position: world, radiance: linear / scale, clipped: clipped)
            }
            y += depthStride
        }

        // The sources themselves.
        for p in probes.indices {
            var samples: [(pixel: SIMD2<Float>, depth: Float)] = []
            if probes[p].isLamp {
                guard let hit = f.geometry.project(world: probes[p].points[0]) else { continue }
                let r = f.geometry.fx * 0.06 / hit.depth          // a 6 cm disc around the marked point
                for dy in -2...2 {
                    for dx in -2...2 where dx * dx + dy * dy <= 4 {
                        samples.append((hit.pixel + SIMD2<Float>(Float(dx), Float(dy)) * (r / 2), hit.depth))
                    }
                }
            } else {
                for w in probes[p].points {
                    if let hit = f.geometry.project(world: w) { samples.append((hit.pixel, hit.depth)) }
                }
            }
            for sample in samples {
                let px = sample.pixel
                guard px.x >= 0, px.y >= 0, px.x < Float(imgW), px.y < Float(imgH) else { continue }
                // Something stands in front of the source (a plant, a chair back): skip this pixel.
                let dx = min(Int(px.x / sx), dW - 1), dy = min(Int(px.y / sy), dH - 1)
                let front = dBase.advanced(by: dy * dStride).assumingMemoryBound(to: Float32.self)[dx]
                if front.isFinite, front > 0.1, front < sample.depth - 0.3 { continue }
                let ui = Int(px.x), vi = Int(px.y)
                let cIndex = (vi / 2) * cStride + (ui / 2) * 2
                let rgb = Colorimetry.rgb(y: yPtr[vi * yStride + ui], cb: cPtr[cIndex], cr: cPtr[cIndex + 1])
                let linear = Vec3(Colorimetry.linearize(rgb.x), Colorimetry.linearize(rgb.y), Colorimetry.linearize(rgb.z))
                probes[p].add(Colorimetry.luminance(linear) / scale)
            }
        }
        framesProcessed += 1
        if f.exposureFromExif { exifFrames += 1 }
    }
}

/// Surface points seen while finding a room (geometry only, any light), on a 5 cm grid, with the camera
/// position each point was seen from (for the line-of-sight check of the registration).
final class GeometryProbe {
    private let queue = DispatchQueue(label: "lumen.probe", qos: .userInitiated)
    private var cells: [Int64: (sum: Vec3, eye: Vec3, n: Float)] = [:]
    private let lock = NSLock()
    private var pending = 0
    private var count = 0
    private let cell: Float = 0.05

    /// Whether another frame can be queued now (it holds an ARKit depth buffer until processed).
    var canAccept: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending < 1
    }

    /// Number of 5 cm cells seen so far.
    var cellCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func add(_ frame: ARFrame) {
        guard let depth = frame.sceneDepth?.depthMap else { return }
        let confidence = frame.sceneDepth?.confidenceMap
        let geometry = CameraGeometry(camera: frame.camera)
        let t = frame.camera.transform.columns.3
        let eye = Vec3(t.x, t.y, t.z)
        let imageSize = frame.camera.imageResolution
        lock.lock(); pending += 1; lock.unlock()
        queue.async {
            self.process(depth: depth, confidence: confidence, geometry: geometry, imageSize: imageSize, eye: eye)
            self.lock.lock(); self.pending -= 1; self.count = self.cells.count; self.lock.unlock()
        }
    }

    /// Points and camera positions seen so far, delivered on the main queue.
    func snapshot(completion: @escaping @MainActor (_ points: [Vec3], _ eyes: [Vec3]) -> Void) {
        queue.async {
            var points: [Vec3] = [], eyes: [Vec3] = []
            points.reserveCapacity(self.cells.count)
            eyes.reserveCapacity(self.cells.count)
            for c in self.cells.values {
                points.append(c.sum / c.n)
                eyes.append(c.eye / c.n)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(points, eyes) } }
        }
    }

    private static func key(_ i: Int, _ j: Int, _ k: Int) -> Int64 {
        let o = 1 << 20
        return (Int64(i + o) << 42) | (Int64(j + o) << 21) | Int64(k + o)
    }

    private func process(depth: CVPixelBuffer, confidence: CVPixelBuffer?, geometry: CameraGeometry,
                         imageSize: CGSize, eye: Vec3) {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        }
        guard let dBase = CVPixelBufferGetBaseAddress(depth) else { return }
        let dW = CVPixelBufferGetWidth(depth), dH = CVPixelBufferGetHeight(depth)
        let dStride = CVPixelBufferGetBytesPerRow(depth)
        var confBase: UnsafeMutableRawPointer?
        var confStride = 0
        if let c = confidence, CVPixelBufferGetWidth(c) == dW, CVPixelBufferGetHeight(c) == dH {
            confBase = CVPixelBufferGetBaseAddress(c)
            confStride = CVPixelBufferGetBytesPerRow(c)
        }
        let sx = Float(imageSize.width) / Float(dW), sy = Float(imageSize.height) / Float(dH)
        let stride = 4                                          // 64 × 48 points per frame
        var y = 0
        while y < dH {
            let dRow = dBase.advanced(by: y * dStride).assumingMemoryBound(to: Float32.self)
            let cRow = confBase?.advanced(by: y * confStride).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < dW {
                defer { x += stride }
                if let cRow, cRow[x] < 2 { continue }
                let d = dRow[x]
                guard d.isFinite, d > 0.3, d < 5 else { continue }
                let p = geometry.unproject(pixel: SIMD2<Float>((Float(x) + 0.5) * sx, (Float(y) + 0.5) * sy), depth: d)
                let key = Self.key(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)),
                                   Int((p.z / cell).rounded(.down)))
                var c = cells[key] ?? (.zero, .zero, 0)
                c.sum += p
                c.eye += eye
                c.n += 1
                cells[key] = c
            }
            y += stride
        }
    }
}
