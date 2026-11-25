import Foundation
import ARKit
import LumenCore

enum Mode: Equatable {
    case main     // view the light, capture moments
    case mark     // mark windows and lamps
    case align    // re-mark two reference points after relocalisation failed
}

enum MarkTool: String, CaseIterable, Identifiable {
    case lamp, window
    var id: String { rawValue }
    var title: String { self == .lamp ? "Lamp" : "Window" }
}

/// Result of rebuilding the light field off the main thread.
private struct BuildResult: Sendable {
    var splats: [Splat]
    /// Which sources shine in the most recent moment.
    var shining: [UUID: Bool]
}

@MainActor
final class LumenController: NSObject, ObservableObject {
    static let whiteBalanceKelvin: Float = 5000
    /// A scan lasts until the user stops it (at most this long).
    static let maxCaptureDuration: TimeInterval = 300
    static let minCaptureDuration: TimeInterval = 3
    static let playDuration: TimeInterval = 12

    let session = ARSession()
    private var renderer: LightRenderer?

    // Room
    @Published private(set) var manifest = RoomManifest(name: "Room")
    @Published private(set) var rooms: [RoomManifest] = []
    private var voxels: [UUID: [SurfaceVoxel]] = [:]

    // Modes and status
    @Published private(set) var mode: Mode = .main
    @Published var tool: MarkTool = .lamp { didSet { pendingCorner = nil; pushMarkers() } }
    @Published private(set) var pendingCorner: Vec3?
    @Published private(set) var alignTaps: [Vec3] = []
    @Published private(set) var trackingText = ""
    @Published private(set) var trackingNormal = false
    @Published private(set) var relocalizing = false
    @Published private(set) var needsAlignment = false
    @Published private(set) var message: String?
    @Published private(set) var lidarAvailable = true
    @Published private(set) var whiteBalanceLocked = false

    // Capture
    @Published private(set) var isCapturing = false
    @Published private(set) var isSaving = false
    /// Seconds since the scan started (updated a few times per second).
    @Published private(set) var captureElapsed: TimeInterval = 0
    /// Surface area covered by the scan so far, m².
    @Published private(set) var scannedArea: Float = 0
    private var processor: CaptureProcessor?
    private var captureStart: Date?
    private var lastSnapshot = Date.distantPast
    private var snapshotPending = false
    private var whiteBalancePending = true
    private var frameCounter = 0

    // Light
    @Published private(set) var isBuilding = false
    @Published private(set) var splatCount = 0
    @Published var showLight = true { didSet { pushRenderState() } }
    /// Clean view for watching and filming: every control and marker is hidden.
    @Published var interfaceHidden = false { didSet { pushRenderState() } }
    @Published var timelinePosition: Double = 1 { didSet { updateWeights() } }
    @Published var timelineMode: Timeline.Mode = .accumulate { didSet { updateWeights() } }
    @Published private(set) var isPlaying = false
    @Published var render = RenderSettings() { didSet { pushRenderState(); saveRenderSettings() } }
    /// Time of day of each layer (sorted), as dates on 1 Jan 2001 UTC.
    private(set) var layerDates: [Date] = []
    private var lastSplats: [Splat] = []
    private var buildTask: Task<BuildResult, Never>?
    /// Which marked sources shine in the most recent moment (shown on the markers).
    @Published private(set) var sourceShining: [UUID: Bool] = [:]
    private var buildGeneration = 0
    private var playTimer: Timer?
    private var messageGeneration = 0

    private static let lastRoomKey = "lumen.lastRoom"
    private static let renderKey = "lumen.render"

