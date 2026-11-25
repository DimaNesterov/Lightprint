import Foundation

/// Parameters of the visual law. Everything visible follows from these numbers.
public struct LightLaw: Codable, Equatable, Sendable {
    /// Version of the defaults. A law saved with an older version is replaced by the current defaults.
    public static let currentVersion = 2
    public var version: Int = LightLaw.currentVersion
    /// Size of the finest cell of the light volume, metres: at most one splat per finest cell.
    public var cellSize: Float = 0.04
    /// Total number of splats for the whole day: fixes the size of one light quantum.
    public var splatBudget: Int = 60_000
    /// A surface cell counts as directly lit when brighter than `litThreshold` × the capture's median.
    public var litThreshold: Float = 1.5
    /// A marked source emits rays in a moment only if it is itself at least this many times brighter than the
    /// capture's median surface: a dark window at night or a dim screen emits nothing.
    public var sourceThreshold: Float = 4
    /// Energy carried by rays (direct light).
    public var beamGain: Float = 1.0
    /// Ambient energy density relative to the capture's median surface luminance.
    public var ambientGain: Float = 0.3
    /// Angular spacing of rays, degrees: lit surfaces in the same direction from a source share one ray.
    public var rayAngleDegrees: Float = 6
    /// Spacing of rays where they cross a window, metres.
    public var windowRaySpacing: Float = 0.12
    /// Width of a ray relative to the bundle of light it stands for (1 = the whole bundle, rays then merge).
    /// The shape comes from the data: a ray is as wide as the patch it leaves at the source and the patch it
    /// lights, so lamp rays widen and dissolve (density ∝ 1/r²) while parallel sunlight stays a shaft.
    public var rayWidth: Float = 0.3
    /// Within one ray's direction only the first surface (up to this much deeper) is lit; the rest is in shadow.
    public var firstSurfaceDepth: Float = 0.3
    /// Colour scale: reference temperature (neutral) and the mired distance mapped to the palette ends.
    public var referenceKelvin: Float = 5000
    public var spanMired: Float = 90
    /// Max cells along one axis of the volume (the cell grows for very large rooms).
    public var maxCellsPerAxis: Int = 160

    public init() {}

    // Tolerant decoding: missing parameters take their defaults; an older version takes all defaults.
    private enum CodingKeys: String, CodingKey {
        case version, cellSize, splatBudget, litThreshold, sourceThreshold, beamGain, ambientGain, rayAngleDegrees, windowRaySpacing,
             rayWidth, firstSurfaceDepth, referenceKelvin, spanMired, maxCellsPerAxis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LightLaw()
        let stored = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard stored >= LightLaw.currentVersion else {
            self = d
            return
        }
        version = LightLaw.currentVersion
        cellSize = try c.decodeIfPresent(Float.self, forKey: .cellSize) ?? d.cellSize
        splatBudget = try c.decodeIfPresent(Int.self, forKey: .splatBudget) ?? d.splatBudget
        litThreshold = try c.decodeIfPresent(Float.self, forKey: .litThreshold) ?? d.litThreshold
        sourceThreshold = try c.decodeIfPresent(Float.self, forKey: .sourceThreshold) ?? d.sourceThreshold
        beamGain = try c.decodeIfPresent(Float.self, forKey: .beamGain) ?? d.beamGain
        ambientGain = try c.decodeIfPresent(Float.self, forKey: .ambientGain) ?? d.ambientGain
        rayAngleDegrees = try c.decodeIfPresent(Float.self, forKey: .rayAngleDegrees) ?? d.rayAngleDegrees
        windowRaySpacing = try c.decodeIfPresent(Float.self, forKey: .windowRaySpacing) ?? d.windowRaySpacing
        rayWidth = try c.decodeIfPresent(Float.self, forKey: .rayWidth) ?? d.rayWidth
        firstSurfaceDepth = try c.decodeIfPresent(Float.self, forKey: .firstSurfaceDepth) ?? d.firstSurfaceDepth
        referenceKelvin = try c.decodeIfPresent(Float.self, forKey: .referenceKelvin) ?? d.referenceKelvin
        spanMired = try c.decodeIfPresent(Float.self, forKey: .spanMired) ?? d.spanMired
        maxCellsPerAxis = try c.decodeIfPresent(Int.self, forKey: .maxCellsPerAxis) ?? d.maxCellsPerAxis
    }
}

