import CoreGraphics
import Foundation
import ImageIO

/// A named thing near the person (from OpenStreetMap via /landmarks).
struct Landmark: Codable, Equatable, Identifiable {
    var name: String
    var kind: String
    var lat: Double
    var lon: Double
    var distance_m: Double?
    var street_bearing: Double?
    var id: String { "\(name)|\(kind)" }
    var coord: Coord { Coord(lat: lat, lon: lon) }
    var isStreet: Bool { street_bearing != nil }
}

/// Where a landmark is, seen from the person and the way the camera points.
struct Seen: Equatable {
    let landmark: Landmark
    let distance: Double        // metres from the person now
    let relative: Double        // degrees, -180 … 180; negative = left
}

/// "What is in the direction I'm pointing?" – pure, so it is testable and works without any AI key.
enum Orientation {
    /// Horizontal field of view of the back camera held upright (about 60° in portrait).
    static let fieldOfView = 60.0

    /// Angle from the camera direction to a bearing, -180 … 180, negative = left.
    static func relative(_ bearing: Double, heading: Double) -> Double {
        var d = (bearing - heading).truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 } else if d > 180 { d -= 360 }
        return d
    }

    /// Clock face, as blind people are taught: 12 ahead, 3 right, 9 left.
    static func clock(_ relative: Double) -> Int {
        let h = Int(((relative + 360).truncatingRemainder(dividingBy: 360) / 30).rounded()) % 12
        return h == 0 ? 12 : h
    }

    static func words(_ relative: Double) -> String {
        switch relative {
        case -12...12: return tr("ahead", "vorne")
        case 12...40: return tr("slightly right", "halb rechts")
        case 40...135: return tr("right", "rechts")
        case -40 ... -12: return tr("slightly left", "halb links")
        case -135 ... -40: return tr("left", "links")
        default: return tr("behind you", "hinter Ihnen")
        }
    }

    static func compass(_ heading: Double) -> String {
        let names = Lang.german ? ["Norden", "Nordosten", "Osten", "Südosten", "Süden", "Südwesten", "Westen", "Nordwesten"]
                                : ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return names[Int(((heading.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45)) % 8]
    }

    /// Everything around, with direction from the camera, nearest first.
    static func around(_ landmarks: [Landmark], here: Coord, heading: Double, within: Double = 150) -> [Seen] {
        landmarks.map { l in
            Seen(landmark: l, distance: Geo.distance(here, l.coord),
                 relative: relative(Geo.bearing(here, l.coord), heading: heading))
        }
        .filter { $0.distance <= within }
        .sorted { $0.distance < $1.distance }
    }

    /// Things inside the camera picture (streets excluded: they are said separately).
    static func inView(_ landmarks: [Landmark], here: Coord, heading: Double, fov: Double = fieldOfView) -> [Seen] {
        around(landmarks, here: here, heading: heading).filter { !$0.landmark.isStreet && abs($0.relative) <= fov / 2 + 5 }
    }

    /// The street the person stands on, and whether they face along it or across it.
    static func streetSentence(_ landmarks: [Landmark], here: Coord, heading: Double) -> String? {
        guard let s = around(landmarks, here: here, heading: heading, within: 30).first(where: { $0.landmark.isStreet }),
              let sb = s.landmark.street_bearing else { return nil }
        var diff = abs(heading - sb).truncatingRemainder(dividingBy: 180)
        if diff > 90 { diff = 180 - diff }
        return diff < 30 ? tr("You are facing along \(s.landmark.name).", "Sie schauen entlang der \(s.landmark.name).")
                         : tr("\(s.landmark.name) runs across in front of you.", "Die \(s.landmark.name) verläuft quer vor Ihnen.")
    }

    /// One short paragraph for the direction the camera points.
    static func sentence(heading: Double, here: Coord, landmarks: [Landmark], signs: [String] = []) -> String {
        var parts = [tr("Facing \(compass(heading)).", "Blick nach \(compass(heading)).")]
        if let s = streetSentence(landmarks, here: here, heading: heading) { parts.append(s) }
        let matched = matchSigns(signs, landmarks: landmarks)
        for (sign, l) in matched.prefix(1) {
            let d = Int(Geo.distance(here, l.coord).rounded())
            parts.append(tr("I can read \"\(sign)\": that is \(l.name), \(l.kind), \(d) metres.",
                            "Ich lese „\(sign)“: das ist \(l.name), \(l.kind), \(d) Meter."))
        }
        let seen = inView(landmarks, here: here, heading: heading)
            .filter { s in !matched.contains { $0.1 == s.landmark } }
            .prefix(3)
        if seen.isEmpty, matched.isEmpty {
            parts.append(tr("Nothing named on the map in this direction.", "In dieser Richtung ist nichts Benanntes auf der Karte."))
        }
        for s in seen {
            let what = s.landmark.name == s.landmark.kind ? s.landmark.name : "\(s.landmark.name), \(s.landmark.kind)"
            parts.append(tr("\(words(s.relative).capitalizedFirst): \(what), \(Int(s.distance.rounded())) metres.",
                            "\(words(s.relative).capitalizedFirst): \(what), \(Int(s.distance.rounded())) Meter."))
        }
        return parts.joined(separator: " ")
    }

    /// Text the phone read (shop signs, street signs) that matches a nearby place.
    static func matchSigns(_ signs: [String], landmarks: [Landmark]) -> [(String, Landmark)] {
        var out: [(String, Landmark)] = []
        for sign in signs {
            let s = sign.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 4 else { continue }
            if let l = landmarks.first(where: { l in
                let n = l.name.lowercased()
                return n.contains(s) || s.contains(n) || n.split(separator: " ").contains { $0.count >= 5 && s.contains($0) }
            }), !out.contains(where: { $0.1 == l }) {
                out.append((sign, l))
            }
        }
        return out
    }

    /// Map facts for the AI picture description ("Rossmann (drugstore), 20 m slightly right").
    static func grounding(_ landmarks: [Landmark], here: Coord, heading: Double?) -> [String] {
        let list = heading.map { around(landmarks, here: here, heading: $0, within: 120) }
            ?? landmarks.map { Seen(landmark: $0, distance: Geo.distance(here, $0.coord), relative: 0) }.sorted { $0.distance < $1.distance }
        return list.prefix(12).map { s in
            let dir = heading == nil ? "" : " " + words(s.relative)
            return "\(s.landmark.name) (\(s.landmark.kind)), \(Int(s.distance.rounded())) m\(dir)"
        }
    }
}

