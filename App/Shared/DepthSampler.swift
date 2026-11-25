import CoreVideo
import simd

/// LiDAR depth map of one frame, locked once for many lookups (256×192 on current devices,
/// aligned with the captured image).
final class DepthFrame {
    private let depthBuffer: CVPixelBuffer
    private let confidenceBuffer: CVPixelBuffer?
    private let depthBase: UnsafeMutableRawPointer
    private let depthStride: Int
    private let confidenceBase: UnsafeMutableRawPointer?
    private let confidenceStride: Int
    let width: Int
    let height: Int
    let imageSize: CGSize

    init?(depth: CVPixelBuffer?, confidence: CVPixelBuffer?, imageSize: CGSize) {
        guard let depth else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        guard let base = CVPixelBufferGetBaseAddress(depth) else {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            return nil
        }
        depthBuffer = depth
        depthBase = base
        depthStride = CVPixelBufferGetBytesPerRow(depth)
        width = CVPixelBufferGetWidth(depth)
        height = CVPixelBufferGetHeight(depth)
        self.imageSize = imageSize

        if let confidence, CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confidenceBuffer = confidence
            confidenceBase = CVPixelBufferGetBaseAddress(confidence)
            confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        } else {
            confidenceBuffer = nil
            confidenceBase = nil
            confidenceStride = 0
        }
    }

    deinit {
        CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)
        if let confidenceBuffer { CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly) }
    }

    /// Median depth in a (2r+1)² window around a captured-image pixel. Returns nil if too few pixels
    /// have at least `minConfidence`, or if the window straddles a depth edge (object silhouette).
    func depth(atImagePixel pixel: SIMD2<Float>, radius: Int = 1, minConfidence: UInt8 = 1,
               maxSpread: Float = 0.08) -> Float? {
        let px = Int((pixel.x / Float(imageSize.width)) * Float(width))
        let py = Int((pixel.y / Float(imageSize.height)) * Float(height))
        guard px >= 0, py >= 0, px < width, py < height else { return nil }

        var values: [Float] = []
        values.reserveCapacity((2 * radius + 1) * (2 * radius + 1))
        for y in max(0, py - radius)...min(height - 1, py + radius) {
            let row = depthBase.advanced(by: y * depthStride).assumingMemoryBound(to: Float32.self)
            let confRow = confidenceBase?.advanced(by: y * confidenceStride).assumingMemoryBound(to: UInt8.self)
            for x in max(0, px - radius)...min(width - 1, px + radius) {
                if let confRow, confRow[x] < minConfidence { continue }
                let d = row[x]
                if d.isFinite, d > 0.1, d < 6.0 { values.append(d) }
            }
        }
        let window = (2 * radius + 1) * (2 * radius + 1)
        guard values.count >= max(2, (window + 1) / 2) else { return nil }
        values.sort()
        let median = values[values.count / 2]
        if values.count >= 5 {
            let lo = values[values.count / 5]
            let hi = values[(values.count * 4) / 5]
            guard hi - lo <= maxSpread else { return nil }
        } else if let first = values.first, let last = values.last, last - first > maxSpread {
            return nil
        }
        return median
    }

    /// Depth of the nearest surface around a pixel (lower quantile of valid depths in a (2r+1)² window).
    /// Meant for taps on corners and edges (a window corner: frame/wall in front, glass or street behind).
    func nearDepth(atImagePixel pixel: SIMD2<Float>, radius: Int = 3, quantile: Float = 0.25) -> Float? {
        let px = Int((pixel.x / Float(imageSize.width)) * Float(width))
        let py = Int((pixel.y / Float(imageSize.height)) * Float(height))
        guard px >= 0, py >= 0, px < width, py < height else { return nil }
        var values: [Float] = []
        for y in max(0, py - radius)...min(height - 1, py + radius) {
            let row = depthBase.advanced(by: y * depthStride).assumingMemoryBound(to: Float32.self)
            let confRow = confidenceBase?.advanced(by: y * confidenceStride).assumingMemoryBound(to: UInt8.self)
            for x in max(0, px - radius)...min(width - 1, px + radius) {
                if let confRow, confRow[x] < 1 { continue }
                let d = row[x]
                if d.isFinite, d > 0.1, d < 6.0 { values.append(d) }
            }
        }
        guard values.count >= 4 else { return nil }
        values.sort()
        return values[min(values.count - 1, Int(Float(values.count - 1) * quantile))]
    }
}