/// One rendered quantum of light.
public struct Splat: Equatable, Sendable {
    public var position: Vec3
    public var color: Vec3
    public var layer: Int
}

/// One ray of direct light: from a source to the surface it lights. Every slice of the ray carries the same
/// energy (the bundle's flux), spread over a disc whose radius goes from `startRadius` to `endRadius`.
public struct LightRay: Equatable, Sendable {
    public var from: Vec3
    public var to: Vec3
    public var energyPerMetre: Float
    public var color: Vec3
    public var startRadius: Float = 0
    public var endRadius: Float = 0
}

/// Energy, colour and position of light on a regular grid covering the room.
public struct LightVolume: Sendable {
    public let origin: Vec3
    public let cell: Float
    public let nx: Int, ny: Int, nz: Int
    public var energy: [Float]
    public var colorEnergy: [Vec3]      // energy-weighted display colour
    public var positionEnergy: [Vec3]   // energy-weighted position: splats sit where the light passed

    public init(origin: Vec3, cell: Float, nx: Int, ny: Int, nz: Int) {
        self.origin = origin
        self.cell = cell
        self.nx = nx
        self.ny = ny
        self.nz = nz
        energy = [Float](repeating: 0, count: nx * ny * nz)
        colorEnergy = [Vec3](repeating: .zero, count: nx * ny * nz)
        positionEnergy = [Vec3](repeating: .zero, count: nx * ny * nz)
    }

    @inlinable public func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }

    public func center(_ i: Int, _ j: Int, _ k: Int) -> Vec3 {
        origin + Vec3(Float(i) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * cell
    }

    public var totalEnergy: Float { energy.reduce(0, +) }

    /// Adds energy to one cell, placed at the cell's centre.
    public mutating func add(_ e: Float, color: Vec3, cell i: Int, _ j: Int, _ k: Int) {
        let idx = index(i, j, k)
        energy[idx] += e
        colorEnergy[idx] += color * e
        positionEnergy[idx] += center(i, j, k) * e
    }

    /// Adds the same energy to every cell (ambient light).
    public mutating func addEverywhere(_ e: Float, color: Vec3) {
        guard e > 0 else { return }
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    add(e, color: color, cell: i, j, k)
                }
            }
        }
    }

    /// A ray as a beam of light: each slice along a→b carries `energyPerMetre × slice length`, spread evenly over a
    /// disc whose radius goes from `r0` to `r1`. A beam that widens dissolves: its density in space falls with the
    /// cross-section (1/r² for a cone from a point). Splats land where the light passes.
    public mutating func depositBeam(from a: Vec3, to b: Vec3, startRadius r0: Float, endRadius r1: Float,
                                     energyPerMetre: Float, color: Vec3) {
        let d = b - a
        let length = d.length
        guard length > 1e-6, energyPerMetre > 0 else { return }
        let axis = d / length
        let helper = abs(axis.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
        let u = axis.cross(helper).normalized()
        let w = axis.cross(u)
        let steps = max(1, Int((length / (cell * 0.5)).rounded(.up)))
        let slice = energyPerMetre * length / Float(steps)
        let golden = Float.pi * (3 - Float(5).squareRoot())
        for s in 0..<steps {
            let t = (Float(s) + 0.5) / Float(steps)
            let centre = a + d * t
            let radius = max(r0 + (r1 - r0) * t, 0)
            // Enough points on the disc to cover every cell it touches (sunflower pattern, turned every slice).
            let n = min(max(Int((2 * Float.pi * radius * radius / (cell * cell)).rounded(.up)), 1), 64)
            let e = slice / Float(n)
            for k in 0..<n {
                let rr = radius * ((Float(k) + 0.5) / Float(n)).squareRoot()
                let phi = Float(k) * golden + Float(s) * 0.7
                depositPoint(centre + (u * cos(phi) + w * sin(phi)) * rr, energy: e, color: color)
            }
        }
    }

    private mutating func depositPoint(_ p: Vec3, energy e: Float, color: Vec3) {
        let q = (p - origin) / cell
        let i = Int(q.x.rounded(.down)), j = Int(q.y.rounded(.down)), k = Int(q.z.rounded(.down))
        guard i >= 0, j >= 0, k >= 0, i < nx, j < ny, k < nz else { return }
        let idx = index(i, j, k)
        energy[idx] += e
        colorEnergy[idx] += color * e
        positionEnergy[idx] += p * e
    }

    /// Deposits `energyPerMetre × length` along segment a→b (3D DDA, Amanatides–Woo):
    /// the ray looks equally dense along its whole length, and its splats sit on the ray itself.
    public mutating func depositSegment(from a: Vec3, to b: Vec3, energyPerMetre: Float, color: Vec3) {
        let p = (a - origin) / cell
        let q = (b - origin) / cell
        let d = q - p
        let lengthCells = d.length
        guard lengthCells > 1e-6, energyPerMetre > 0 else { return }
        let lengthMetres = lengthCells * cell

        var i = Int(p.x.rounded(.down)), j = Int(p.y.rounded(.down)), k = Int(p.z.rounded(.down))
        let si = d.x > 0 ? 1 : -1, sj = d.y > 0 ? 1 : -1, sk = d.z > 0 ? 1 : -1
        let inf = Float.greatestFiniteMagnitude
        let tdx = d.x != 0 ? abs(1 / d.x) : inf
        let tdy = d.y != 0 ? abs(1 / d.y) : inf
        let tdz = d.z != 0 ? abs(1 / d.z) : inf
        var tmx = d.x != 0 ? (d.x > 0 ? Float(i + 1) - p.x : p.x - Float(i)) * tdx : inf
        var tmy = d.y != 0 ? (d.y > 0 ? Float(j + 1) - p.y : p.y - Float(j)) * tdy : inf
        var tmz = d.z != 0 ? (d.z > 0 ? Float(k + 1) - p.z : p.z - Float(k)) * tdz : inf
        var t: Float = 0
        var guardSteps = 0
        while t < 1, guardSteps < 4 * (nx + ny + nz) {
            guardSteps += 1
            let tNext = min(min(tmx, tmy), min(tmz, 1))
            if i >= 0, j >= 0, k >= 0, i < nx, j < ny, k < nz {
                let e = energyPerMetre * (tNext - t) * lengthMetres
                let idx = index(i, j, k)
                let mid = a + (b - a) * (0.5 * (t + tNext))
                energy[idx] += e
                colorEnergy[idx] += color * e
                positionEnergy[idx] += mid * e
            }
            if tNext >= 1 { break }
            if tmx <= tmy && tmx <= tmz {
                i += si; t = tmx; tmx += tdx
            } else if tmy <= tmz {
                j += sj; t = tmy; tmy += tdy
            } else {
                k += sk; t = tmz; tmz += tdz
            }
        }
    }
}