/// When to speak while the person sweeps the phone around: after turning at least `minTurn`
/// and holding still for `settle` seconds. Pure, testable.
struct SweepPolicy {
    var minTurn = 25.0
    var settle: TimeInterval = 0.6
    private(set) var spokenHeading: Double?
    private var candidate: Double?
    private var candidateSince: TimeInterval = 0

    /// Returns the heading to describe now, or nil.
    mutating func feed(heading: Double, at t: TimeInterval) -> Double? {
        if let c = candidate, abs(Orientation.relative(heading, heading: c)) < 8 {
            if t - candidateSince >= settle {
                if let s = spokenHeading, abs(Orientation.relative(c, heading: s)) < minTurn { return nil }
                spokenHeading = c
                return c
            }
            return nil
        }
        candidate = heading
        candidateSince = t
        return nil
    }

    mutating func reset() { spokenHeading = nil; candidate = nil }
}

/// How the phone is held, from gravity (CoreMotion, device axes: x right, y up, z out of the screen).
enum PhoneHold: String, Equatable {
    case portrait, upsideDown, topLeft, topRight

    static func from(gx: Double, gy: Double) -> PhoneHold {
        if abs(gx) > abs(gy) { return gx < 0 ? .topLeft : .topRight }
        return gy <= 0 ? .portrait : .upsideDown
    }

    /// Orientation of the camera sensor's raw (landscape) buffer, e.g. ARKit's capturedImage.
    var rawOrientation: CGImagePropertyOrientation {
        switch self { case .portrait: .right; case .upsideDown: .left; case .topLeft: .up; case .topRight: .down }
    }

    /// Orientation of a buffer that is already turned to portrait (CameraFeed).
    var portraitBufferOrientation: CGImagePropertyOrientation {
        switch self { case .portrait: .up; case .upsideDown: .down; case .topLeft: .left; case .topRight: .right }
    }

    /// Normalised point of the oriented picture (Vision: origin bottom-left) → raw buffer (origin top-left).
    static func rawPoint(_ o: CGImagePropertyOrientation, x: Double, y: Double) -> (u: Double, v: Double) {
        switch o {
        case .right: (1 - y, 1 - x)
        case .left: (y, x)
        case .down: (1 - x, y)
        default: (x, 1 - y)
        }
    }
}

/// Where the back camera points up or down, and a spoken hint when it is useless for orientation.
enum CameraAim {
    /// Pitch of the back camera in degrees from gravity: 0 = horizon, -90 = straight down, +90 = sky.
    static func pitch(gz: Double) -> Double { asin(max(-1, min(1, gz))) * 180 / .pi }

    static func hint(pitch: Double) -> String? {
        if pitch < -50 { return tr("Raise the phone a little, it points at the ground.", "Heben Sie das Telefon etwas an, es zeigt auf den Boden.") }
        if pitch > 40 { return tr("Lower the phone a little, it points at the sky.", "Senken Sie das Telefon etwas, es zeigt in den Himmel.") }
        return nil
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
