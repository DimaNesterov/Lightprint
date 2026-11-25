import Foundation
import ARKit
import LumenCore

/// Capture metadata kept in the room manifest (the voxels live in their own binary file).
struct CaptureInfo: Codable, Identifiable, Equatable {
    let id: UUID
    var date: Date
    var whiteBalanceKelvin: Float
    var voxelCount: Int
    /// How bright each marked source looked during the scan (keys: source ids).
    var sourceLuminance: [String: Float]?
}

/// One room: its light sources, its moments and the law used to draw them.
/// Moments may come from different days; the timeline uses their time of day.
struct RoomManifest: Codable, Equatable {
    var id: UUID
    var name: String
    var created: Date
    var sources: [LightSource]
    var captures: [CaptureInfo]
    var law: LightLaw

    init(id: UUID = UUID(), name: String, created: Date = Date()) {
        self.id = id
        self.name = name
        self.created = created
        sources = []
        captures = []
        law = LightLaw()
    }
}

/// Files:  Documents/Rooms/<room id>/room.json
///                                  /captures/<capture id>.bin
///                                  /world.armap
/// The Documents folder is visible in the Files app (On My iPhone → Lumen).
enum RoomStore {
    static var roomsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Rooms", isDirectory: true)
    }

    static func folder(_ id: UUID) -> URL { roomsURL.appendingPathComponent(id.uuidString, isDirectory: true) }
    private static func manifestURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("room.json") }
    private static func captureURL(room: UUID, capture: UUID) -> URL {
        folder(room).appendingPathComponent("captures", isDirectory: true).appendingPathComponent("\(capture.uuidString).bin")
    }
    private static func worldMapURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("world.armap") }

    // MARK: Rooms

    static func listRooms() -> [RoomManifest] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: roomsURL, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return loadManifest(id)
        }
        .sorted { $0.created > $1.created }
    }

    static func loadManifest(_ id: UUID) -> RoomManifest? {
        guard let data = try? Data(contentsOf: manifestURL(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RoomManifest.self, from: data)
    }

    static func save(_ manifest: RoomManifest) throws {
        try FileManager.default.createDirectory(at: folder(manifest.id).appendingPathComponent("captures"),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(manifest.id), options: .atomic)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    // MARK: Captures (binary: "LUMV", version, count, then 7 × Float32 + Int32 per voxel)

    static func saveVoxels(_ voxels: [SurfaceVoxel], room: UUID, capture: UUID) throws {
        var data = Data()
        data.reserveCapacity(12 + voxels.count * 28)
        data.append(contentsOf: Array("LUMV".utf8))
        append(UInt32(1), to: &data)
        append(UInt32(voxels.count), to: &data)
        for v in voxels {
            for f in [v.position.x, v.position.y, v.position.z, v.radiance.x, v.radiance.y, v.radiance.z] {
                append(f.bitPattern, to: &data)
            }
            append(UInt32(bitPattern: v.samples), to: &data)
        }
        try FileManager.default.createDirectory(at: folder(room).appendingPathComponent("captures"),
                                                withIntermediateDirectories: true)
        try data.write(to: captureURL(room: room, capture: capture), options: .atomic)
    }

    static func loadVoxels(room: UUID, capture: UUID) -> [SurfaceVoxel]? {
        guard let data = try? Data(contentsOf: captureURL(room: room, capture: capture)), data.count >= 12 else { return nil }
        let bytes = [UInt8](data)
        guard String(bytes: bytes[0..<4], encoding: .utf8) == "LUMV" else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        let count = Int(u32(8))
        guard bytes.count >= 12 + count * 28 else { return nil }
        var out: [SurfaceVoxel] = []
        out.reserveCapacity(count)
        for n in 0..<count {
            let o = 12 + n * 28
            let f = (0..<6).map { Float(bitPattern: u32(o + 4 * $0)) }
            out.append(SurfaceVoxel(position: Vec3(f[0], f[1], f[2]), radiance: Vec3(f[3], f[4], f[5]),
                                    samples: Int32(bitPattern: u32(o + 24))))
        }
        return out
    }

    static func deleteVoxels(room: UUID, capture: UUID) {
        try? FileManager.default.removeItem(at: captureURL(room: room, capture: capture))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    // MARK: World map

    static func saveWorldMap(_ map: ARWorldMap, room: UUID) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        try data.write(to: worldMapURL(room), options: .atomic)
    }

    static func loadWorldMap(room: UUID) -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL(room)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    static func deleteWorldMap(room: UUID) {
        try? FileManager.default.removeItem(at: worldMapURL(room))
    }
}