/// Builds the light volume of every capture and samples identical splats from it.
public enum LightFieldBuilder {
    /// Bounding box of the room from all captures (2nd–98th percentile per axis, plus a margin).
    public static func roomBounds(_ captures: [CaptureRecord], margin: Float = 0.1) -> (min: Vec3, max: Vec3)? {
        let positions = captures.flatMap { $0.voxels.map(\.position) }
        guard positions.count >= 10 else { return nil }
        func range(_ values: [Float]) -> (Float, Float) {
            let s = values.sorted()
            let lo = s[Int(Float(s.count - 1) * 0.02)], hi = s[Int(Float(s.count - 1) * 0.98)]
            return (lo - margin, hi + margin)
        }
        let x = range(positions.map(\.x)), y = range(positions.map(\.y)), z = range(positions.map(\.z))
        return (Vec3(x.0, y.0, z.0), Vec3(x.1, y.1, z.1))
    }

    /// Luminance normalisation shared by the whole day: the 99th percentile maps to 1.
    public static func dayScale(_ captures: [CaptureRecord]) -> Float {
        let ys = captures.flatMap { $0.voxels.map { Colorimetry.luminance($0.radiance) } }.sorted()
        guard !ys.isEmpty else { return 1 }
        let p99 = ys[Int(Float(ys.count - 1) * 0.99)]
        return p99 > 1e-9 ? 1 / p99 : 1
    }

    public static func emptyVolume(bounds: (min: Vec3, max: Vec3), law: LightLaw) -> LightVolume {
        let extent = bounds.max - bounds.min
        let longest = max(extent.x, max(extent.y, extent.z))
        let cell = max(law.cellSize, longest / Float(law.maxCellsPerAxis))
        let nx = max(1, Int((extent.x / cell).rounded(.up)))
        let ny = max(1, Int((extent.y / cell).rounded(.up)))
        let nz = max(1, Int((extent.z / cell).rounded(.up)))
        return LightVolume(origin: bounds.min, cell: cell, nx: nx, ny: ny, nz: nz)
    }

