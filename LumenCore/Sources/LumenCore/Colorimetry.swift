import Foundation

/// Light colour: from camera RGB to colour temperature, and from temperature to the display palette.
public enum Colorimetry {
    /// Rec. 709 luminance of linear RGB.
    @inlinable public static func luminance(_ rgb: Vec3) -> Float {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }

    /// sRGB-like transfer → linear (approximation good enough for relative light measurements).
    @inlinable public static func linearize(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : Float(pow(Double((v + 0.055) / 1.055), 2.4))
    }

    /// Full-range BT.601 YCbCr (0…255) → gamma-encoded RGB (0…1), as delivered by ARKit's captured image.
    @inlinable public static func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> Vec3 {
        let yf = Float(y), cbf = Float(cb) - 128, crf = Float(cr) - 128
        let r = yf + 1.402 * crf
        let g = yf - 0.344136 * cbf - 0.714136 * crf
        let b = yf + 1.772 * cbf
        return Vec3(min(max(r / 255, 0), 1), min(max(g / 255, 0), 1), min(max(b / 255, 0), 1))
    }

    /// Correlated colour temperature (McCamy) of linear camera RGB recorded with white balance locked
    /// at `whiteBalanceKelvin`. Neutral camera RGB means light of exactly that temperature.
    public static func kelvin(ofLinearRGB rgb: Vec3, whiteBalanceKelvin: Float = 5000) -> Float {
        // linear sRGB → XYZ
        let X = 0.4124 * rgb.x + 0.3576 * rgb.y + 0.1805 * rgb.z
        let Y = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        let Z = 0.0193 * rgb.x + 0.1192 * rgb.y + 0.9505 * rgb.z
        let s = X + Y + Z
        guard s > 1e-6 else { return whiteBalanceKelvin }
        let x = X / s, y = Y / s
        let n = (x - 0.3320) / (0.1858 - y)
        var cct = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
        cct = min(max(cct, 1500), 20000)
        // Shift in mired space: camera-neutral (sRGB white, 6504 K) corresponds to the locked WB temperature.
        let mired = 1e6 / cct - 1e6 / 6504 + 1e6 / whiteBalanceKelvin
        return 1e6 / min(max(mired, 1e6 / 25000), 1e6 / 1200)
    }

    /// Fixed warm → neutral → cold palette (display colours, 0…1).
    public static let palette: [Vec3] = [
        Vec3(1.00, 0.42, 0.12),   // amber
        Vec3(1.00, 0.66, 0.34),
        Vec3(1.00, 0.93, 0.84),   // neutral
        Vec3(0.66, 0.82, 1.00),
        Vec3(0.35, 0.60, 1.00),   // ice blue
    ]

    /// Colour of light with temperature `kelvin` on the fixed palette. The position on the palette is
    /// (mired − reference mired) / span, clamped to [−1, 1]: warmer light → amber, colder → blue.
    public static func displayColor(kelvin: Float, referenceKelvin: Float = 5000, spanMired: Float = 90) -> Vec3 {
        let m = 1e6 / max(kelvin, 500)
        let t = min(max((m - 1e6 / referenceKelvin) / max(spanMired, 1), -1), 1)
        let u = (1 - t) / 2 * Float(palette.count - 1)
        let i = min(max(Int(u), 0), palette.count - 2)
        let f = u - Float(i)
        return palette[i] * (1 - f) + palette[i + 1] * f
    }
}
