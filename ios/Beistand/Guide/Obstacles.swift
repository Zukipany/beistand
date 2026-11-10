import AVFoundation
import Foundation
import simd
import UIKit

/// Nearest obstacle ahead in three lanes of the walking direction, in metres. nil = nothing within range.
struct ObstacleZones: Equatable, Codable {
    var left: Float?
    var centre: Float?
    var right: Float?
}

/// Turns LiDAR points into "what is in my way". Pure, so it is testable without a phone.
///
/// The walking corridor is the phone's forward direction flattened to the ground, 0.8 m wide.
/// Points on the ground (and just above it, like a kerb's edge) are ignored, and so is anything
/// above head height, so a shop sign overhead does not beep.
enum ObstacleGeometry {
    static let corridorHalfWidth: Float = 0.4
    static let sideWidth: Float = 0.8          // each side lane, outside the corridor
    static let minHeight: Float = 0.15         // above the floor
    static let maxHeight: Float = 2.0          // head height plus a little
    static let range: ClosedRange<Float> = 0.2...5.0

    /// - Parameters:
    ///   - points: world positions (metres, y up), e.g. from LiDAR depth.
    ///   - camera: the phone's world position.
    ///   - forward: the direction the phone points (any length; the vertical part is ignored).
    ///   - floorY: world height of the ground.
    static func zones(points: [SIMD3<Float>], camera: SIMD3<Float>, forward: SIMD3<Float>, floorY: Float) -> ObstacleZones {
        var f = SIMD3<Float>(forward.x, 0, forward.z)
        guard simd_length(f) > 1e-3 else { return ObstacleZones() }
        f = simd_normalize(f)
        let right = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
        var z = ObstacleZones()
        for p in points {
            let h = p.y - floorY
            guard h > minHeight, h < maxHeight else { continue }
            let rel = p - camera
            let ahead = simd_dot(rel, f)
            guard range.contains(ahead) else { continue }
            let side = simd_dot(rel, right)
            if abs(side) <= corridorHalfWidth {
                z.centre = min(z.centre ?? .infinity, ahead)
            } else if side < 0, side >= -(corridorHalfWidth + sideWidth) {
                z.left = min(z.left ?? .infinity, ahead)
            } else if side > 0, side <= corridorHalfWidth + sideWidth {
                z.right = min(z.right ?? .infinity, ahead)
            }
        }
        return z
    }

    /// Unprojects one depth pixel into world space. ARKit camera space: x right, y up, looking along -z;
    /// depth image rows go down. `intrinsics` are scaled to the depth image size.
    static func worldPoint(u: Float, v: Float, depth: Float, fx: Float, fy: Float, cx: Float, cy: Float,
                           cameraTransform: simd_float4x4) -> SIMD3<Float> {
        let local = SIMD4<Float>((u - cx) / fx * depth, -(v - cy) / fy * depth, -depth, 1)
        let w = cameraTransform * local
        return SIMD3<Float>(w.x, w.y, w.z)
    }
}

/// How often to beep for the nearest obstacle straight ahead, like a parking sensor.
enum BeepTiming {
    static let start: Float = 2.0          // silent beyond this
    static let urgent: Float = 0.5         // fastest at or below this

    /// Seconds between beeps, or nil for silence.
    static func interval(for distance: Float?) -> TimeInterval? {
        guard let d = distance, d < start else { return nil }
        if d <= urgent { return 0.1 }
        let t = (d - urgent) / (start - urgent)          // 0 near … 1 far
        return 0.1 + TimeInterval(t) * 0.6               // 0.1 s … 0.7 s
    }
}

/// Something the on-phone detector found, with distance from LiDAR.
struct SeenObject: Equatable, Codable {
    enum Side: String, Codable { case left, ahead, right }
    var label: String           // one of ObjectAlerts.names keys
    var distance: Float
    var side: Side
    var box: CGRect? = nil      // where in the picture (normalised, origin bottom-left), for the live view
}