    /// A lit surface cell as seen by one source: where it is, how much of its light this source gives, its colour.
    public struct LitTarget: Sendable {
        public var position: Vec3
        public var energy: Float
        public var color: Vec3

        public init(position: Vec3, energy: Float, color: Vec3) {
            self.position = position
            self.energy = energy
            self.color = color
        }
    }

    /// Light volume of one capture: bundled rays from sources to lit surfaces + uniform ambient light.
    public static func volume(for capture: CaptureRecord, sources: [LightSource], bounds: (min: Vec3, max: Vec3),
                              dayScale: Float, law: LightLaw) -> LightVolume {
        var volume = emptyVolume(bounds: bounds, law: law)
        let voxels = capture.voxels
        guard !voxels.isEmpty else { return volume }

        let lum = voxels.map { Colorimetry.luminance($0.radiance) * dayScale }
        let kelvin = voxels.map { Colorimetry.kelvin(ofLinearRGB: $0.radiance, whiteBalanceKelvin: capture.whiteBalanceKelvin) }
        let colors = kelvin.map { Colorimetry.displayColor(kelvin: $0, referenceKelvin: law.referenceKelvin, spanMired: law.spanMired) }
        let median = lum.sorted()[lum.count / 2]

        // How bright each source itself is in this capture, and whether it shines at all.
        let brightness = sourceLuminance(capture, sources: sources).map { $0 * dayScale }
        let emits = brightness.map { $0 > 0 && $0 >= law.sourceThreshold * median }

        // Direct light: every lit surface cell is split between the shining sources that can explain it,
        // then each source's share is bundled into discrete rays. Light no shining source explains gets no rays.
        if emits.contains(true) {
            var targets = [[LitTarget]](repeating: [], count: sources.count)
            var weights = [Float](repeating: 0, count: sources.count)
            for v in 0..<voxels.count {
                let excess = lum[v] - law.litThreshold * median
                guard excess > 0 else { continue }
                let p = voxels[v].position
                if sources.contains(where: { $0.contains(p) }) { continue }   // the source itself
                var total: Float = 0
                for (s, source) in sources.enumerated() {
                    guard emits[s] else {
                        weights[s] = 0
                        continue
                    }
                    let d2 = max(p.distance(to: source.center).squared, 0.05)
                    weights[s] = brightness[s] * source.area / d2
                    total += weights[s]
                }
                guard total > 0 else { continue }
                for s in 0..<sources.count {
                    let share = weights[s] / total
                    guard share >= 0.05 else { continue }
                    targets[s].append(LitTarget(position: p, energy: law.beamGain * excess * share, color: colors[v]))
                }
            }
            for (s, source) in sources.enumerated() where !targets[s].isEmpty {
                for ray in bundledRays(source: source, targets: targets[s], law: law) {
                    volume.depositBeam(from: ray.from, to: ray.to, startRadius: ray.startRadius, endRadius: ray.endRadius,
                                       energyPerMetre: ray.energyPerMetre, color: ray.color)
                }
            }
        }

        // Ambient light: uniform energy density through the room, coloured by the capture's median temperature.
        let medianKelvin = kelvin.sorted()[kelvin.count / 2]
        let ambientColor = Colorimetry.displayColor(kelvin: medianKelvin, referenceKelvin: law.referenceKelvin,
                                                    spanMired: law.spanMired)
        volume.addEverywhere(law.ambientGain * median * volume.cell * volume.cell * volume.cell * 40, color: ambientColor)
        return volume
    }

    /// How bright each source itself is in a capture (same units as surface luminance): measured from the camera
    /// image during the scan when available, otherwise the 90th percentile of the surface cells that belong to the
    /// source. A source that was never seen gives 0.
    public static func sourceLuminance(_ capture: CaptureRecord, sources: [LightSource]) -> [Float] {
        sources.map { source in
            if let measured = capture.sourceLuminance[source.id] { return measured }
            let own = capture.voxels.filter { source.contains($0.position) }
                .map { Colorimetry.luminance($0.radiance) }
                .sorted()
            guard !own.isEmpty else { return 0 }
            return own[Int(Float(own.count - 1) * 0.9)]
        }
    }

