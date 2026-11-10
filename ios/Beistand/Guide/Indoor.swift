import Foundation
import simd

/// The floor in front of the person, from LiDAR: steps, stairs, and edges where the floor ends
/// (a balcony, a stairwell, a platform edge). Always spoken: a fall is the worst thing that can happen.
/// Pure, testable.
enum GroundProfile {
    enum Event: Equatable {
        case stepUp(distance: Float, height: Float)
        case stepDown(distance: Float, height: Float)
        case stairsUp(distance: Float)
        case stairsDown(distance: Float)
        case drop(distance: Float)          // no floor ahead (or far below): stop
    }

    static let binSize: Float = 0.25
    static let corridor: Float = 0.35       // half width of the walking path
    static let range: ClosedRange<Float> = 0.4...3.0
    static let stepMin: Float = 0.08        // a kerb or a single step
    static let stepMax: Float = 0.45        // more than this is a drop, not a step

    /// Floor height in each 25 cm bin ahead (lowest point in the walking path); nil = no floor seen.
    static func floor(points: [SIMD3<Float>], camera: SIMD3<Float>, forward: SIMD3<Float>) -> [Float?] {
        var f = SIMD3<Float>(forward.x, 0, forward.z)
        guard simd_length(f) > 1e-3 else { return [] }
        f = simd_normalize(f)
        let right = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
        let count = Int((range.upperBound - range.lowerBound) / binSize)
        var bins = [Float?](repeating: nil, count: count)
        for p in points {
            let rel = p - camera
            let ahead = simd_dot(rel, f)
            guard range.contains(ahead), abs(simd_dot(rel, right)) <= corridor else { continue }
            guard p.y < camera.y - 0.6 else { continue }          // floor-ish only, not walls at eye height
            let i = min(count - 1, Int((ahead - range.lowerBound) / binSize))
            bins[i] = min(bins[i] ?? .infinity, p.y)
        }
        return bins
    }

    /// The nearest thing to warn about, reading the floor from near to far.
    static func analyze(_ bins: [Float?]) -> Event? {
        // Held upright the phone sees the floor only from ~2 m on: start where the floor first shows.
        guard let first = bins.firstIndex(where: { $0 != nil }), let start = bins[first] else { return nil }
        var level = start
        var steps: [(i: Int, dh: Float)] = []
        var missing = 0
        for i in (first + 1)..<bins.count {
            guard let h = bins[i] else {
                missing += 1
                // Two bins (50 cm) without any floor right after floor: an edge.
                if missing >= 2, steps.isEmpty { return .drop(distance: dist(i - 1)) }
                continue
            }
            missing = 0
            let dh = h - level
            if dh < -stepMax { return steps.isEmpty ? .drop(distance: dist(i)) : summarize(steps) }
            if abs(dh) >= stepMin {
                steps.append((i, dh))
                level = h
            }
        }
        return steps.isEmpty ? nil : summarize(steps)
    }

    private static func summarize(_ steps: [(i: Int, dh: Float)]) -> Event {
        let first = steps[0]
        let sameWay = steps.filter { ($0.dh > 0) == (first.dh > 0) }.count
        if sameWay >= 2 { return first.dh > 0 ? .stairsUp(distance: dist(first.i)) : .stairsDown(distance: dist(first.i)) }
        return first.dh > 0 ? .stepUp(distance: dist(first.i), height: first.dh) : .stepDown(distance: dist(first.i), height: -first.dh)
    }

    private static func dist(_ i: Int) -> Float { range.lowerBound + Float(i) * binSize }

    static func phrase(_ e: Event) -> String {
        func m(_ d: Float) -> String {
            let v = max(0.5, (d * 2).rounded() / 2)
            let s = v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
            return tr("\(s) \(v == 1 ? "metre" : "metres")", "\(s) Meter")
        }
        switch e {
        case .stepUp(let d, _): return tr("Step up in \(m(d)).", "Stufe hoch in \(m(d)).")
        case .stepDown(let d, _): return tr("Step down in \(m(d)).", "Stufe runter in \(m(d)).")
        case .stairsUp(let d): return tr("Stairs going up in \(m(d)).", "Treppe nach oben in \(m(d)).")
        case .stairsDown(let d): return tr("Careful: stairs going down in \(m(d)).", "Vorsicht: Treppe nach unten in \(m(d)).")
        case .drop(let d): return tr("Stop! No floor ahead, \(m(d)).", "Stopp! Kein Boden vor Ihnen, \(m(d)).")
        }
    }

