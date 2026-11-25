import XCTest
import Foundation
@testable import LumenCore

final class ColorimetryTests: XCTestCase {
    func testNeutralMeansWhiteBalanceTemperature() {
        let k = Colorimetry.kelvin(ofLinearRGB: Vec3(0.5, 0.5, 0.5), whiteBalanceKelvin: 5000)
        XCTAssertEqual(k, 5000, accuracy: 150)
    }

    func testWarmAndColdOrdering() {
        let warm = Colorimetry.kelvin(ofLinearRGB: Vec3(0.8, 0.5, 0.25))
        let cold = Colorimetry.kelvin(ofLinearRGB: Vec3(0.4, 0.5, 0.75))
        XCTAssertLessThan(warm, 4000)
        XCTAssertGreaterThan(cold, 6000)
        let warmColor = Colorimetry.displayColor(kelvin: warm)
        let coldColor = Colorimetry.displayColor(kelvin: cold)
        XCTAssertGreaterThan(warmColor.x - warmColor.z, 0.3)
        XCTAssertGreaterThan(coldColor.z - coldColor.x, 0.1)
    }
}

final class VolumeTests: XCTestCase {
    func testSegmentDepositsEnergyPerMetre() {
        var v = LightVolume(origin: .zero, cell: 0.1, nx: 20, ny: 20, nz: 20)
        v.depositSegment(from: Vec3(0.05, 0.33, 0.21), to: Vec3(1.73, 1.02, 0.88), energyPerMetre: 2, color: Vec3(1, 0, 0))
        let length = Vec3(0.05, 0.33, 0.21).distance(to: Vec3(1.73, 1.02, 0.88))
        XCTAssertEqual(v.totalEnergy, 2 * length, accuracy: 1e-3)
        let red = v.colorEnergy.reduce(Vec3.zero, +)
        XCTAssertEqual(red.x, v.totalEnergy, accuracy: 1e-3)
    }

    func testDensityFollowsEnergy() {
        var v = LightVolume(origin: .zero, cell: 0.04, nx: 64, ny: 16, nz: 16)
        for k in 0..<16 { for j in 0..<16 { for i in 0..<64 {
            v.add(i < 32 ? 1 : 4, color: Vec3(1, 1, 1), cell: i, j, k)
        }}}
        // quantum such that the bright half is below one splat per cell
        let splats = LightFieldBuilder.sample(v, quantum: 6, layer: 0)
        let left = splats.filter { $0.position.x < 32 * 0.04 }.count
        let right = splats.count - left
        XCTAssertGreaterThan(Float(right) / Float(max(left, 1)), 3)
        XCTAssertLessThan(Float(right) / Float(max(left, 1)), 5.5)
    }

    func testAtMostOneSplatPerFinestCell() {
        var v = LightVolume(origin: .zero, cell: 0.04, nx: 8, ny: 8, nz: 8)
        v.addEverywhere(100, color: Vec3(1, 1, 1))
        let splats = LightFieldBuilder.sample(v, quantum: 1, layer: 0)
        XCTAssertEqual(splats.count, 512)
    }

    func testRaySplatsSitOnTheRay() {
        var v = LightVolume(origin: .zero, cell: 0.04, nx: 50, ny: 50, nz: 50)
        let a = Vec3(0.1, 0.13, 0.17), b = Vec3(1.8, 1.1, 1.6)
        v.depositSegment(from: a, to: b, energyPerMetre: 100, color: Vec3(1, 1, 1))
        let splats = LightFieldBuilder.sample(v, quantum: 1, layer: 0)
        XCTAssertGreaterThan(splats.count, 40)
        let dir = (b - a).normalized()
        for s in splats {
            let r = s.position - a
            let off = (r - dir * r.dot(dir)).length
            XCTAssertLessThan(off, 0.005)
        }
    }
}

final class RayTests: XCTestCase {
    let law = LightLaw()

    func testLampBundlesByDirectionAndLightsOnlyTheFirstSurface() {
        let lamp = LightSource(kind: .lamp, points: [Vec3(0, 1, 0)])
        let t = [
            LightFieldBuilder.LitTarget(position: Vec3(1, 1, 0), energy: 1, color: Vec3(1, 0, 0)),
            LightFieldBuilder.LitTarget(position: Vec3(1.01, 1, 0.01), energy: 1, color: Vec3(1, 0, 0)),
            LightFieldBuilder.LitTarget(position: Vec3(3, 1, 0), energy: 5, color: Vec3(0, 0, 1)),   // behind, in shadow
            LightFieldBuilder.LitTarget(position: Vec3(0, 1, 2), energy: 1, color: Vec3(0, 1, 0)),   // other direction
        ]
        let rays = LightFieldBuilder.bundledRays(source: lamp, targets: t, law: law)
        XCTAssertEqual(rays.count, 2)
        let toX = rays.first { $0.to.x > 0.5 }!
        XCTAssertEqual(toX.energyPerMetre, 2, accuracy: 1e-5)
        XCTAssertLessThan(toX.to.x, 1.1)
        XCTAssertEqual(toX.color.x, 1, accuracy: 1e-5)
    }

