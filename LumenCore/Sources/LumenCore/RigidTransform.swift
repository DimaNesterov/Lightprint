/// Rotation + translation in 3D, stored as rotation-matrix columns (platform independent, no simd module).
public struct RigidTransform: Equatable, Sendable {
    public var c0: Vec3
    public var c1: Vec3
    public var c2: Vec3
    public var translation: Vec3

    public init(c0: Vec3, c1: Vec3, c2: Vec3, translation: Vec3) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.translation = translation
    }

    public static let identity = RigidTransform(c0: Vec3(1, 0, 0), c1: Vec3(0, 1, 0), c2: Vec3(0, 0, 1),
                                                translation: .zero)

    /// Rotation from a unit quaternion (w, x, y, z) plus translation.
    public init(quaternion q: SIMD4<Float>, translation t: Vec3) {
        let w = q.x, x = q.y, y = q.z, z = q.w
        c0 = Vec3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y))
        c1 = Vec3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x))
        c2 = Vec3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y))
        translation = t
    }

    @inlinable public func rotate(_ v: Vec3) -> Vec3 {
        var r = c0 * v.x
        r += c1 * v.y
        r += c2 * v.z
        return r
    }

    @inlinable public func apply(_ p: Vec3) -> Vec3 {
        rotate(p) + translation
    }

    public var inverse: RigidTransform {
        // Transpose of the rotation: rows become columns.
        let r0 = Vec3(c0.x, c1.x, c2.x)
        let r1 = Vec3(c0.y, c1.y, c2.y)
        let r2 = Vec3(c0.z, c1.z, c2.z)
        let inv = RigidTransform(c0: r0, c1: r1, c2: r2, translation: .zero)
        return RigidTransform(c0: r0, c1: r1, c2: r2, translation: -inv.rotate(translation))
    }

    /// self ∘ other: first `other`, then `self`.
    public func composed(with other: RigidTransform) -> RigidTransform {
        RigidTransform(c0: rotate(other.c0), c1: rotate(other.c1), c2: rotate(other.c2),
                       translation: apply(other.translation))
    }

    public static func translation(_ t: Vec3) -> RigidTransform {
        RigidTransform(c0: Vec3(1, 0, 0), c1: Vec3(0, 1, 0), c2: Vec3(0, 0, 1), translation: t)
    }
}

/// Least-squares rigid alignment (Horn 1987, closed form with unit quaternions) and RANSAC.
public enum RigidFit {
    /// R, t minimising Σ |R·p_i + t − q_i|². Needs ≥ 3 non-collinear points.
    public static func horn(_ p: [Vec3], _ q: [Vec3]) -> RigidTransform? {
        let n = p.count
        guard n >= 3, q.count == n else { return nil }
        var pc = Vec3.zero, qc = Vec3.zero
        for k in 0..<n {
            pc += p[k]
            qc += q[k]
        }
        pc /= Float(n)
        qc /= Float(n)
        // Cross-covariance S = Σ (p − p̄)(q − q̄)ᵀ, accumulated in Double for accuracy.
        var s = [Double](repeating: 0, count: 9)
        for k in 0..<n {
            let a = p[k] - pc, b = q[k] - qc
            let av = [Double(a.x), Double(a.y), Double(a.z)]
            let bv = [Double(b.x), Double(b.y), Double(b.z)]
            for i in 0..<3 {
                for j in 0..<3 { s[i * 3 + j] += av[i] * bv[j] }
            }
        }
        let sxx = s[0], sxy = s[1], sxz = s[2]
        let syx = s[3], syy = s[4], syz = s[5]
        let szx = s[6], szy = s[7], szz = s[8]
        var m: [Double] = [
            sxx + syy + szz, syz - szy, szx - sxz, sxy - syx,
            syz - szy, sxx - syy - szz, sxy + syx, szx + sxz,
            szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy,
            sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz,
        ]
        let (values, vectors) = jacobiEigen4(&m)
        var best = 0
        for k in 1..<4 where values[k] > values[best] { best = k }
        var quat = SIMD4<Float>(Float(vectors[0 * 4 + best]), Float(vectors[1 * 4 + best]),
                                Float(vectors[2 * 4 + best]), Float(vectors[3 * 4 + best]))
        let len = (quat * quat).sum().squareRoot()
        guard len > 1e-9 else { return nil }
        quat /= len
        let rotationOnly = RigidTransform(quaternion: quat, translation: .zero)
        return RigidTransform(quaternion: quat, translation: qc - rotationOnly.rotate(pc))
    }

