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
}

/// Decides what to say about detected objects: short fixed phrases, nearest first, no repeats.
/// These are warnings, so they never come from a language model. Pure, testable.
struct ObjectAlerts {
    var announceWithin: Float = 4.0
    var peopleWithin: Float = 1.5           // crowds would otherwise talk all the time
    var repeatAfter: TimeInterval = 8
    var minGap: TimeInterval = 2
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
