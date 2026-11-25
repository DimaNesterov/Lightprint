import ARKit
import simd

/// Pinhole camera model of one ARFrame, in the captured image's native (landscape-right)
/// orientation: pixel x to the right, y down, origin top-left.
///
/// ARKit camera space: +x right, +y up, −z forward. A pixel (u, v) with depth d (distance from
/// the camera plane, as in ARDepthData) maps to
///     P_cam = ((u − cx)/fx · d, −(v − cy)/fy · d, −d)
///     P_world = T_cam · P_cam
struct CameraGeometry {
    let intrinsics: simd_float3x3
    let cameraToWorld: simd_float4x4
    let worldToCamera: simd_float4x4
    let imageSize: CGSize

    init(camera: ARCamera) {
        intrinsics = camera.intrinsics
        cameraToWorld = camera.transform
        worldToCamera = camera.transform.inverse
        imageSize = camera.imageResolution
    }

    var fx: Float { intrinsics[0][0] }
    var fy: Float { intrinsics[1][1] }
    var cx: Float { intrinsics[2][0] }
    var cy: Float { intrinsics[2][1] }

    var width: Float { Float(imageSize.width) }
    var height: Float { Float(imageSize.height) }

    func unproject(pixel: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
        let x = (pixel.x - cx) / fx * depth
        let y = -(pixel.y - cy) / fy * depth
        let p = cameraToWorld * SIMD4<Float>(x, y, -depth, 1)
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    /// World point → image pixel and depth; nil if the point is behind or too close to the camera.
    func project(world: SIMD3<Float>) -> (pixel: SIMD2<Float>, depth: Float)? {
        let c = worldToCamera * SIMD4<Float>(world.x, world.y, world.z, 1)
        let d = -c.z
        guard d > 0.05 else { return nil }
        let u = cx + fx * c.x / d
        let v = cy - fy * c.y / d
        return (SIMD2<Float>(u, v), d)
    }

    func contains(_ pixel: SIMD2<Float>, margin: Float = 0) -> Bool {
        pixel.x >= margin && pixel.y >= margin && pixel.x < width - margin && pixel.y < height - margin
    }

    /// Converts a point in the ARView (portrait UI) to a captured-image pixel.
    static func imagePixel(forViewPoint point: CGPoint, viewSize: CGSize, frame: ARFrame,
                           orientation: UIInterfaceOrientation = .portrait) -> SIMD2<Float> {
        let toImage = frame.displayTransform(for: orientation, viewportSize: viewSize).inverted()
        let normalizedView = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)
        let normalizedImage = normalizedView.applying(toImage)
        let size = frame.camera.imageResolution
        return SIMD2<Float>(Float(normalizedImage.x * size.width), Float(normalizedImage.y * size.height))
    }
}