/// Decides what to say about detected objects: short fixed phrases, nearest first, no repeats.
/// These are warnings, so they never come from a language model. Pure, testable.
struct ObjectAlerts {
    var announceWithin: Float = 4.0
    var peopleWithin: Float = 1.5           // crowds would otherwise talk all the time
    var repeatAfter: TimeInterval = 8
    var minGap: TimeInterval = 2
    /// Calm mode: only things in the walking path.
    var onlyAhead = false
    private var lastSaid: [String: TimeInterval] = [:]
    private var lastAny: TimeInterval = -.infinity

    static let names: [String: (en: String, de: String)] = [
        "bicycle": ("Bike", "Fahrrad"), "scooter": ("Scooter", "Roller"), "car": ("Car", "Auto"),
        "bus": ("Bus", "Bus"), "tram": ("Tram", "Tram"), "person": ("Person", "Person"),
        "dog": ("Dog", "Hund"), "pole": ("Pole", "Pfosten"), "bench": ("Bench", "Bank"),
        "stairs": ("Steps", "Stufen"), "door": ("Door", "Tür"), "sign": ("Sign", "Schild"),
        "bin": ("Bin", "Mülleimer"), "obstacle": ("Obstacle", "Hindernis"),
    ]

    /// Returns at most one sentence for this moment.
    mutating func feed(_ objects: [SeenObject], at t: TimeInterval) -> String? {
        guard t - lastAny >= minGap else { return nil }
        let candidates = objects
            .filter { $0.distance <= ($0.label == "person" ? peopleWithin : announceWithin) }
            .filter { !onlyAhead || $0.side == .ahead }
            .filter { t - (lastSaid[key($0)] ?? -.infinity) >= repeatAfter }
            .sorted { rank($0) < rank($1) }
        guard let o = candidates.first else { return nil }
        lastSaid[key(o)] = t
        lastAny = t
        return Self.phrase(o)
    }

    private func key(_ o: SeenObject) -> String { "\(o.label)-\(o.side.rawValue)" }
    /// Things in the walking path first, then by distance.
    private func rank(_ o: SeenObject) -> Float { o.distance + (o.side == .ahead ? 0 : 1.5) }

    static func phrase(_ o: SeenObject) -> String {
        let n = names[o.label] ?? names["obstacle"]!
        let metres = max(1, Int(o.distance.rounded()))
        let side: String
        switch o.side {
        case .left: side = tr("left", "links")
        case .right: side = tr("right", "rechts")
        case .ahead: side = tr("ahead", "vorne")
        }
        return tr("\(n.en), \(metres) \(metres == 1 ? "metre" : "metres"), \(side).",
                  "\(n.de), \(metres) \(metres == 1 ? "Meter" : "Meter"), \(side).")
    }

    /// Maps a classifier label (Apple's taxonomy) to our short list, or nil if irrelevant.
    static func normalise(_ identifier: String) -> String? {
        let s = identifier.lowercased()
        let table: [(String, [String])] = [
            ("bicycle", ["bicycle", "bike"]), ("scooter", ["scooter", "moped"]), ("bus", ["bus"]),
            ("tram", ["tram", "streetcar", "train"]), ("car", ["car", "vehicle", "automobile", "taxi", "van", "truck"]),
            ("dog", ["dog"]), ("bench", ["bench"]), ("stairs", ["stair", "step"]), ("door", ["door"]),
            ("pole", ["pole", "post", "bollard", "lamppost", "pillar"]), ("sign", ["sign"]),
            ("bin", ["trash", "garbage", "bin"]), ("person", ["person", "people", "human"]),
        ]
        return table.first { _, keys in keys.contains { s.contains($0) } }?.0
    }
}

