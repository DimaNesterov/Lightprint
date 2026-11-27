import Foundation

// Finding a room scanned before from LiDAR geometry alone. Light does not matter: walls and furniture stay
// where they are from morning to night, unlike the visual features ARKit's own relocalisation relies on.
// Both AR sessions are gravity aligned, so the unknowns are a turn about +y and a shift.

/// A turn about +y followed by a shift: maps points of the current session into the room scanned before.
public struct YawPose: Equatable, Sendable {
    public var yaw: Float
    public var translation: Vec3

    public init(yaw: Float, translation: Vec3) {
        self.yaw = yaw
        self.translation = translation
    }

    @inlinable public static func rotate(_ p: Vec3, by yaw: Float) -> Vec3 {
        let c = cos(yaw), s = sin(yaw)
        return Vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z)
    }

    @inlinable public func apply(_ p: Vec3) -> Vec3 { YawPose.rotate(p, by: yaw) + translation }

    public var transform: RigidTransform {
        let c = cos(yaw), s = sin(yaw)
        return RigidTransform(c0: Vec3(c, 0, -s), c1: Vec3(0, 1, 0), c2: Vec3(s, 0, c), translation: translation)
    }
}

/// Outcome of one registration attempt.
public struct RegistrationResult: Sendable {
    /// Maps points of the current session into the room.
    public var pose: YawPose
    /// match − 2 × blocked.
    public var score: Float
    /// Share of the seen walls and furniture that land on the room's surfaces.
    public var match: Float
    /// Share of lines of sight (camera → seen point) that would pass through the room's surfaces.
    public var blocked: Float
    /// Score minus the score of the best clearly different pose (a symmetric room has a small margin).
    public var margin: Float

    public var isConfident: Bool { score >= 0.6 && match >= 0.8 && margin >= 0.15 }

    /// Whether two results describe the same pose.
    public func agrees(with other: RegistrationResult) -> Bool {
        let dyaw = abs(remainder(pose.yaw - other.pose.yaw, 2 * Float.pi))
        return dyaw < 2 * Float.pi / 180 && pose.translation.distance(to: other.pose.translation) < 0.05
    }
}

/// Uniform grid of point indices for neighbour searches.
struct SpatialHash: Sendable {
    let cell: Float
    private var cells: [Int64: [Int32]] = [:]

    init(points: [Vec3], cell: Float) {
        self.cell = cell
        for (i, p) in points.enumerated() {
            cells[key(p), default: []].append(Int32(i))
        }
    }

    private func index(_ v: Float) -> Int { Int((v / cell).rounded(.down)) }
    private func key(_ p: Vec3) -> Int64 { SurfaceAccumulator.key(index(p.x), index(p.y), index(p.z)) }

    /// Nearest point within `maxDistance` (searched in the 27 cells around `q`, so keep it ≤ the cell size).
    func nearest(_ q: Vec3, in points: [Vec3], maxDistance: Float) -> (index: Int, distance: Float)? {
        let i = index(q.x), j = index(q.y), k = index(q.z)
        var best = -1
        var bestD2 = maxDistance * maxDistance
        for di in -1...1 { for dj in -1...1 { for dk in -1...1 {
            guard let list = cells[SurfaceAccumulator.key(i + di, j + dj, k + dk)] else { continue }
            for n in list {
                let d2 = (points[Int(n)] - q).lengthSquared
                if d2 < bestD2 { bestD2 = d2; best = Int(n) }
            }
        }}}
        return best >= 0 ? (best, bestD2.squareRoot()) : nil
    }

    func anyWithin(_ q: Vec3, in points: [Vec3], radius: Float) -> Bool {
        let i = index(q.x), j = index(q.y), k = index(q.z)
        let r2 = radius * radius
        for di in -1...1 { for dj in -1...1 { for dk in -1...1 {
            guard let list = cells[SurfaceAccumulator.key(i + di, j + dj, k + dk)] else { continue }
            for n in list where (points[Int(n)] - q).lengthSquared < r2 { return true }
        }}}
        return false
    }

    func neighbours(_ q: Vec3, in points: [Vec3], radius: Float) -> [Int] {
        let i = index(q.x), j = index(q.y), k = index(q.z)
        let r2 = radius * radius
        var out: [Int] = []
        for di in -1...1 { for dj in -1...1 { for dk in -1...1 {
            guard let list = cells[SurfaceAccumulator.key(i + di, j + dj, k + dk)] else { continue }
            for n in list where (points[Int(n)] - q).lengthSquared < r2 { out.append(Int(n)) }
        }}}
        return out
    }
}

