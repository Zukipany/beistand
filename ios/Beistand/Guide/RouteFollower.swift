import Foundation

struct Coord: Equatable, Codable {
    var lat: Double
    var lon: Double
}

/// Local flat-earth geometry; fine for walking distances.
enum Geo {
    static let earth = 6_371_000.0

    static func distance(_ a: Coord, _ b: Coord) -> Double {
        let (x, y) = offset(from: a, to: b)
        return (x * x + y * y).squareRoot()
    }

    /// Metres east (x) and north (y) of `origin`.
    static func offset(from origin: Coord, to p: Coord) -> (Double, Double) {
        let x = (p.lon - origin.lon) * .pi / 180 * earth * cos(origin.lat * .pi / 180)
        let y = (p.lat - origin.lat) * .pi / 180 * earth
        return (x, y)
    }

    /// Compass bearing from a to b in degrees (0 = north).
    static func bearing(_ a: Coord, _ b: Coord) -> Double {
        let (x, y) = offset(from: a, to: b)
        let deg = atan2(x, y) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Shortest distance from p to the segment a–b.
    static func distance(_ p: Coord, toSegment a: Coord, _ b: Coord) -> Double {
        let (bx, by) = offset(from: a, to: b)
        let (px, py) = offset(from: a, to: p)
        let len2 = bx * bx + by * by
        guard len2 > 0 else { return (px * px + py * py).squareRoot() }
        let t = max(0, min(1, (px * bx + py * by) / len2))
        let dx = px - t * bx, dy = py - t * by
        return (dx * dx + dy * dy).squareRoot()
    }

    static func distance(_ p: Coord, toPolyline line: [Coord]) -> Double {
        guard line.count > 1 else { return line.first.map { distance(p, $0) } ?? .infinity }
        return zip(line, line.dropFirst()).map { distance(p, toSegment: $0, $1) }.min() ?? .infinity
    }

    /// "rechts", "halb links", … for a target bearing relative to the way the person faces.
    static func relative(target: Double, heading: Double) -> String {
        var d = (target - heading).truncatingRemainder(dividingBy: 360)
        if d < -180 { d += 360 } else if d > 180 { d -= 360 }
        switch d {
        case -20...20: return tr("straight ahead", "geradeaus")
        case 20...60: return tr("half right", "halb rechts")
        case 60...120: return tr("right", "rechts")
        case -60 ... -20: return tr("half left", "halb links")
        case -120 ... -60: return tr("left", "links")
        default: return tr("behind you", "hinter Ihnen")
        }
    }
}

struct RouteStep: Codable, Equatable {
    var instruction: String
    var distance_m: Double
    var lat: Double
    var lon: Double
    var coord: Coord { Coord(lat: lat, lon: lon) }
}

/// Follows a walking route: which step is next, when to announce it, and when the person has left the route.
/// A traffic-light crossing on the route, from the city's data, with its signal for blind people.
struct RouteCrossing: Codable, Equatable {
    let signal: String          // "sound" | "tactile" | "none"
    let name: String?
    let lat: Double
    let lon: Double
    let say: String
    var coord: Coord { Coord(lat: lat, lon: lon) }
}

struct RouteFollower {
    enum Event: Equatable {
        case announce(String)       // say this now
        case crossing(String)       // a traffic-light crossing is close: say this
        case offRoute(Double)       // metres from the route → re-plan
        case arrived
    }

    let destinationName: String
    let steps: [RouteStep]
    let line: [Coord]
    var crossings: [RouteCrossing] = []
    var crossingWithin = 25.0
    private var crossingsAnnounced: Set<Int> = []
    var offRouteLimit = 25.0
    var announceWithin = 15.0
    var arriveWithin = 10.0

    private(set) var next = 1             // index of the next step to reach (0 is the start)
    private var announced: Set<Int> = [0]
    private var offRouteCount = 0
    private(set) var done = false

    init(destinationName: String, steps: [RouteStep], line: [Coord]) {
        self.destinationName = destinationName
        self.steps = steps
        self.line = line.isEmpty ? steps.map(\.coord) : line
    }

    var firstInstruction: String { steps.first?.instruction ?? "" }

    /// Feed each GPS fix. Returns what to say or do, if anything.
    mutating func update(_ p: Coord, accuracy: Double = 10) -> Event? {
        guard !done, !steps.isEmpty else { return nil }

        // Off route: two fixes in a row clearly away from the line (allow for GPS error).
        let away = Geo.distance(p, toPolyline: line)
        if away > offRouteLimit + max(0, accuracy - 10) {
            offRouteCount += 1
            if offRouteCount >= 2 { offRouteCount = 0; return .offRoute(away) }
            return nil
        }
        offRouteCount = 0

        // Skip ahead past steps already passed (GPS can jump).
        while next < steps.count - 1,
              Geo.distance(p, steps[next + 1].coord) < Geo.distance(p, steps[next].coord),
              Geo.distance(p, steps[next].coord) < 40 {
            next += 1
        }

        let target = steps[min(next, steps.count - 1)].coord
        let d = Geo.distance(p, target)

        if next >= steps.count - 1, d <= arriveWithin {
            done = true
            return .arrived
        }
        if next < steps.count - 1, d <= announceWithin, !announced.contains(next) {
            announced.insert(next)
            let text = steps[next].instruction
            next += 1
            return .announce(text)
        }
        // Crossings: once each, about 25 m before (steps take priority).
        if let i = crossings.indices.first(where: { !crossingsAnnounced.contains($0) && Geo.distance(p, crossings[$0].coord) <= crossingWithin }) {
            crossingsAnnounced.insert(i)
            return .crossing(crossings[i].say)
        }
        return nil
    }

    /// One line of context for the live guide.
    func context(at p: Coord, heading: Double?) -> String {
        guard !steps.isEmpty else { return "" }
        let idx = min(next, steps.count - 1)
        let target = steps[idx].coord
        let d = Int(Geo.distance(p, target).rounded())
        var s = tr("Destination: \(destinationName). Next point in \(d) m", "Ziel: \(destinationName). Nächster Punkt in \(d) m")
        if let heading { s += ", \(Geo.relative(target: Geo.bearing(p, target), heading: heading))" }
        s += tr(". There: ", ". Dort: ") + steps[idx].instruction
        return s
    }
}
