import Foundation

/// One surface cell of a capture: mean position and mean linear radiance (RGB divided by exposure).
public struct SurfaceVoxel: Codable, Equatable, Sendable {
    public var position: Vec3
    public var radiance: Vec3
    public var samples: Int32

    public init(position: Vec3, radiance: Vec3, samples: Int32) {
        self.position = position
        self.radiance = radiance
        self.samples = samples
    }
}

/// One "moment": what the room's surfaces looked like during one scan.
public struct CaptureRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var date: Date
    public var whiteBalanceKelvin: Float
    public var voxels: [SurfaceVoxel]
    /// Luminance of each marked source as the camera saw it during the scan (90th percentile, same units as
    /// surface radiance). Sources marked after the scan are missing here.
    public var sourceLuminance: [UUID: Float]

    public init(id: UUID = UUID(), date: Date, whiteBalanceKelvin: Float, voxels: [SurfaceVoxel],
                sourceLuminance: [UUID: Float] = [:]) {
        self.id = id
        self.date = date
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.voxels = voxels
        self.sourceLuminance = sourceLuminance
    }

    public func transformed(by t: RigidTransform) -> CaptureRecord {
        var copy = self
        copy.voxels = voxels.map { SurfaceVoxel(position: t.apply($0.position), radiance: $0.radiance, samples: $0.samples) }
        return copy
    }
}

/// Accumulates camera samples (world position + linear RGB already divided by exposure) into cells.
/// Saturated pixels are kept apart: they only say "at least this bright".
public struct SurfaceAccumulator: Sendable {
    public let cellSize: Float
    private struct Cell: Sendable {
        var position = Vec3.zero
        var count: Int32 = 0
        var radiance = Vec3.zero
        var unclipped: Int32 = 0
        var clippedRadiance = Vec3.zero
        var clipped: Int32 = 0
    }
    private var cells: [Int64: Cell] = [:]

    public init(cellSize: Float = 0.04) {
        self.cellSize = cellSize
    }

    public var cellCount: Int { cells.count }

    static func key(_ i: Int, _ j: Int, _ k: Int) -> Int64 {
        // 21 bits per axis, offset so negative indices work (±1M cells ≈ ±40 km at 4 cm).
        let o = 1 << 20
        return (Int64(i + o) << 42) | (Int64(j + o) << 21) | Int64(k + o)
    }

    public mutating func add(position p: Vec3, radiance: Vec3, clipped: Bool = false) {
        let i = Int((p.x / cellSize).rounded(.down))
        let j = Int((p.y / cellSize).rounded(.down))
        let k = Int((p.z / cellSize).rounded(.down))
        let key = Self.key(i, j, k)
        var c = cells[key] ?? Cell()
        c.position += p
        c.count += 1
        if clipped {
            c.clippedRadiance += radiance
            c.clipped += 1
        } else {
            c.radiance += radiance
            c.unclipped += 1
        }
        cells[key] = c
    }

    /// Cells with at least `minSamples` samples. Radiance is the mean of unclipped samples, unless the clipped
    /// ones (a lower bound) are brighter or nothing unclipped was seen — then the clipped mean.
    public func voxels(minSamples: Int32 = 2) -> [SurfaceVoxel] {
        cells.values.compactMap { c in
            guard c.count >= minSamples else { return nil }
            let unclippedMean: Vec3? = c.unclipped > 0 ? c.radiance / Float(c.unclipped) : nil
            let clippedMean: Vec3? = c.clipped > 0 ? c.clippedRadiance / Float(c.clipped) : nil
            let radiance: Vec3
            switch (unclippedMean, clippedMean) {
            case let (u?, k?):
                radiance = Colorimetry.luminance(k) > Colorimetry.luminance(u) ? k : u
            case let (u?, nil):
                radiance = u
            case let (nil, k?):
                radiance = k
            case (nil, nil):
                return nil
            }
            return SurfaceVoxel(position: c.position / Float(c.count), radiance: radiance, samples: c.count)
        }
    }
}