/// The room as scanned before: surface points with normals, its floor height, and its walls and furniture
/// in 20 cm height layers on a 10 cm top-down grid (for the coarse search).
public final class RoomReference: Sendable {
    let points: [Vec3]
    let normals: [Vec3]
    let hash: SpatialHash
    let floor: Float
    let layers: [Int: [SIMD2<Int32>]]
    let cellMin: SIMD2<Int32>
    let cellMax: SIMD2<Int32>

    public var pointCount: Int { points.count }

    /// `positions`: surface cells of earlier scans, in the room's coordinates.
    public init?(positions: [Vec3]) {
        let pts = RoomRegistration.downsample(positions, cell: 0.05)
        guard pts.count >= 500 else { return nil }
        points = pts
        let hash = SpatialHash(points: pts, cell: 0.15)
        self.hash = hash
        let floorY = RoomRegistration.floorHeight(pts)
        floor = floorY
        normals = pts.map { RoomRegistration.normal(at: $0, points: pts, hash: hash) }
        var layers: [Int: [SIMD2<Int32>]] = [:]
        var seen = Set<Int64>()
        var lo = SIMD2<Int32>(Int32.max, Int32.max), hi = SIMD2<Int32>(Int32.min, Int32.min)
        for p in pts where p.y > floorY + 0.12 && p.y < floorY + 2.1 {
            let c = SIMD2<Int32>(Int32((p.x / 0.1).rounded(.down)), Int32((p.z / 0.1).rounded(.down)))
            let layer = Int(((p.y - floorY) / 0.2).rounded(.down))
            if seen.insert(SurfaceAccumulator.key(Int(c.x), layer, Int(c.y))).inserted {
                layers[layer, default: []].append(c)
                lo = pointwiseMin(lo, c)
                hi = pointwiseMax(hi, c)
            }
        }
        guard !layers.isEmpty else { return nil }
        self.layers = layers
        cellMin = lo
        cellMax = hi
    }
}

public enum RoomRegistration {
    /// Finds the pose of the current session in the reference room.
    /// - Parameters:
    ///   - probe: surface points seen in the current session (about 5 cm apart).
    ///   - eyes: for every probe point, where the camera was when it saw it.
    public static func register(reference ref: RoomReference, probe: [Vec3], eyes: [Vec3]) -> RegistrationResult? {
        guard probe.count >= 500, probe.count == eyes.count else { return nil }
        let floorP = floorHeight(probe)
        let dy = ref.floor - floorP
        let structure = probe.indices.filter { probe[$0].y > floorP + 0.12 && probe[$0].y < floorP + 2.1 }
        guard structure.count >= 200 else { return nil }

        let hyps = hypotheses(ref, structure.map { probe[$0] }, floorP: floorP)
        let icpPoints = thin(probe, to: 2500)
        let scorePoints = thin(structure.map { probe[$0] }, to: 2500)
        let rayIndices = thin(Array(probe.indices), to: 500)
        let rays = rayIndices.map { (point: probe[$0], eye: eyes[$0]) }

        var tried: [YawPose] = []
        var results: [(score: Float, match: Float, blocked: Float, pose: YawPose)] = []
        for h in hyps {
            if tried.count >= 20 { break }
            let start = YawPose(yaw: h.yaw, translation: Vec3(h.x, dy, h.z))
            if tried.contains(where: { different($0, start) == false }) { continue }
            tried.append(start)
            var pose = icpPointToPoint(ref, icpPoints, start)
            pose = icpPointToPlane(ref, icpPoints, pose)
            let s = score(ref, scorePoints, rays, pose)
            results.append((s.match - 2 * s.blocked, s.match, s.blocked, pose))
        }
        results.sort { $0.score > $1.score }
        guard let best = results.first else { return nil }
        let other = results.dropFirst().first { different($0.pose, best.pose) }
        return RegistrationResult(pose: best.pose, score: best.score, match: best.match, blocked: best.blocked,
                                  margin: best.score - (other?.score ?? -1))
    }

    // MARK: Coarse search

    struct Hypothesis {
        var score: Float
        var yaw: Float
        var x: Float
        var z: Float
    }