    /// RANSAC over minimal 3-point samples, then two least-squares refits on the inliers.
    /// `threshold(i)` is the inlier distance for correspondence i (e.g. growing with depth).
    public static func ransac(_ p: [Vec3], _ q: [Vec3], threshold: (Int) -> Float,
                              iterations: Int = 60, seed: UInt64 = 0x9E3779B97F4A7C15)
        -> (transform: RigidTransform, inliers: [Bool])? {
        let n = p.count
        guard n >= 3, q.count == n else { return nil }
        var rng = SplitMix64(seed: seed)
        var bestInliers: [Bool]?
        var bestCount = 0
        for _ in 0..<iterations {
            let i = Int(rng.next() % UInt64(n))
            var j = Int(rng.next() % UInt64(n))
            var k = Int(rng.next() % UInt64(n))
            if j == i { j = (j + 1) % n }
            if k == i || k == j { k = (max(i, j) + 1) % n }
            if k == i || k == j { continue }
            let area = (p[j] - p[i]).cross(p[k] - p[i]).length
            if area < 1e-5 { continue }
            guard let t = horn([p[i], p[j], p[k]], [q[i], q[j], q[k]]) else { continue }
            var count = 0
            var inl = [Bool](repeating: false, count: n)
            for m in 0..<n where t.apply(p[m]).distance(to: q[m]) < threshold(m) {
                inl[m] = true
                count += 1
            }
            if count > bestCount {
                bestCount = count
                bestInliers = inl
                if count * 10 >= n * 9 { break }   // 90 % inliers: good enough, refit below
            }
        }
        guard var inliers = bestInliers, bestCount >= 3 else { return nil }
        var result: RigidTransform?
        for _ in 0..<2 {
            let ps = (0..<n).filter { inliers[$0] }.map { p[$0] }
            let qs = (0..<n).filter { inliers[$0] }.map { q[$0] }
            guard let t = horn(ps, qs) else { break }
            result = t
            inliers = (0..<n).map { t.apply(p[$0]).distance(to: q[$0]) < threshold($0) }
        }
        guard let transform = result, inliers.filter({ $0 }).count >= 3 else { return nil }
        return (transform, inliers)
    }

    /// Cyclic Jacobi eigen-decomposition of a symmetric 4×4 matrix (row-major, modified in place).
    /// Returns eigenvalues and eigenvectors (column k of the row-major 4×4 `vectors`).
    static func jacobiEigen4(_ a: inout [Double]) -> (values: [Double], vectors: [Double]) {
        var v: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        for _ in 0..<50 {
            var off = 0.0
            for p in 0..<4 { for q in 0..<4 where p != q { off += a[p * 4 + q] * a[p * 4 + q] } }
            if off < 1e-22 { break }
            for p in 0..<3 {
                for q in (p + 1)..<4 {
                    let apq = a[p * 4 + q]
                    if abs(apq) < 1e-30 { continue }
                    let theta = (a[q * 4 + q] - a[p * 4 + p]) / (2 * apq)
                    let t = theta == 0 ? 1.0 : (theta > 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    for k in 0..<4 {
                        let akp = a[k * 4 + p], akq = a[k * 4 + q]
                        a[k * 4 + p] = c * akp - s * akq
                        a[k * 4 + q] = s * akp + c * akq
                    }
                    for k in 0..<4 {
                        let apk = a[p * 4 + k], aqk = a[q * 4 + k]
                        a[p * 4 + k] = c * apk - s * aqk
                        a[q * 4 + k] = s * apk + c * aqk
                    }
                    for k in 0..<4 {
                        let vkp = v[k * 4 + p], vkq = v[k * 4 + q]
                        v[k * 4 + p] = c * vkp - s * vkq
                        v[k * 4 + q] = s * vkp + c * vkq
                    }
                }
            }
        }
        return ([a[0], a[5], a[10], a[15]], v)
    }
}

/// Small deterministic PRNG (RANSAC sampling must be reproducible in tests).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