    /// Whether each source shines in a capture: only if it is itself at least `sourceThreshold` × the median
    /// surface luminance.
    public static func shining(_ capture: CaptureRecord, sources: [LightSource], law: LightLaw) -> [Bool] {
        let lum = capture.voxels.map { Colorimetry.luminance($0.radiance) }.sorted()
        guard !lum.isEmpty else { return sources.map { _ in false } }
        let median = lum[lum.count / 2]
        return sourceLuminance(capture, sources: sources).map { $0 > 0 && $0 >= law.sourceThreshold * median }
    }

    /// Groups one source's lit targets into rays.
    ///  - Lamp: by direction from the lamp, in bins of `rayAngleDegrees`.
    ///  - Window: by where the ray crosses the window (cells of `windowRaySpacing`) and by direction. The crossing
    ///    is found by tracing the target back along the window's dominant light direction, so direct sun becomes
    ///    parallel shafts.
    /// In each bundle only the first surface along the ray is lit (deeper cells are in its shadow); the bundle's
    /// whole energy per metre travels along one ray to the energy centroid of that surface. The ray's radius at each
    /// end is the spread of the bundle's light paths there (across the ray), times `rayWidth`.
    public static func bundledRays(source: LightSource, targets: [LitTarget], law: LightLaw) -> [LightRay] {
        guard !targets.isEmpty else { return [] }
        let angle = max(law.rayAngleDegrees, 0.5) * .pi / 180
        var origins: [Vec3] = []
        var keys: [Int64] = []
        origins.reserveCapacity(targets.count)
        keys.reserveCapacity(targets.count)

        switch source.kind {
        case .lamp:
            let o = source.points[0]
            for t in targets {
                origins.append(o)
                keys.append(directionKey(t.position - o, angle: angle))
            }
        case .window:
            guard let plane = source.windowPlane else { return [] }
            var dominant = Vec3.zero
            for t in targets { dominant += (t.position - plane.center).normalized() * t.energy }
            dominant = dominant.normalized(or: plane.normal)
            let nd = plane.normal.dot(dominant)
            let spacing = max(law.windowRaySpacing, 0.01)
            for t in targets {
                let r = t.position - plane.center
                var o = abs(nd) > 0.2 ? t.position - dominant * (r.dot(plane.normal) / nd)
                                      : t.position - plane.normal * r.dot(plane.normal)
                let u = min(max((o - plane.center).dot(plane.axis), -plane.halfWidth), plane.halfWidth)
                let v = min(max(o.y - plane.center.y, -plane.halfHeight), plane.halfHeight)
                o = plane.center + plane.axis * u + Vec3(0, v, 0)
                origins.append(o)
                let iu = Int64(Int((u / spacing).rounded(.down)) + 4096)
                let iv = Int64(Int((v / spacing).rounded(.down)) + 4096)
                keys.append((iu << 48) | (iv << 34) | directionKey(t.position - o, angle: angle))
            }
        }

        var bundles: [Int64: [Int]] = [:]
        for (i, key) in keys.enumerated() { bundles[key, default: []].append(i) }

        var rays: [LightRay] = []
        rays.reserveCapacity(bundles.count)
        for key in bundles.keys.sorted() {
            guard let members = bundles[key] else { continue }
            var nearest = Float.greatestFiniteMagnitude
            for i in members { nearest = min(nearest, targets[i].position.distance(to: origins[i])) }
            let lit = members.filter { targets[$0].position.distance(to: origins[$0]) <= nearest + law.firstSurfaceDepth }
            var e: Float = 0
            var from = Vec3.zero, to = Vec3.zero, color = Vec3.zero
            for i in lit {
                let w = targets[i].energy
                e += w
                from += origins[i] * w
                to += targets[i].position * w
                color += targets[i].color * w
            }
            guard e > 0 else { continue }
            from /= e
            to /= e
            // Spread of the light paths across the ray, at the source and at the lit surface.
            let axis = (to - from).normalized()
            var spreadFrom: Float = 0, spreadTo: Float = 0
            for i in lit {
                let w = targets[i].energy
                let a = origins[i] - from, b = targets[i].position - to
                spreadFrom += (a - axis * a.dot(axis)).lengthSquared * w
                spreadTo += (b - axis * b.dot(axis)).lengthSquared * w
            }
            let k = max(law.rayWidth, 0) * Float(2).squareRoot()
            rays.append(LightRay(from: from, to: to, energyPerMetre: e, color: color / e,
                                 startRadius: k * (spreadFrom / e).squareRoot(),
                                 endRadius: k * (spreadTo / e).squareRoot()))
        }
        return rays
    }