/// Plays the parking-sensor beep. Ahead only; side obstacles are spoken, not beeped.
/// Seizure mode does not matter here (sound only); hearing mode gets the haptic tick only.
final class Beeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var timer: Timer?
    private var interval: TimeInterval?
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    var sound = true
    var enabled = true { didSet { if !enabled { update(nil) } } }

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(0.04 * format.sampleRate)          // 40 ms click
        if let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            b.frameLength = frames
            for i in 0..<Int(frames) {
                let env = sin(Float.pi * Float(i) / Float(frames))          // no clicks at the edges
                b.floatChannelData![0][i] = sin(2 * .pi * 1400 * Float(i) / Float(format.sampleRate)) * 0.5 * env
            }
            buffer = b
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Call with the nearest distance ahead, as often as new depth arrives.
    func update(_ distance: Float?) {
        let next = enabled ? BeepTiming.interval(for: distance) : nil
        guard next != interval else { return }
        interval = next
        timer?.invalidate()
        timer = nil
        guard let next else { return }
        if sound, !engine.isRunning { try? engine.start() }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: next, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        haptic.impactOccurred(intensity: 0.7)
        guard sound, let buffer, engine.isRunning else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    func stop() {
        update(nil)
        player.stop()
        engine.stop()
    }
}

/// What the phone recognised during the last few minutes, with where the person was, so the guide
/// can answer "where was the bench?". Pure, testable.
struct SceneMemory {
    struct Sighting: Equatable {
        let object: SeenObject
        let at: TimeInterval
        let position: Coord?
    }

    var keep: TimeInterval = 180
    private(set) var sightings: [Sighting] = []

    mutating func add(_ objects: [SeenObject], at t: TimeInterval, position: Coord?) {
        sightings.removeAll { t - $0.at > keep }
        for o in objects where o.label != "obstacle" {
            // One entry per thing per 10 s, so standing next to a bench doesn't fill the memory.
            if let last = sightings.last(where: { $0.object.label == o.label }), t - last.at < 10 { continue }
            sightings.append(Sighting(object: o, at: t, position: position))
        }
    }

    /// The label the person means: "bench", "Bank", "the bikes" → "bench", "bench", "bicycle".
    static func label(for words: String) -> String? {
        let w = words.lowercased()
        for (key, n) in ObjectAlerts.names where w.contains(n.en.lowercased()) || w.contains(n.de.lowercased()) {
            return key
        }
        return ObjectAlerts.normalise(w)
    }

    /// A sentence for the guide (and the person).
    func answer(_ words: String, now: TimeInterval, here: Coord?) -> String {
        guard let label = Self.label(for: words) else {
            return tr("I don't know that kind of thing yet. I can remember benches, doors, steps, bikes, scooters, poles, signs and people.",
                      "Das kenne ich noch nicht. Ich merke mir Bänke, Türen, Stufen, Fahrräder, Roller, Pfosten, Schilder und Personen.")
        }
        let n = ObjectAlerts.names[label] ?? ObjectAlerts.names["obstacle"]!
        guard let s = sightings.last(where: { $0.object.label == label && now - $0.at <= keep }) else {
            return tr("I haven't noticed a \(n.en.lowercased()) in the last \(Int(keep / 60)) minutes.",
                      "Ich habe in den letzten \(Int(keep / 60)) Minuten kein(e) \(n.de) bemerkt.")
        }
        let secs = Int(now - s.at)
        var where_ = ""
        if let p = s.position, let here {
            let d = Int(Geo.distance(here, p).rounded())
            where_ = d < 5 ? tr(", right around here", ", genau hier in der Nähe")
                           : tr(", about \(d) metres from here", ", etwa \(d) Meter von hier")
        }
        let ago = secs < 10 ? tr("just now", "gerade eben") : tr("\(secs) seconds ago", "vor \(secs) Sekunden")
        return tr("I noticed a \(n.en.lowercased()) \(ago)\(where_). It was \(Int(s.object.distance.rounded())) metres \(s.object.side.rawValue) of you then.",
                  "Ich habe \(ago) ein(e) \(n.de) bemerkt\(where_). Es war damals \(Int(s.object.distance.rounded())) Meter \(s.object.side == .left ? "links" : s.object.side == .right ? "rechts" : "vorne").")
    }
}
