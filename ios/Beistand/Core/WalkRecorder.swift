import Foundation

/// Records a walk as JSON lines, so it can be replayed in tests without going outside:
/// GPS fixes, obstacle lanes, detected objects and everything the app said.
/// Off by default; switched on in Settings → Diagnostics. Stays on the phone until shared.
final class WalkRecorder {
    static let shared = WalkRecorder()

    struct Entry: Codable, Equatable {
        var t: Double                       // seconds since the walk started
        var kind: String                    // fix | zones | objects | say
        var lat: Double? = nil, lon: Double? = nil, acc: Double? = nil, heading: Double? = nil
        var zones: ObstacleZones? = nil
        var objects: [SeenObject]? = nil
        var text: String? = nil
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "recordWalks") }
        set { UserDefaults.standard.set(newValue, forKey: "recordWalks") }
    }
    private var handle: FileHandle?
    private var started = Date()
    private var lastZones = Date.distantPast
    private let queue = DispatchQueue(label: "beistand.recorder")
    private let encoder = JSONEncoder()

    static var folder: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("walks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func begin() {
        guard enabled, handle == nil else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.folder.appendingPathComponent("walk_\(f.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        started = Date()
    }

    func end() {
        queue.sync { try? handle?.close(); handle = nil }
    }

    func log(_ entry: Entry) {
        guard handle != nil else { return }
        var e = entry
        e.t = (Date().timeIntervalSince(started) * 100).rounded() / 100
        if e.kind == "zones" {                     // 10 per second is more than a test needs
            guard Date().timeIntervalSince(lastZones) >= 0.25 else { return }
            lastZones = Date()
        }
        queue.async { [weak self] in
            guard let self, let h = self.handle, var data = try? self.encoder.encode(e) else { return }
            data.append(0x0A)
            try? h.write(contentsOf: data)
        }
    }

    /// Reads a recorded walk back (for replay tests and the Diagnostics screen).
    static func read(_ text: String) -> [Entry] {
        let d = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? d.decode(Entry.self, from: Data($0.utf8)) }
    }
}