    /// The kind of change, without the distance, and how far it is.
    static func kind(_ e: Event) -> (String, Float) {
        switch e {
        case .stepUp(let d, _): ("stepUp", d)
        case .stepDown(let d, _): ("stepDown", d)
        case .stairsUp(let d): ("stairsUp", d)
        case .stairsDown(let d): ("stairsDown", d)
        case .drop(let d): ("drop", d)
        }
    }

    /// Say it again only when it is a different kind, a full metre closer, or 8 s later (3 s when urgent).
    static func shouldSay(_ e: Event, last: (kind: String, distance: Float, at: TimeInterval)?, now: TimeInterval) -> Bool {
        let (k, d) = kind(e)
        guard let last, last.kind == k else { return true }
        if last.distance - d >= 1 { return true }
        return now - last.at >= (urgent(e) ? 3 : 8)
    }

    static func urgent(_ e: Event) -> Bool {
        switch e {
        case .drop(let d): return d < 2.5
        case .stairsDown(let d), .stepDown(let d, _): return d < 1.2
        default: return false
        }
    }
}

/// A door, window or exit sign the phone found indoors, relative to the person.
struct IndoorThing: Equatable, Identifiable {
    enum Kind: String { case door, window, exitSign, opening }
    let kind: Kind
    let distance: Float
    let angle: Float          // degrees, negative = left
    var label: String? = nil  // e.g. the exit sign's text
    var id: String { "\(kind.rawValue)-\(Int(angle / 10))-\(Int(distance))" }

    var phrase: String {
        let dir = Orientation.words(Double(angle))
        let m = max(1, Int(distance.rounded()))
        switch kind {
        case .door: return tr("Door, \(m) metres, \(dir).", "Tür, \(m) Meter, \(dir).")
        case .opening: return tr("Open doorway, \(m) metres, \(dir).", "Offene Tür, \(m) Meter, \(dir).")
        case .window: return tr("Window or glass door, \(m) metres, \(dir). Careful, it may be a balcony.",
                                "Fenster oder Glastür, \(m) Meter, \(dir). Vorsicht, dahinter kann ein Balkon sein.")
        case .exitSign: return tr("Exit sign, \(dir)\(label.map { ": \($0)" } ?? "").", "Ausgang-Schild, \(dir)\(label.map { ": \($0)" } ?? "").")
        }
    }
}

enum Indoor {
    /// Text that marks a way out.
    static func isExitSign(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["ausgang", "notausgang", "exit", "way out", "sortie", "uscita"].contains { t.contains($0) }
    }

    /// Apple's whole-picture labels that mean "inside a building".
    static func looksIndoors(_ labels: [(String, Float)]) -> Bool {
        let inside = ["interior_room", "kitchen", "bedroom", "living_room", "bathroom", "hallway", "office", "staircase", "interior_shop"]
        return labels.contains { inside.contains($0.0) && $0.1 >= 0.3 }
    }

    /// Where an anchor is, seen from the camera: horizontal distance and angle from where it looks.
    static func relative(_ p: SIMD3<Float>, camera: SIMD3<Float>, forward: SIMD3<Float>) -> (distance: Float, angle: Float)? {
        var f = SIMD3<Float>(forward.x, 0, forward.z)
        guard simd_length(f) > 1e-3 else { return nil }
        f = simd_normalize(f)
        let right = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
        let rel = p - camera
        let ahead = simd_dot(rel, f), side = simd_dot(rel, right)
        return ((ahead * ahead + side * side).squareRoot(), atan2(side, ahead) * 180 / .pi)
    }

    /// What to say first: the nearest exit sign, else the nearest door, else an opening, else a window.
    static func mostUseful(_ things: [IndoorThing]) -> IndoorThing? {
        let order: [IndoorThing.Kind] = [.exitSign, .door, .opening, .window]
        for k in order {
            if let t = things.filter({ $0.kind == k }).min(by: { $0.distance < $1.distance }) { return t }
        }
        return nil
    }
}