    func testSunThroughWindowGivesParallelRays() {
        // Window in the plane z = 0 (x 0…1, y 1…2), room at z > 0, sun patch on the floor.
        let window = LightSource.window(corner: Vec3(0, 1, 0), Vec3(1, 2, 0), viewer: Vec3(0.5, 1.5, 3))
        let sun = Vec3(0.2, -0.6, 0.77).normalized()
        var targets: [LightFieldBuilder.LitTarget] = []
        for i in 0..<10 { for j in 0..<10 {
            let w = Vec3(0.05 + Float(i) * 0.1, 1.05 + Float(j) * 0.1, 0)
            let p = w + sun * (-w.y / sun.y)
            targets.append(.init(position: p, energy: 1, color: Vec3(1, 1, 1)))
        }}
        let rays = LightFieldBuilder.bundledRays(source: window, targets: targets, law: law)
        XCTAssertGreaterThan(rays.count, 20)
        for r in rays {
            XCTAssertGreaterThan((r.to - r.from).normalized().dot(sun), 0.995)
            XCTAssertEqual(r.from.z, 0, accuracy: 1e-4)
        }
    }
}

final class SourceTests: XCTestCase {
    func testWindowGeometry() {
        let w = LightSource(kind: .window, points: [Vec3(1, 1, 0), Vec3(2, 2, 0)])
        XCTAssertEqual(w.area, 1, accuracy: 1e-4)
        XCTAssertTrue(w.contains(Vec3(1.5, 1.5, 0.02)))
        XCTAssertFalse(w.contains(Vec3(1.5, 1.5, 0.5)))
        XCTAssertEqual(w.samplePoints(gridSize: 3).count, 9)
    }
}

final class TimelineTests: XCTestCase {
    func testAccumulateAndMoment() {
        let t0 = Date(timeIntervalSince1970: 0)
        let dates = [t0, t0.addingTimeInterval(3600), t0.addingTimeInterval(7200)]
        let acc = Timeline.weights(dates: dates, position: 0.5, mode: .accumulate)
        XCTAssertEqual(acc[0], 1)
        XCTAssertEqual(acc[1], 1)
        XCTAssertEqual(acc[2], 0)
        let moment = Timeline.weights(dates: dates, position: 0.5, mode: .moment)
        XCTAssertGreaterThan(moment[1], moment[0])
        XCTAssertGreaterThan(moment[1], moment[2])
    }
}

final class AlignmentTests: XCTestCase {
    func testYawTranslationMapsPoints() {
        let a = Vec3(1, 1, 0), b = Vec3(2, 2, 0.5)
        let truth = RigidTransform(quaternion: SIMD4<Float>(cos(0.35), 0, sin(0.35), 0), translation: Vec3(0.4, 0, -1.2))
        let t = Alignment.yawTranslation(old: a, b, new: truth.apply(a), truth.apply(b))
        XCTAssertLessThan(t.apply(a).distance(to: truth.apply(a)), 1e-4)
        XCTAssertLessThan(t.apply(b).distance(to: truth.apply(b)), 1e-4)
        let p = Vec3(-0.3, 0.7, 2.2)
        XCTAssertLessThan(t.apply(p).distance(to: truth.apply(p)), 1e-4)
    }
}

final class AccumulatorTests: XCTestCase {
    func testAveragesPerCell() {
        var acc = SurfaceAccumulator(cellSize: 0.1)
        acc.add(position: Vec3(0.01, 0.01, 0.01), radiance: Vec3(1, 0, 0))
        acc.add(position: Vec3(0.03, 0.02, 0.01), radiance: Vec3(0, 1, 0))
        acc.add(position: Vec3(0.51, 0.01, 0.01), radiance: Vec3(0, 0, 1))
        let voxels = acc.voxels(minSamples: 2)
        XCTAssertEqual(voxels.count, 1)
        XCTAssertEqual(voxels[0].radiance.x, 0.5, accuracy: 1e-6)
    }

    func testStreetBehindWindowIsDropped() {
        // Window in the plane z = 0, room on the z > 0 side.
        let window = LightSource(kind: .window, points: [Vec3(-0.5, 1.0, 0), Vec3(0.5, 2.0, 0)])
        var voxels: [SurfaceVoxel] = []
        for i in 0..<50 { voxels.append(SurfaceVoxel(position: Vec3(Float(i) * 0.05, 0, 1 + Float(i) * 0.02), radiance: .one, samples: 3)) }
        voxels.append(SurfaceVoxel(position: Vec3(0, 1.5, -2), radiance: .one, samples: 3))     // street through the glass
        voxels.append(SurfaceVoxel(position: Vec3(0, 1.5, -0.05), radiance: .one, samples: 3))  // window frame
        let capture = CaptureRecord(date: Date(), whiteBalanceKelvin: 5000, voxels: voxels)
        let kept = LightFieldBuilder.insideRoom([capture], sources: [window])[0].voxels
        XCTAssertEqual(kept.count, 51)
        XCTAssertFalse(kept.contains { $0.position.z < -1 })
    }

    func testWindowCornersDoNotDependOnTheDiagonal() {
        let viewer = Vec3(0.5, 1.5, 3)     // inside the room, looking towards -z
        let a = LightSource.canonicalWindowCorners(Vec3(0, 1, 0), Vec3(1, 2, 0), viewer: viewer)
        let b = LightSource.canonicalWindowCorners(Vec3(1, 1, 0), Vec3(0, 2, 0), viewer: viewer)
        let c = LightSource.canonicalWindowCorners(Vec3(1, 2, 0), Vec3(0, 1, 0), viewer: viewer)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
        XCTAssertEqual(a[0], Vec3(0, 1, 0))   // bottom-left: looking towards -z, left is -x
        XCTAssertEqual(a[1], Vec3(1, 2, 0))
    }
}