    /// For every 3° of yaw, all (room cell − seen cell) shifts within the same height layer vote; the three
    /// strongest local peaks of each yaw become hypotheses.
    static func hypotheses(_ ref: RoomReference, _ structure: [Vec3], floorP: Float) -> [Hypothesis] {
        let cell: Float = 0.1
        var out: [Hypothesis] = []
        for step in 0..<120 {
            let yaw = Float(step) * 3 * .pi / 180
            let c = cos(yaw), s = sin(yaw)
            var byLayer: [Int: [SIMD2<Int32>]] = [:]
            var seen = Set<Int64>()
            var lo = SIMD2<Int32>(Int32.max, Int32.max), hi = SIMD2<Int32>(Int32.min, Int32.min)
            for p in structure {
                let q = SIMD2<Int32>(Int32(((c * p.x + s * p.z) / cell).rounded(.down)),
                                     Int32(((-s * p.x + c * p.z) / cell).rounded(.down)))
                let layer = Int(((p.y - floorP) / 0.2).rounded(.down))
                guard ref.layers[layer] != nil else { continue }
                if seen.insert(SurfaceAccumulator.key(Int(q.x), layer, Int(q.y))).inserted {
                    byLayer[layer, default: []].append(q)
                    lo = pointwiseMin(lo, q)
                    hi = pointwiseMax(hi, q)
                }
            }
            let count = seen.count
            guard count > 0 else { continue }
            let shiftLo = ref.cellMin &- hi, shiftHi = ref.cellMax &- lo
            let w = Int(shiftHi.x - shiftLo.x) + 1, d = Int(shiftHi.y - shiftLo.y) + 1
            guard w > 0, d > 0, w * d < 4_000_000 else { continue }
            var acc = [Int32](repeating: 0, count: w * d)
            for (layer, qs) in byLayer {
                guard let rs = ref.layers[layer] else { continue }
                for r in rs {
                    for q in qs {
                        let i = Int(r.x - q.x - shiftLo.x), k = Int(r.y - q.y - shiftLo.y)
                        acc[i * d + k] += 1
                    }
                }
            }
            // 3×3 box sums, then the three strongest separated peaks.
            var box = [Int32](repeating: 0, count: w * d)
            for i in 0..<w {
                for k in 0..<d {
                    var sum: Int32 = 0
                    for di in max(i - 1, 0)...min(i + 1, w - 1) {
                        for dk in max(k - 1, 0)...min(k + 1, d - 1) { sum += acc[di * d + dk] }
                    }
                    box[i * d + k] = sum
                }
            }
            for _ in 0..<3 {
                var bestIndex = 0
                for n in 1..<box.count where box[n] > box[bestIndex] { bestIndex = n }
                let i = bestIndex / d, k = bestIndex % d
                guard box[bestIndex] > 0 else { break }
                out.append(Hypothesis(score: Float(box[bestIndex]) / Float(count), yaw: yaw,
                                      x: (Float(i) + Float(shiftLo.x) + 0.5) * cell,
                                      z: (Float(k) + Float(shiftLo.y) + 0.5) * cell))
                for di in max(i - 3, 0)...min(i + 3, w - 1) {
                    for dk in max(k - 3, 0)...min(k + 3, d - 1) { box[di * d + dk] = 0 }
                }
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    // MARK: Refinement

    /// Point-to-point ICP for yaw and shift; the last iterations ignore the 30% worst matches, so furniture that
    /// moved since the earlier scans does not pull the pose.
    static func icpPointToPoint(_ ref: RoomReference, _ probe: [Vec3], _ start: YawPose) -> YawPose {
        var pose = start
        for iteration in 0..<30 {
            let maxDistance = max(0.3 * pow(0.8, Float(iteration)), 0.05)
            var pairs: [(a: Vec3, b: Vec3, d: Float)] = []
            pairs.reserveCapacity(probe.count)
            for p in probe {
                if let hit = ref.hash.nearest(pose.apply(p), in: ref.points, maxDistance: maxDistance) {
                    pairs.append((p, ref.points[hit.index], hit.distance))
                }
            }
            guard pairs.count >= 30 else { break }
            if iteration >= 12 {
                let cut = percentile(pairs.map(\.d), 0.7)
                pairs = pairs.filter { $0.d <= cut }
            }
            var am = Vec3.zero, bm = Vec3.zero
            for pair in pairs { am += pair.a; bm += pair.b }
            am /= Float(pairs.count)
            bm /= Float(pairs.count)
            var sumCos: Float = 0, sumSin: Float = 0
            for pair in pairs {
                let a = pair.a - am, b = pair.b - bm
                sumCos += b.x * a.x + b.z * a.z
                sumSin += b.x * a.z - b.z * a.x
            }
            let yaw = atan2(sumSin, sumCos)
            pose = YawPose(yaw: yaw, translation: bm - YawPose.rotate(am, by: yaw))
        }
        return pose
    }

    /// Point-to-plane refinement (a point may slide along a wall without the point-to-point error changing;
    /// the distance to the wall's plane does not let it).
    static func icpPointToPlane(_ ref: RoomReference, _ probe: [Vec3], _ start: YawPose) -> YawPose {
        var pose = start
        for _ in 0..<12 {
            var rows: [(p: Vec3, n: Vec3, r: Float)] = []
            rows.reserveCapacity(probe.count)
            for q in probe {
                let p = pose.apply(q)
                guard let hit = ref.hash.nearest(p, in: ref.points, maxDistance: 0.08) else { continue }
                let n = ref.normals[hit.index]
                rows.append((p, n, n.dot(p - ref.points[hit.index])))
            }
            guard rows.count >= 30 else { break }
            let cut = percentile(rows.map { abs($0.r) }, 0.75)
            rows = rows.filter { abs($0.r) <= cut }
            var c = Vec3.zero
            for row in rows { c += row.p }
            c /= Float(rows.count)
            // Normal equations for x = (dyaw, dx, dy, dz): J = [n·(p.z − c.z, 0, −(p.x − c.x)), n.x, n.y, n.z].
            var m = [[Float]](repeating: [Float](repeating: 0, count: 4), count: 4)
            var v = [Float](repeating: 0, count: 4)
            for row in rows {
                let dp = Vec3(row.p.z - c.z, 0, -(row.p.x - c.x))
                let j: [Float] = [row.n.dot(dp), row.n.x, row.n.y, row.n.z]
                for a in 0..<4 {
                    v[a] -= j[a] * row.r
                    for b in 0..<4 { m[a][b] += j[a] * j[b] }
                }
            }
            for a in 0..<4 { m[a][a] += 1e-4 }
            guard let x = solve4(m, v) else { break }
            let dyaw = x[0]
            let shifted = YawPose.rotate(pose.translation - c, by: dyaw) + c + Vec3(x[1], x[2], x[3])
            pose = YawPose(yaw: pose.yaw + dyaw, translation: shifted)
            if abs(dyaw) < 1e-5, Vec3(x[1], x[2], x[3]).length < 1e-4 { break }
        }
        return pose
    }

    // MARK: Scoring

    /// match: seen walls/furniture landing on the room's surfaces. blocked: lines of sight that would pass through
    /// the room's surfaces (the camera saw empty space where the room has something).
    static func score(_ ref: RoomReference, _ points: [Vec3], _ rays: [(point: Vec3, eye: Vec3)],
                      _ pose: YawPose) -> (match: Float, blocked: Float) {
        var matched = 0
        for p in points where ref.hash.nearest(pose.apply(p), in: ref.points, maxDistance: 0.06) != nil { matched += 1 }
        var blocked = 0, tested = 0
        for ray in rays {
            let e = pose.apply(ray.eye), x = pose.apply(ray.point)
            let v = x - e
            let length = v.length
            guard length >= 0.8 else { continue }
            tested += 1
            var s: Float = 0.3
            while s < length - 0.25 {
                if ref.hash.anyWithin(e + v * (s / length), in: ref.points, radius: 0.035) {
                    blocked += 1
                    break
                }
                s += 0.05
            }
        }
        return (Float(matched) / Float(max(points.count, 1)), Float(blocked) / Float(max(tested, 1)))
    }

    // MARK: Helpers

    static func different(_ a: YawPose, _ b: YawPose) -> Bool {
        let dyaw = abs(remainder(a.yaw - b.yaw, 2 * Float.pi))
        return dyaw > 8 * Float.pi / 180 || a.translation.distance(to: b.translation) > 0.3
    }

    /// Mean point of every occupied cell.
    public static func downsample(_ points: [Vec3], cell: Float) -> [Vec3] {
        var cells: [Int64: (sum: Vec3, n: Float)] = [:]
        for p in points {
            let key = SurfaceAccumulator.key(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)),
                                             Int((p.z / cell).rounded(.down)))
            var c = cells[key] ?? (.zero, 0)
            c.sum += p
            c.n += 1
            cells[key] = c
        }
        return cells.values.map { $0.sum / $0.n }
    }

    /// Height of the floor: the strongest 5 cm layer in the lower part of the cloud.
    static func floorHeight(_ points: [Vec3]) -> Float {
        let ys = points.map(\.y).sorted()
        let lo = ys[Int(Float(ys.count - 1) * 0.01)], hi = ys[Int(Float(ys.count - 1) * 0.99)]
        let start = lo - 0.1, end = lo + 0.45 * (hi - lo) + 0.1
        let n = max(1, Int(((end - start) / 0.05).rounded(.up)))
        var histogram = [Int](repeating: 0, count: n)
        for y in ys where y >= start && y < end { histogram[min(Int((y - start) / 0.05), n - 1)] += 1 }
        let best = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        return start + Float(best) * 0.05 + 0.025
    }

    /// Surface normal from the neighbours within 10 cm (direction of least spread).
    static func normal(at p: Vec3, points: [Vec3], hash: SpatialHash) -> Vec3 {
        let near = hash.neighbours(p, in: points, radius: 0.1)
        guard near.count >= 5 else { return Vec3(0, 1, 0) }
        var mean = Vec3.zero
        for i in near { mean += points[i] }
        mean /= Float(near.count)
        var a = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
        for i in near {
            let d = points[i] - mean
            let v = [d.x, d.y, d.z]
            for r in 0..<3 { for c in 0..<3 { a[r][c] += v[r] * v[c] } }
        }
        return smallestEigenvector(a)
    }

    /// Jacobi eigen-decomposition of a symmetric 3×3 matrix; returns the eigenvector of the smallest eigenvalue.
    static func smallestEigenvector(_ input: [[Float]]) -> Vec3 {
        var a = input
        var v: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<12 {
            for (p, q) in [(0, 1), (0, 2), (1, 2)] where abs(a[p][q]) > 1e-12 {
                let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<3 {
                    let akp = a[k][p], akq = a[k][q]
                    a[k][p] = c * akp - s * akq
                    a[k][q] = s * akp + c * akq
                }
                for k in 0..<3 {
                    let apk = a[p][k], aqk = a[q][k]
                    a[p][k] = c * apk - s * aqk
                    a[q][k] = s * apk + c * aqk
                }
                for k in 0..<3 {
                    let vkp = v[k][p], vkq = v[k][q]
                    v[k][p] = c * vkp - s * vkq
                    v[k][q] = s * vkp + c * vkq
                }
            }
        }
        let i = [0, 1, 2].min { a[$0][$0] < a[$1][$1] } ?? 0
        return Vec3(v[0][i], v[1][i], v[2][i]).normalized(or: Vec3(0, 1, 0))
    }

    /// Gaussian elimination with partial pivoting for a 4×4 system.
    static func solve4(_ matrix: [[Float]], _ rhs: [Float]) -> [Float]? {
        var m = matrix, b = rhs
        for col in 0..<4 {
            guard let pivot = (col..<4).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-9
            else { return nil }
            m.swapAt(col, pivot)
            b.swapAt(col, pivot)
            for row in (col + 1)..<4 {
                let f = m[row][col] / m[col][col]
                for k in col..<4 { m[row][k] -= f * m[col][k] }
                b[row] -= f * b[col]
            }
        }
        var x = [Float](repeating: 0, count: 4)
        for row in stride(from: 3, through: 0, by: -1) {
            var s = b[row]
            for k in (row + 1)..<4 { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x
    }

    static func percentile(_ values: [Float], _ q: Float) -> Float {
        let s = values.sorted()
        return s[min(s.count - 1, Int(Float(s.count - 1) * q))]
    }

    /// Every n-th element, so that at most `limit` remain (deterministic).
    static func thin<T>(_ items: [T], to limit: Int) -> [T] {
        guard items.count > limit else { return items }
        let step = Float(items.count) / Float(limit)
        return (0..<limit).map { items[Int(Float($0) * step)] }
    }
}