    var isAligned: Bool { !relocalizing && !needsAlignment }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.renderKey),
           let saved = try? JSONDecoder().decode(RenderSettings.self, from: data) {
            render = saved
        }
    }

    // MARK: Lifecycle

    func attach(renderer: LightRenderer) {
        self.renderer = renderer
        renderer.session = session
        renderer.setSplats(lastSplats)
        pushRenderState()
        pushMarkers()
        updateWeights()
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            lidarAvailable = false
            return
        }
        session.delegate = self
        rooms = RoomStore.listRooms()
        if let s = UserDefaults.standard.string(forKey: Self.lastRoomKey), let id = UUID(uuidString: s),
           let m = RoomStore.loadManifest(id) {
            open(m)
        } else if let first = rooms.first {
            open(first)
        } else {
            newRoom()
        }
    }

    func appWillResignActive() {
        if isCapturing { cancelCapture(reason: "Scan interrupted") }
        stopPlaying()
        saveWorldMap()
    }

    private func configuration(worldMap: ARWorldMap?) -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        c.planeDetection = []
        c.environmentTexturing = .none
        c.isLightEstimationEnabled = false
        c.videoHDRAllowed = false          // HDR video would break the camera as a light meter
        c.initialWorldMap = worldMap
        return c
    }

    private func runSession(worldMap: ARWorldMap?) {
        session.run(configuration(worldMap: worldMap), options: [.resetTracking, .removeExistingAnchors])
        whiteBalancePending = true
        relocalizing = worldMap != nil
        trackingNormal = false
    }

    // MARK: Rooms

    func open(_ m: RoomManifest) {
        cancelCapture(reason: nil)
        stopPlaying()
        manifest = m
        UserDefaults.standard.set(m.id.uuidString, forKey: Self.lastRoomKey)
        voxels = [:]
        for c in m.captures {
            if let v = RoomStore.loadVoxels(room: m.id, capture: c.id) { voxels[c.id] = v }
        }
        let map = RoomStore.loadWorldMap(room: m.id)
        let hasData = !m.sources.isEmpty || !m.captures.isEmpty
        needsAlignment = hasData && map == nil
        mode = .main
        pendingCorner = nil
        alignTaps = []
        runSession(worldMap: hasData ? map : nil)
        timelinePosition = 1
        rebuild()
        pushRenderState()
        pushMarkers()
    }

    func newRoom() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM, HH:mm"
        let m = RoomManifest(name: "Room · \(f.string(from: Date()))")
        try? RoomStore.save(m)
        rooms = RoomStore.listRooms()
        open(m)
    }

    func deleteRoom(_ id: UUID) {
        guard id != manifest.id else { return }
        RoomStore.delete(id)
        rooms = RoomStore.listRooms()
    }

    func deleteCapture(_ id: UUID) {
        manifest.captures.removeAll { $0.id == id }
        voxels[id] = nil
        RoomStore.deleteVoxels(room: manifest.id, capture: id)
        saveManifest()
        rebuild()
    }

    func setLaw(_ law: LightLaw) {
        guard law != manifest.law else { return }
        manifest.law = law
        saveManifest()
        rebuild()
    }

    private func saveManifest() {
        do {
            try RoomStore.save(manifest)
        } catch {
            flash("Could not save the room")
        }
        rooms = RoomStore.listRooms()
    }

    private func saveRenderSettings() {
        if let data = try? JSONEncoder().encode(render) {
            UserDefaults.standard.set(data, forKey: Self.renderKey)
        }
    }

    /// Saves ARKit's map of the room so a later session can relocalise into the same coordinates.
    private func saveWorldMap() {
        guard isAligned, mode != .align else { return }
        let roomID = manifest.id
        session.getCurrentWorldMap { map, _ in
            guard let map else { return }
            try? RoomStore.saveWorldMap(map, room: roomID)
        }
    }

    // MARK: Frames

    fileprivate func handle(_ frame: ARFrame) {
        updateTracking(frame.camera.trackingState)
        frameCounter += 1
        if whiteBalancePending {
            whiteBalancePending = !CameraControl.lockWhiteBalance(kelvin: Self.whiteBalanceKelvin)
        }
        if frameCounter % 30 == 0 {
            let locked = CameraControl.isWhiteBalanceLocked
            if locked != whiteBalanceLocked { whiteBalanceLocked = locked }
            if !locked { whiteBalancePending = true }
        }
        if isCapturing { captureFrame(frame) }
    }

    private func updateTracking(_ state: ARCamera.TrackingState) {
        var normal = false
        var text = ""
        switch state {
        case .normal:
            normal = true
        case .notAvailable:
            text = "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: text = "Starting up: move the phone slowly"
            case .excessiveMotion: text = "Too fast, slow down"
            case .insufficientFeatures: text = "Not enough detail, or too dark"
            case .relocalizing: text = "Looking for the room: point the camera where you scanned before"
            @unknown default: text = "Tracking limited"
            }
        }
        if case .limited(.relocalizing) = state, !relocalizing {
            relocalizing = true
            pushRenderState()
            pushMarkers()
        }
        if normal, relocalizing {
            relocalizing = false
            if !needsAlignment { flash("Room found") }
            pushRenderState()
            pushMarkers()
        }
        if trackingNormal != normal { trackingNormal = normal }
        if trackingText != text { trackingText = text }
    }

    // MARK: Taps

    func tap(at point: CGPoint, viewSize: CGSize) {
        guard mode != .main else { return }
        guard trackingNormal, !relocalizing else {
            flash("Wait until tracking is stable")
            return
        }
        guard let p = worldPoint(at: point, viewSize: viewSize) else {
            flash("No depth at this point, move closer")
            return
        }
        switch mode {
        case .mark: mark(p)
        case .align: addAlignmentTap(p)
        case .main: break
        }
    }

    /// World position under a screen point: LiDAR depth (nearest surface around the tap), else an ARKit raycast.
    private func worldPoint(at point: CGPoint, viewSize: CGSize) -> Vec3? {
        guard let frame = session.currentFrame, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let pixel = CameraGeometry.imagePixel(forViewPoint: point, viewSize: viewSize, frame: frame)
        let geometry = CameraGeometry(camera: frame.camera)
        if let depth = DepthFrame(depth: frame.sceneDepth?.depthMap, confidence: frame.sceneDepth?.confidenceMap,
                                  imageSize: frame.camera.imageResolution),
           let d = depth.nearDepth(atImagePixel: pixel, radius: 3) {
            return geometry.unproject(pixel: pixel, depth: d)
        }
        let size = frame.camera.imageResolution
        let normalized = CGPoint(x: CGFloat(pixel.x) / size.width, y: CGFloat(pixel.y) / size.height)
        let query = frame.raycastQuery(from: normalized, allowing: .estimatedPlane, alignment: .any)
        if let hit = session.raycast(query).first {
            let t = hit.worldTransform.columns.3
            return Vec3(t.x, t.y, t.z)
        }
        return nil
    }

    /// Current camera position in the world.
    private var cameraPosition: Vec3? {
        guard let t = session.currentFrame?.camera.transform.columns.3 else { return nil }
        return Vec3(t.x, t.y, t.z)
    }

    /// Screen point (view coordinates) of a world point, nil if it is behind the camera.
    private func screenPoint(of world: Vec3, frame: ARFrame, viewSize: CGSize) -> CGPoint? {
        let geometry = CameraGeometry(camera: frame.camera)
        guard let hit = geometry.project(world: world) else { return nil }
        let image = CGPoint(x: CGFloat(hit.pixel.x) / geometry.imageSize.width,
                            y: CGFloat(hit.pixel.y) / geometry.imageSize.height)
        let view = image.applying(frame.displayTransform(for: .portrait, viewportSize: viewSize))
        return CGPoint(x: view.x * viewSize.width, y: view.y * viewSize.height)
    }

    /// Where the camera ray through a screen point meets a vertical plane.
    private func hitPlane(at point: CGPoint, viewSize: CGSize, frame: ARFrame, planePoint: Vec3, normal: Vec3) -> Vec3? {
        let pixel = CameraGeometry.imagePixel(forViewPoint: point, viewSize: viewSize, frame: frame)
        let along = CameraGeometry(camera: frame.camera).unproject(pixel: pixel, depth: 1)
        let t = frame.camera.transform.columns.3
        let origin = Vec3(t.x, t.y, t.z)
        let dir = (along - origin).normalized()
        let denom = normal.dot(dir)
        guard abs(denom) > 0.05 else { return nil }
        let s = normal.dot(planePoint - origin) / denom
        guard s > 0.05, s < 15 else { return nil }
        return origin + dir * s
    }

    // MARK: Correcting window corners by dragging

    private struct CornerDrag {
        let source: Int
        let corner: Int          // 0 bottom-left, 1 bottom-right, 2 top-right, 3 top-left
        var left: Vec3
        var right: Vec3
        var bottom: Float
        var top: Float
        let planePoint: Vec3
        let normal: Vec3
        let offset: CGPoint      // corner on screen minus finger at the start: the corner does not jump
    }

    private var drag: CornerDrag?
    @Published private(set) var isDraggingCorner = false

    /// Starts dragging the window corner nearest to the finger (in marking mode). Returns false if none is close.
    func beginCornerDrag(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard mode == .mark, isAligned, let frame = session.currentFrame else { return false }
        var best: (source: Int, corner: Int, screen: CGPoint, distance: CGFloat)?
        for (s, source) in manifest.sources.enumerated() where source.kind == .window {
            for (c, corner) in source.windowCorners.enumerated() {
                guard let sp = screenPoint(of: corner, frame: frame, viewSize: viewSize) else { continue }
                let d = hypot(sp.x - point.x, sp.y - point.y)
                if d < 70, d < (best?.distance ?? .greatestFiniteMagnitude) { best = (s, c, sp, d) }
            }
        }
        guard let best, let plane = manifest.sources[best.source].windowPlane else { return false }
        let pts = manifest.sources[best.source].points
        drag = CornerDrag(source: best.source, corner: best.corner, left: pts[0], right: pts[1],
                          bottom: pts[0].y, top: pts[1].y, planePoint: plane.center, normal: plane.normal,
                          offset: CGPoint(x: best.screen.x - point.x, y: best.screen.y - point.y))
        pendingCorner = nil
        isDraggingCorner = true
        pushMarkers()
        return true
    }

    /// Moves the dragged corner within the window's plane: the window keeps its wall, only its edges move.
    func updateCornerDrag(at point: CGPoint, viewSize: CGSize) {
        guard var d = drag, d.source < manifest.sources.count, let frame = session.currentFrame else { return }
        let target = CGPoint(x: point.x + d.offset.x, y: point.y + d.offset.y)
        guard let p = hitPlane(at: target, viewSize: viewSize, frame: frame, planePoint: d.planePoint, normal: d.normal)
        else { return }
        switch d.corner {
        case 0: d.left = p; d.bottom = p.y
        case 1: d.right = p; d.bottom = p.y
        case 2: d.right = p; d.top = p.y
        default: d.left = p; d.top = p.y
        }
        drag = d
        manifest.sources[d.source].points = [Vec3(d.left.x, d.bottom, d.left.z), Vec3(d.right.x, d.top, d.right.z)]
        pushMarkers()
    }

    func endCornerDrag() {
        guard let d = drag else { return }
        drag = nil
        isDraggingCorner = false
        if d.source < manifest.sources.count, let viewer = cameraPosition {
            let pts = manifest.sources[d.source].points
            manifest.sources[d.source].points = LightSource.canonicalWindowCorners(pts[0], pts[1], viewer: viewer)
        }
        saveManifest()
        pushMarkers()
    }

    // MARK: Marking

    func beginMarking() {
        guard isAligned else {
            flash(needsAlignment ? "Align the room first" : "Wait until the room is found")
            return
        }
        stopPlaying()
        mode = .mark
        pendingCorner = nil
        pushRenderState()
        pushMarkers()
    }

    func endMarking() {
        if drag != nil { endCornerDrag() }
        if let viewer = cameraPosition {
            for i in manifest.sources.indices where manifest.sources[i].kind == .window {
                let p = manifest.sources[i].points
                manifest.sources[i].points = LightSource.canonicalWindowCorners(p[0], p[1], viewer: viewer)
            }
            saveManifest()
        }
        mode = .main
        pendingCorner = nil
        pushRenderState()
        pushMarkers()
        saveWorldMap()
        rebuild()
    }

    func undoMark() {
        if pendingCorner != nil {
            pendingCorner = nil
        } else if !manifest.sources.isEmpty {
            manifest.sources.removeLast()
            saveManifest()
        }
        pushMarkers()
    }

    private func mark(_ p: Vec3) {
        switch tool {
        case .lamp:
            manifest.sources.append(LightSource(kind: .lamp, points: [p]))
            saveManifest()
            flash("Lamp marked")
        case .window:
            if let first = pendingCorner {
                var h = p - first
                h.y = 0
                pendingCorner = nil
                guard abs(p.y - first.y) > 0.15, h.length > 0.15, let viewer = cameraPosition else {
                    flash("Corners too close: mark opposite corners of the window")
                    pushMarkers()
                    return
                }
                // Stored as bottom-left, top-right seen from inside: the same order is used for manual alignment.
                manifest.sources.append(LightSource.window(corner: first, p, viewer: viewer))
                saveManifest()
                flash("Window marked. Drag its corners to adjust")
            } else {
                pendingCorner = p
            }
        }
        pushMarkers()
    }

    var windowCount: Int { manifest.sources.filter { $0.kind == .window }.count }
    var lampCount: Int { manifest.sources.filter { $0.kind == .lamp }.count }

    // MARK: Alignment

    /// Reference points for manual alignment: the first window's corners (bottom-left, top-right), or the first two lamps.
    private var referencePoints: [Vec3]? {
        if let w = manifest.sources.first(where: { $0.kind == .window }) { return w.points }
        let lamps = manifest.sources.filter { $0.kind == .lamp }
        if lamps.count >= 2 { return [lamps[0].points[0], lamps[1].points[0]] }
        return nil
    }

    var alignmentUsesWindow: Bool { manifest.sources.contains { $0.kind == .window } }
    var canAlign: Bool { referencePoints != nil }

    func beginAlignment() {
        guard canAlign else {
            flash("Alignment needs a marked window or two lamps")
            return
        }
        cancelCapture(reason: nil)
        stopPlaying()
        alignTaps = []
        mode = .align
        runSession(worldMap: nil)
        relocalizing = false
        needsAlignment = true
        pushRenderState()
        pushMarkers()
    }

    func cancelAlignment() {
        mode = .main
        alignTaps = []
        let map = RoomStore.loadWorldMap(room: manifest.id)
        runSession(worldMap: map)
        needsAlignment = map == nil && (!manifest.sources.isEmpty || !manifest.captures.isEmpty)
        pushRenderState()
        pushMarkers()
    }

    private func addAlignmentTap(_ p: Vec3) {
        alignTaps.append(p)
        pushMarkers()
        guard alignTaps.count == 2, let ref = referencePoints else { return }
        var new = alignTaps
        if alignmentUsesWindow, let viewer = cameraPosition {
            new = LightSource.canonicalWindowCorners(new[0], new[1], viewer: viewer)
        }
        let oldDistance = ref[0].distance(to: ref[1]), newDistance = new[0].distance(to: new[1])
        guard abs(oldDistance - newDistance) < max(0.25, 0.2 * oldDistance) else {
            alignTaps = []
            pushMarkers()
            flash("Distance does not match (\(Self.cm(newDistance)) instead of \(Self.cm(oldDistance))). Mark the same points again")
            return
        }
        let t = Alignment.yawTranslation(old: ref[0], ref[1], new: new[0], new[1])
        manifest.sources = manifest.sources.map { $0.transformed(by: t) }
        for info in manifest.captures {
            guard let v = voxels[info.id] else { continue }
            let moved = v.map { SurfaceVoxel(position: t.apply($0.position), radiance: $0.radiance, samples: $0.samples) }
            voxels[info.id] = moved
            try? RoomStore.saveVoxels(moved, room: manifest.id, capture: info.id)
        }
        saveManifest()
        needsAlignment = false
        alignTaps = []
        mode = .main
        RoomStore.deleteWorldMap(room: manifest.id)
        saveWorldMap()
        rebuild()
        pushRenderState()
        pushMarkers()
        flash("Aligned")
    }

    private static func cm(_ metres: Float) -> String { "\(Int((metres * 100).rounded())) cm" }

    // MARK: Capture (one moment = one scan of the whole room)

    func toggleCapture() {
        isCapturing ? stopCapture() : startCapture()
    }

    func startCapture() {
        guard mode == .main, !isCapturing, !isSaving else { return }
        guard isAligned else {
            flash(needsAlignment ? "Align the room first" : "Wait until the room is found")
            return
        }
        guard trackingNormal else {
            flash("Wait until tracking is stable")
            return
        }
        stopPlaying()
        if !CameraControl.lockWhiteBalance(kelvin: Self.whiteBalanceKelvin) {
            flash("White balance not locked: colours will be inaccurate")
        }
        whiteBalanceLocked = CameraControl.isWhiteBalanceLocked
        CameraControl.autoExposure(biasEV: -1)
        processor = CaptureProcessor(cellSize: manifest.law.cellSize, sources: manifest.sources)
        captureStart = Date()
        captureElapsed = 0
        scannedArea = 0
        lastSnapshot = .distantPast
        snapshotPending = false
        renderer?.setScanPoints([])
        isCapturing = true
        pushRenderState()
    }

    private func captureFrame(_ frame: ARFrame) {
        guard let start = captureStart, let processor else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        if elapsed - captureElapsed >= 0.25 { captureElapsed = elapsed }
        if elapsed >= Self.maxCaptureDuration {
            stopCapture()
            return
        }
        // Live preview of what has been scanned, twice a second.
        if !snapshotPending, now.timeIntervalSince(lastSnapshot) > 0.5 {
            snapshotPending = true
            lastSnapshot = now
            processor.snapshot(whiteBalanceKelvin: Self.whiteBalanceKelvin) { [weak self] points, area in
                guard let self else { return }
                self.snapshotPending = false
                guard self.isCapturing else { return }
                self.renderer?.setScanPoints(points)
                self.scannedArea = area
            }
        }
        // Skip the first frames: the exposure bias needs a moment to take effect.
        guard elapsed > 0.3, case .normal = frame.camera.trackingState, processor.canAccept,
              let f = CaptureFrame(frame: frame, fallbackExposureScale: CameraControl.currentExposureScale ?? 1)
        else { return }
        processor.add(f)
    }

    func stopCapture() {
        guard isCapturing, let processor, let start = captureStart else { return }
        let duration = Date().timeIntervalSince(start)
        isCapturing = false
        self.processor = nil
        captureStart = nil
        CameraControl.resetExposure()
        guard duration >= Self.minCaptureDuration else {
            renderer?.setScanPoints([])
            pushRenderState()
            flash("Too short: sweep the camera over the whole room")
            return
        }
        isSaving = true
        pushRenderState()
        processor.finish { [weak self] result in
            self?.finishCapture(result, date: start)
        }
    }

    private func cancelCapture(reason: String?) {
        guard isCapturing else { return }
        isCapturing = false
        processor = nil
        captureStart = nil
        CameraControl.resetExposure()
        renderer?.setScanPoints([])
        pushRenderState()
        if let reason { flash(reason) }
    }

    private func finishCapture(_ result: CaptureResult, date: Date) {
        isSaving = false
        renderer?.setScanPoints([])
        pushRenderState()
        print("Lumen: scan \(result.frames) frames, exposure from EXIF in \(result.exifFrames), \(result.voxels.count) cells")
        guard result.voxels.count >= 300 else {
            flash("Not enough data (\(result.voxels.count) cells): scan again, more slowly")
            return
        }
        let id = UUID()
        do {
            try RoomStore.saveVoxels(result.voxels, room: manifest.id, capture: id)
        } catch {
            flash("Could not save the moment")
            return
        }
        voxels[id] = result.voxels
        var measured: [String: Float] = [:]
        for (sourceID, value) in result.sourceLuminance { measured[sourceID.uuidString] = value }
        manifest.captures.append(CaptureInfo(id: id, date: date, whiteBalanceKelvin: Self.whiteBalanceKelvin,
                                             voxelCount: result.voxels.count, sourceLuminance: measured))
        saveManifest()
        saveWorldMap()
        timelinePosition = 1
        let area = Float(result.voxels.count) * manifest.law.cellSize * manifest.law.cellSize
        flash("Moment saved: \(Int(area.rounded())) m² of surfaces, \(result.frames) frames")
        rebuild()
    }

    // MARK: Reset

    /// Deletes every moment of the room; windows and lamps stay.
    func clearMoments() {
        cancelCapture(reason: nil)
        stopPlaying()
        for c in manifest.captures { RoomStore.deleteVoxels(room: manifest.id, capture: c.id) }
        manifest.captures = []
        voxels = [:]
        saveManifest()
        timelinePosition = 1
        rebuild()
        flash("Moments deleted: ready for a new scan")
    }

    /// Deletes moments, windows, lamps and the room map: the room starts from scratch.
    func resetRoom() {
        cancelCapture(reason: nil)
        stopPlaying()
        for c in manifest.captures { RoomStore.deleteVoxels(room: manifest.id, capture: c.id) }
        manifest.captures = []
        manifest.sources = []
        voxels = [:]
        RoomStore.deleteWorldMap(room: manifest.id)
        saveManifest()
        drag = nil
        isDraggingCorner = false
        mode = .main
        pendingCorner = nil
        alignTaps = []
        needsAlignment = false
        runSession(worldMap: nil)
        timelinePosition = 1
        rebuild()
        pushRenderState()
        pushMarkers()
        flash("Room reset: mark windows and lamps")
    }

    // MARK: Light field

    static func timeOfDay(_ date: Date) -> Date {
        let start = Calendar.current.startOfDay(for: date)
        return Date(timeIntervalSinceReferenceDate: date.timeIntervalSince(start))
    }

    private func rebuild() {
        let captures: [CaptureRecord] = manifest.captures.compactMap { info in
            guard let v = voxels[info.id] else { return nil }
            var measured: [UUID: Float] = [:]
            for (key, value) in info.sourceLuminance ?? [:] {
                if let id = UUID(uuidString: key) { measured[id] = value }
            }
            return CaptureRecord(id: info.id, date: Self.timeOfDay(info.date),
                                 whiteBalanceKelvin: info.whiteBalanceKelvin, voxels: v, sourceLuminance: measured)
        }
        layerDates = captures.map(\.date).sorted()
        buildTask?.cancel()
        buildGeneration += 1
        let generation = buildGeneration
        guard !captures.isEmpty else {
            isBuilding = false
            sourceShining = [:]
            applySplats([])
            pushMarkers()
            return
        }
        let latestID = manifest.captures.max { $0.date < $1.date }?.id
        let sources = manifest.sources, law = manifest.law
        isBuilding = true
        let task = Task.detached(priority: .userInitiated) { () -> BuildResult in
            let splats = LightFieldBuilder.splats(captures: captures, sources: sources, law: law,
                                                  isCancelled: { Task.isCancelled })
            var shining: [UUID: Bool] = [:]
            if let latest = captures.first(where: { $0.id == latestID }) {
                for (source, on) in zip(sources, LightFieldBuilder.shining(latest, sources: sources, law: law)) {
                    shining[source.id] = on
                }
            }
            return BuildResult(splats: splats, shining: shining)
        }
        buildTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self, generation == self.buildGeneration else { return }
            self.isBuilding = false
            self.sourceShining = result.shining
            self.applySplats(result.splats)
            self.pushMarkers()
            if !sources.isEmpty, !result.shining.isEmpty, !result.shining.values.contains(true) {
                self.flash("No marked window or lamp is shining in the latest moment, so there are no rays")
            }
        }
    }

    private func applySplats(_ splats: [Splat]) {
        lastSplats = splats
        splatCount = splats.count
        renderer?.setSplats(splats)
        updateWeights()
    }

    // MARK: Timeline

    private func updateWeights() {
        renderer?.setLayerWeights(Timeline.weights(dates: layerDates, position: timelinePosition, mode: timelineMode))
    }

    /// Positions of the moments on the timeline, 0…1.
    var captureTicks: [Double] {
        guard let first = layerDates.first, let last = layerDates.last, layerDates.count > 1 else {
            return layerDates.isEmpty ? [] : [1]
        }
        let span = max(last.timeIntervalSince(first), 1)
        return layerDates.map { $0.timeIntervalSince(first) / span }
    }

    var timelineLabel: String {
        guard let first = layerDates.first, let last = layerDates.last else { return "--:--" }
        let t = first.addingTimeInterval(timelinePosition * last.timeIntervalSince(first))
        return Self.clock.string(from: t)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")   // layer dates are seconds since midnight on 1 Jan 2001 UTC
        return f
    }()

    func togglePlay() {
        if isPlaying {
            stopPlaying()
            return
        }
        guard layerDates.count > 1 else { return }
        if timelinePosition >= 0.999 { timelinePosition = 0 }
        isPlaying = true
        let step = 1.0 / 30.0
        playTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = self.timelinePosition + step / Self.playDuration
                if next >= 1 {
                    self.timelinePosition = 1
                    self.stopPlaying()
                } else {
                    self.timelinePosition = next
                }
            }
        }
    }

    func stopPlaying() {
        playTimer?.invalidate()
        playTimer = nil
        if isPlaying { isPlaying = false }
    }

    // MARK: Renderer state

    private func pushRenderState() {
        guard let renderer else { return }
        renderer.settings = render
        renderer.cameraDim = render.cameraDim
        renderer.showLight = showLight && isAligned && mode == .main && !isCapturing && !isSaving
        renderer.showScan = isCapturing || isSaving
        renderer.showMarkers = !interfaceHidden
            && (mode == .align || (isAligned && (mode == .mark || render.showMarkers)))
    }

    private func pushMarkers() {
        guard let renderer else { return }
        let warm = SIMD4<Float>(1.0, 0.62, 0.25, 0.95)
        let cool = SIMD4<Float>(0.75, 0.88, 1.0, 0.95)
        let white = SIMD4<Float>(1, 1, 1, 1)
        let dark = SIMD4<Float>(0.5, 0.5, 0.5, 0.85)      // marked, but not shining in the latest moment
        var markers: [MarkerPoint] = []
        if mode == .align {
            markers = alignTaps.map { MarkerPoint($0, size: 44, color: white) }
        } else if isAligned {
            for s in manifest.sources {
                switch s.kind {
                case .lamp:
                    markers.append(MarkerPoint(s.points[0], size: 54, color: sourceShining[s.id] == false ? dark : warm))
                case .window:
                    let edge = sourceShining[s.id] == false ? dark : cool
                    let corners = s.windowCorners
                    let handle: Float = mode == .mark ? 66 : 36
                    for (i, c) in corners.enumerated() {
                        let dragged = drag.map { manifest.sources.indices.contains($0.source)
                            && manifest.sources[$0.source].id == s.id && $0.corner == i } ?? false
                        markers.append(MarkerPoint(c, size: dragged ? handle * 1.3 : handle, color: dragged ? white : edge))
                        let next = corners[(i + 1) % 4]
                        let steps = max(1, Int(c.distance(to: next) / 0.05))
                        for k in 1..<max(steps, 2) {
                            let t = Float(k) / Float(steps)
                            markers.append(MarkerPoint(c + (next - c) * t, size: 10, color: edge))
                        }
                    }
                }
            }
            if let p = pendingCorner { markers.append(MarkerPoint(p, size: 44, color: white)) }
        }
        renderer.setMarkers(markers)
        pushRenderState()
    }

    // MARK: Messages

    func flash(_ text: String) {
        messageGeneration += 1
        let generation = messageGeneration
        message = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, self.messageGeneration == generation else { return }
            self.message = nil
        }
    }

    /// The line shown at the top: what to do now.
    var instruction: String {
        if let message { return message }
        switch mode {
        case .mark:
            if tool == .lamp { return "Tap the lamp: its shade or the bulb itself" }
            if isDraggingCorner { return "Drag the corner to the edge of the window" }
            if pendingCorner != nil { return "Now the opposite corner of the window" }
            return windowCount > 0 ? "New window: tap a corner. Drag corners of marked windows to adjust"
                                   : "Window: tap one corner, then the opposite one"
        case .align:
            if alignmentUsesWindow {
                return alignTaps.isEmpty ? "Alignment: tap a corner of the first window"
                                         : "Now the opposite corner of the same window"
            }
            return alignTaps.isEmpty ? "Alignment: tap the first marked lamp" : "Now the second lamp"
        case .main:
            if !trackingText.isEmpty { return trackingText }
            if needsAlignment { return "No room map: tap Align" }
            if isCapturing { return "Scan the whole room: walls, floor, ceiling, corners. Stop when everything is covered" }
            if isSaving { return "Saving the moment…" }
            if manifest.sources.isEmpty { return "Mark the windows and lamps" }
            if manifest.captures.isEmpty { return "Capture the first moment: scan the whole room" }
            if isBuilding { return "Building the light…" }
            return ""
        }
    }
}

// MARK: - ARSessionDelegate

extension LumenController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.handle(frame) }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { self.cancelCapture(reason: "Scan interrupted") }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let text = error.localizedDescription
        MainActor.assumeIsolated { self.flash("AR error: \(text)") }
    }
}
