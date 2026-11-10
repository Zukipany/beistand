import UIKit

/// A parked shared e-scooter or bike (operators' open GBFS feeds, via /scooters).
struct Scooter: Codable, Equatable, Identifiable {
    let id: String
    let lat: Double
    let lon: Double
    let kind: String            // "scooter" | "bike"
    var coord: Coord { Coord(lat: lat, lon: lon) }
}

/// When to vibrate for scooters and bikes: they are what people trip over on the pavement.
/// Felt, not spoken, so it never adds to the talking. Pure, testable.
struct ScooterAlert {
    var cameraAhead: Float = 3.0        // seen by the camera straight ahead within this
    var cameraAround: Float = 1.2       // or anywhere this close
    var mapAhead = 10.0                 // a parked one on the map, walking towards it
    var mapCone = 25.0                  //   within this many degrees of where the person faces
    var mapClose = 2.0                  // or this close on the map (GPS is only good to a few metres)
    var gap: TimeInterval = 3           // at most one vibration this often
    var sameAgain: TimeInterval = 30    // the same parked scooter again only after this
    private var last: TimeInterval = -.infinity
    private var warned: [String: TimeInterval] = [:]

    static let labels: Set<String> = ["scooter", "bicycle"]

    /// Camera: true = vibrate now.
    mutating func feed(_ objects: [SeenObject], at t: TimeInterval) -> Bool {
        guard t - last >= gap else { return false }
        let hit = objects.contains { o in
            Self.labels.contains(o.label) && ((o.side == .ahead && o.distance <= cameraAhead) || o.distance <= cameraAround)
        }
        if hit { last = t }
        return hit
    }

    /// Map: the scooter to warn about now, if any.
    mutating func feed(here: Coord, heading: Double?, scooters: [Scooter], at t: TimeInterval) -> Scooter? {
        guard t - last >= gap else { return nil }
        let hit = scooters
            .filter { t - (warned[$0.id] ?? -.infinity) >= sameAgain }
            .map { ($0, Geo.distance(here, $0.coord)) }
            .filter { s, d in
                if d <= mapClose { return true }
                guard d <= mapAhead, let heading else { return false }
                return abs(Orientation.relative(Geo.bearing(here, s.coord), heading: heading)) <= mapCone
            }
            .min { $0.1 < $1.1 }?.0
        if let hit { last = t; warned[hit.id] = t }
        return hit
    }
}

/// Three quick hard taps: different from the obstacle beeper's single tick and the route's pulses.
enum ScooterHaptics {
    static func warn() {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.prepare()
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.11) { g.impactOccurred(intensity: 1) }
        }
    }
}