    /// Equal-area direction bins (cylindrical: azimuth × height), about `angle` radians across at the horizon.
    static func directionKey(_ d: Vec3, angle: Float) -> Int64 {
        let u = d.normalized()
        let nPhi = max(1, Int((2 * Float.pi / angle).rounded()))
        let nY = max(1, Int((2 / angle).rounded()))
        let phi = atan2(u.z, u.x) + .pi
        let i = min(max(Int(phi / (2 * .pi) * Float(nPhi)), 0), nPhi - 1)
        let j = min(max(Int((min(max(u.y, -1), 1) + 1) / 2 * Float(nY)), 0), nY - 1)
        return Int64(j * nPhi + i)
    }

    /// Hierarchical quantum sampling: a cell expecting n = energy/quantum > 1 splats splits into 8 children;
    /// otherwise it emits one splat with probability n, at the energy centroid of the cell. At most one splat per
    /// finest cell: the densest light becomes a regular lattice, dim light a sparse one, rays straight dotted lines.
    public static func sample(_ volume: LightVolume, quantum: Float, layer: Int) -> [Splat] {
        guard quantum > 0 else { return [] }
        // Sum pyramid (non-cubic, each level halves every axis, rounding up).
        struct Level {
            let nx: Int, ny: Int, nz: Int
            var e: [Float]
            var c: [Vec3]
            var p: [Vec3]
        }
        var levels = [Level(nx: volume.nx, ny: volume.ny, nz: volume.nz,
                            e: volume.energy, c: volume.colorEnergy, p: volume.positionEnergy)]
        while let last = levels.last, last.nx > 1 || last.ny > 1 || last.nz > 1 {
            let nx = (last.nx + 1) / 2, ny = (last.ny + 1) / 2, nz = (last.nz + 1) / 2
            var e = [Float](repeating: 0, count: nx * ny * nz)
            var c = [Vec3](repeating: .zero, count: nx * ny * nz)
            var p = [Vec3](repeating: .zero, count: nx * ny * nz)
            for k in 0..<last.nz {
                for j in 0..<last.ny {
                    for i in 0..<last.nx {
                        let src = (k * last.ny + j) * last.nx + i
                        let dst = ((k / 2) * ny + j / 2) * nx + i / 2
                        e[dst] += last.e[src]
                        c[dst] += last.c[src]
                        p[dst] += last.p[src]
                    }
                }
            }
            levels.append(Level(nx: nx, ny: ny, nz: nz, e: e, c: c, p: p))
        }

        var out: [Splat] = []
        var stack: [(level: Int, i: Int, j: Int, k: Int)] = [(levels.count - 1, 0, 0, 0)]
        while let item = stack.popLast() {
            let (level, i, j, k) = item
            let L = levels[level]
            guard i < L.nx, j < L.ny, k < L.nz else { continue }
            let idx = (k * L.ny + j) * L.nx + i
            let e = L.e[idx]
            guard e > 0 else { continue }
            let n = e / quantum
            if n > 1, level > 0 {
                for dk in 0...1 { for dj in 0...1 { for di in 0...1 {
                    stack.append((level - 1, 2 * i + di, 2 * j + dj, 2 * k + dk))
                }}}
                continue
            }
            if hash01(i, j, k, layer &* 31 &+ level) < min(n, 1) {
                out.append(Splat(position: L.p[idx] / e, color: L.c[idx] / e, layer: layer))
            }
        }
        return out
    }

    /// The whole day: one layer per capture (sorted by time), one shared quantum.
    /// Two passes so that only one volume lives in memory at a time: first the day's total energy
    /// (which fixes the quantum), then each volume again for sampling.
    public static func splats(captures: [CaptureRecord], sources: [LightSource], law: LightLaw,
                              isCancelled: () -> Bool = { false }) -> [Splat] {
        let sorted = insideRoom(captures, sources: sources).sorted { $0.date < $1.date }
        guard let bounds = roomBounds(sorted) else { return [] }
        let scale = dayScale(sorted)
        var total: Float = 0
        for capture in sorted {
            if isCancelled() { return [] }
            total += volume(for: capture, sources: sources, bounds: bounds, dayScale: scale, law: law).totalEnergy
        }
        guard total > 0 else { return [] }
        let quantum = total / Float(max(law.splatBudget, 1))
        var all: [Splat] = []
        for (layer, capture) in sorted.enumerated() {
            if isCancelled() { return [] }
            let v = volume(for: capture, sources: sources, bounds: bounds, dayScale: scale, law: law)
            all.append(contentsOf: sample(v, quantum: quantum, layer: layer))
        }
        return all
    }

