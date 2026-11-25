// Small vector helpers on top of the standard library SIMD types.
// Implemented as members (not free functions) so they never clash with the
// `simd` module's `dot`, `cross`, `length`, `normalize` on Apple platforms.

public typealias Vec3 = SIMD3<Float>
public typealias Vec2 = SIMD2<Float>

extension SIMD3 where Scalar == Float {
    @inlinable public func dot(_ other: Self) -> Float {
        (self * other).sum()
    }

    @inlinable public func cross(_ other: Self) -> Self {
        Self(y * other.z - z * other.y,
             z * other.x - x * other.z,
             x * other.y - y * other.x)
    }

    @inlinable public var lengthSquared: Float { dot(self) }

    @inlinable public var length: Float { lengthSquared.squareRoot() }

    @inlinable public func normalized(or fallback: Self = Self(0, 0, 1)) -> Self {
        let l = length
        return l > 1e-12 ? self / l : fallback
    }

    @inlinable public var isFiniteVector: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }

    @inlinable public func distance(to other: Self) -> Float {
        (self - other).length
    }

    @inlinable public static func lerp(_ a: Self, _ b: Self, _ t: Float) -> Self {
        a + (b - a) * t
    }
}
