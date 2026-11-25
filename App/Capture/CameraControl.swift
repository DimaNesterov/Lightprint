import AVFoundation
import ARKit
import ImageIO

/// Camera settings for measuring light: white balance locked for the whole session (colours stay comparable),
/// exposure automatic but biased down during a scan (fewer clipped highlights). Every frame is divided by its own
/// exposure, so the exposure may follow the scene while the user scans the room.
enum CameraControl {
    static var device: AVCaptureDevice? {
        ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
    }

    /// Locks white balance to a fixed temperature.
    @discardableResult
    static func lockWhiteBalance(kelvin: Float) -> Bool {
        guard let d = device, d.isWhiteBalanceModeSupported(.locked) else { return false }
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
            var gains = d.deviceWhiteBalanceGains(for: values)
            let maxGain = d.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            return true
        } catch {
            return false
        }
    }

    static var isWhiteBalanceLocked: Bool { device?.whiteBalanceMode == .locked }

    /// Continuous auto exposure shifted by `biasEV` (negative keeps highlights from clipping).
    static func autoExposure(biasEV: Float) {
        guard let d = device else { return }
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            let bias = min(max(biasEV, d.minExposureTargetBias), d.maxExposureTargetBias)
            d.setExposureTargetBias(bias, completionHandler: nil)
        } catch {}
    }

    /// Back to normal auto exposure for viewing.
    static func resetExposure() {
        autoExposure(biasEV: 0)
    }

    /// Current exposure scale of the camera (seconds × ISO / 100).
    static var currentExposureScale: Float? {
        guard let d = device else { return nil }
        let t = CMTimeGetSeconds(d.exposureDuration)
        guard t > 0, d.iso > 0 else { return nil }
        return Float(t) * d.iso / 100
    }

    /// Exposure scale of one frame from its EXIF data (seconds × ISO / 100), if present.
    static func exposureScale(of frame: ARFrame) -> Float? {
        let exif = frame.exifData
        let dict = (exif["{Exif}"] as? [String: Any]) ?? exif
        guard let time = (dict[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
              let isoList = dict[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
              let iso = isoList.first?.doubleValue, time > 0, iso > 0 else { return nil }
        return Float(time * iso / 100)
    }
}
