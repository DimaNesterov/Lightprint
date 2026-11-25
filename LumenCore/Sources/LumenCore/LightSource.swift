import Foundation

/// A light source marked by the user: a lamp (one point) or a window (two diagonal corners).
/// World space is gravity aligned (ARKit): +y is up.
public struct LightSource: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case lamp, window }

    public let id: UUID
    public var kind: Kind
    /// Lamp: [position]. Window: [bottom-left, top-right] as seen from inside the room (see `canonicalWindowCorners`).
    public var points: [Vec3]

    public init(id: UUID = UUID(), kind: Kind, points: [Vec3]) {
        self.id = id
        self.kind = kind
        self.points = points
    }

    /// A window from two opposite corners (either diagonal), seen from `viewer` standing inside the room.
    public static func window(corner p: Vec3, _ q: Vec3, viewer: Vec3) -> LightSource {
        LightSource(kind: .window, points: canonicalWindowCorners(p, q, viewer: viewer))
    }

    /// Two opposite corners of a vertical rectangle → [bottom-left, top-right] as seen from `viewer`.
    /// Both diagonals describe the same rectangle, so the result does not depend on which one was tapped.
    public static func canonicalWindowCorners(_ p: Vec3, _ q: Vec3, viewer: Vec3) -> [Vec3] {
        let y0 = min(p.y, q.y), y1 = max(p.y, q.y)
        var h = q - p
        h.y = 0
        let mid = (p + q) * 0.5
        var normal = h.normalized(or: Vec3(1, 0, 0)).cross(Vec3(0, 1, 0))
        if normal.dot(mid - viewer) < 0 { normal = -normal }        // looking from the viewer into the window
        let right = normal.cross(Vec3(0, 1, 0))
        let (left, rightEnd) = p.dot(right) <= q.dot(right) ? (p, q) : (q, p)
        return [Vec3(left.x, y0, left.z), Vec3(rightEnd.x, y1, rightEnd.z)]
    }

    public var center: Vec3 {
        kind == .lamp ? points[0] : (points[0] + points[1]) * 0.5
    }

    /// Geometry of a window's rectangle.
    public struct WindowPlane: Sendable {
        public var center: Vec3
        /// Horizontal unit axis along the window (from points[0] towards points[1]).
        public var axis: Vec3
        /// Horizontal unit normal (sign arbitrary).
        public var normal: Vec3
        public var halfWidth: Float
        public var halfHeight: Float
    }

    /// Nil for lamps and degenerate windows.
    public var windowPlane: WindowPlane? {
        guard kind == .window, points.count >= 2 else { return nil }
        let a = points[0], b = points[1]
        var h = b - a
        h.y = 0
        let width = h.length
        guard width > 1e-4 else { return nil }
        let axis = h / width
        return WindowPlane(center: (a + b) * 0.5, axis: axis, normal: axis.cross(Vec3(0, 1, 0)),
                           halfWidth: width * 0.5, halfHeight: abs(b.y - a.y) * 0.5)
    }

    /// The window's four corners: [bottom-left, bottom-right, top-right, top-left] for canonical points.
    public var windowCorners: [Vec3] {
        guard kind == .window, points.count >= 2 else { return [] }
        let a = points[0], b = points[1]
        return [a, Vec3(b.x, a.y, b.z), b, Vec3(a.x, b.y, a.z)]
    }

    /// Horizontal unit normal of a window's plane (sign arbitrary); nil for lamps and degenerate windows.
    public var windowNormal: Vec3? { windowPlane?.normal }

    /// Emitting area, m² (lamps count as a small fixed area).
    public var area: Float {
        guard let w = windowPlane else { return kind == .lamp ? 0.05 : 0.01 }
        return max(4 * w.halfWidth * w.halfHeight, 0.01)
    }

    /// Points spread over the source (lamp: its position; window: an n×n grid).
    public func samplePoints(gridSize n: Int = 3) -> [Vec3] {
        guard let w = windowPlane else { return [points[0]] }
        var out: [Vec3] = []
        for i in 0..<n {
            for j in 0..<n {
                let u = (Float(i) + 0.5) / Float(n) * 2 - 1
                let v = (Float(j) + 0.5) / Float(n) * 2 - 1
                out.append(w.center + w.axis * (u * w.halfWidth) + Vec3(0, w.halfHeight * v, 0))
            }
        }
        return out
    }

    /// Whether `p` belongs to the source (used to measure how bright the source itself is).
    public func contains(_ p: Vec3, margin: Float = 0.08) -> Bool {
        switch kind {
        case .lamp:
            return p.distance(to: points[0]) < 0.15 + margin
        case .window:
            guard let w = windowPlane else { return false }
            let r = p - w.center
            return abs(r.dot(w.axis)) < w.halfWidth + margin
                && abs(r.y) < w.halfHeight + margin
                && abs(r.dot(w.normal)) < margin
        }
    }

    public func transformed(by t: RigidTransform) -> LightSource {
        LightSource(id: id, kind: kind, points: points.map { t.apply($0) })
    }
}