    /// LiDAR sees through glass: drops points behind a window's wall (the street). Each window's plane splits
    /// space, and the room is the side holding most of the points.
    public static func insideRoom(_ captures: [CaptureRecord], sources: [LightSource],
                                  margin: Float = 0.15) -> [CaptureRecord] {
        let windows = sources.compactMap(\.windowPlane)
        guard !windows.isEmpty else { return captures }
        let all = captures.flatMap { $0.voxels.map(\.position) }
        guard !all.isEmpty else { return captures }
        let planes: [(point: Vec3, inward: Vec3)] = windows.map { w in
            let positive = all.reduce(0) { $0 + (($1 - w.center).dot(w.normal) > 0 ? 1 : 0) }
            return (w.center, positive * 2 >= all.count ? w.normal : -w.normal)
        }
        return captures.map { capture in
            var copy = capture
            copy.voxels = capture.voxels.filter { v in
                planes.allSatisfy { (v.position - $0.point).dot($0.inward) > -margin }
            }
            return copy
        }
    }

    /// Deterministic hash → [0, 1).
    static func hash01(_ i: Int, _ j: Int, _ k: Int, _ salt: Int) -> Float {
        var h = UInt64(truncatingIfNeeded: i) &* 73_856_093
        h ^= UInt64(truncatingIfNeeded: j) &* 19_349_663
        h ^= UInt64(truncatingIfNeeded: k) &* 83_492_791
        h ^= UInt64(truncatingIfNeeded: salt) &* 2_654_435_761
        h ^= h >> 33
        h &*= 0xff51afd7ed558ccd
        h ^= h >> 33
        h &*= 0xc4ceb9fe1a85ec53
        h ^= h >> 33
        return Float(h >> 40) / Float(1 << 24)
    }
}

/// Time scrubbing: which layers are visible for a slider position.
public enum Timeline {
    public enum Mode: String, Codable, Sendable, CaseIterable { case accumulate, moment }

    /// Weights per capture (sorted by date) for slider position s ∈ [0, 1] over the day's span.
    public static func weights(dates: [Date], position s: Double, mode: Mode) -> [Float] {
        guard let first = dates.min(), let last = dates.max() else { return [] }
        if dates.count == 1 { return [1] }
        let span = max(last.timeIntervalSince(first), 1)
        let now = first.timeIntervalSince1970 + s * span
        let spacing = span / Double(dates.count - 1)
        return dates.map { d in
            let dt = now - d.timeIntervalSince1970
            switch mode {
            case .accumulate:
                let ramp = 0.25 * spacing
                return Float(min(max((dt + ramp) / ramp, 0), 1))
            case .moment:
                let sigma = 0.5 * spacing
                return Float(exp(-(dt * dt) / (2 * sigma * sigma)))
            }
        }
    }
}

/// Re-alignment after relocalisation failed: two points re-marked in the new session (e.g. window corners).
/// ARKit worlds are gravity aligned, so only yaw and translation differ.
public enum Alignment {
    /// Transform mapping old-session points onto new-session points.
    public static func yawTranslation(old a: Vec3, _ b: Vec3, new a2: Vec3, _ b2: Vec3) -> RigidTransform {
        let d1 = b - a, d2 = b2 - a2
        let angle = atan2(d2.x, d2.z) - atan2(d1.x, d1.z)
        let c = cos(angle), s = sin(angle)
        // Rotation about +y by `angle` (maps direction d1 onto d2 in the horizontal plane).
        let r = RigidTransform(c0: Vec3(c, 0, -s), c1: Vec3(0, 1, 0), c2: Vec3(s, 0, c), translation: .zero)
        let mid1 = (a + b) * 0.5, mid2 = (a2 + b2) * 0.5
        return RigidTransform(c0: r.c0, c1: r.c1, c2: r.c2, translation: mid2 - r.rotate(mid1))
    }
}

extension Float {
    var squared: Float { self * self }
}
