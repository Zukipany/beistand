import Foundation

/// A trip from /trip: one or more legs (U6 to Münchner Freiheit, then U3 …).
struct RideTrip: Decodable, Equatable {
    struct Stop: Decodable, Equatable {
        let name: String
        var time: Double?           // expected (planned + delay), seconds since 1970
        var platform: Int?
        var exit: String?
        var lift_out_of_order: Bool?
        var escalator_out_of_order: Bool?
        var lat: Double?
        var lon: Double?
        var coord: Coord? { lat.flatMap { la in lon.map { Coord(lat: la, lon: $0) } } }
    }
    struct Leg: Decodable, Equatable {
        let line: String?
        let type: String?
        let direction: String?
        let from: Stop
        let stops: [Stop]
        let to: Stop
        /// Every stop of the leg in order: where you get on … where you get off.
        var all: [Stop] { [from] + stops + [to] }
    }
    let legs: [Leg]
}

/// Follows a ride without GPS: by the timetable, by the stops the phone feels (train stopping),
/// and by station names the camera reads. Says the next stop, warns one stop early, says when
/// to get off and where to change. Pure, testable.
struct RideTracker {
    enum Event: Equatable {
        case next(at: String, next: String)            // "Odeonsplatz. Next: Universität."
        case getReady(String)                          // one stop before: strong vibration
        case getOff(String, change: RideTrip.Leg?)     // now: get off (and change to this leg)
        case arrived(String)                           // last stop of the whole trip reached
    }

    let trip: RideTrip
    private(set) var leg = 0
    private(set) var at = 0                // index in the leg's stops of the last stop reached
    private(set) var finished = false
    private var warned: Set<String> = []
    var lateSlack: TimeInterval = 40       // the timetable alone moves on this long after a stop's time
    var earlySlack: TimeInterval = 90      // a felt stop counts only this close to the next stop's time

    init(trip: RideTrip) { self.trip = trip }

    var current: RideTrip.Leg? { finished || trip.legs.isEmpty ? nil : trip.legs[leg] }
    var nextStop: RideTrip.Stop? { current.flatMap { at + 1 < $0.all.count ? $0.all[at + 1] : nil } }
    var stopsLeft: Int { current.map { $0.all.count - 1 - at } ?? 0 }
    var destination: RideTrip.Stop? { trip.legs.last?.to }

    /// Every second: timetable fallback, and the early warning by time if counting missed a stop.
    mutating func tick(now: Double) -> Event? {
        guard let leg = current, let next = nextStop, let t = next.time else { return nil }
        let last = leg.all.count - 1
        if at + 1 == last, now >= t - 75, !warned.contains(key(last)) {
            warned.insert(key(last))
            return .getReady(next.name)
        }
        if now >= t + lateSlack { return advance() }
        return nil
    }

    /// The train stopped (motion). Counts as reaching the next stop if it is due about now.
    mutating func feltStop(now: Double) -> Event? {
        guard let next = nextStop else { return nil }
        if let t = next.time, now < t - earlySlack { return nil }      // stopped in the tunnel, too early
        return advance()
    }

    /// Location (GPS, Wi-Fi) near a station ahead on this leg moves the ride there.
    mutating func reached(_ p: Coord, accuracy: Double = 50) -> Event? {
        guard let leg = current, accuracy <= 150 else { return nil }
        let radius = max(80, accuracy)
        for i in (at + 1)..<leg.all.count {
            if let c = leg.all[i].coord, Geo.distance(p, c) <= radius {
                var e: Event?
                while at < i, !finished { e = advance() }
                return e
            }
        }
        return nil
    }

    /// The camera read a sign. A station name ahead on this leg moves the ride there.
    mutating func saw(_ text: String) -> Event? {
        guard let leg = current else { return nil }
        let s = Self.norm(text)
        guard s.count >= 4 else { return nil }
        for i in (at + 1)..<leg.all.count where s.contains(Self.norm(leg.all[i].name)) || Self.norm(leg.all[i].name).contains(s) {
            var e: Event?
            while at < i, !finished { e = advance() }
            return e
        }
        return nil
    }

    private mutating func advance() -> Event? {
        guard let leg = current else { return nil }
        at += 1
        let last = leg.all.count - 1
        if at >= last {
            let here = leg.all[last].name
            if self.leg + 1 < trip.legs.count {
                self.leg += 1
                at = 0
                return .getOff(here, change: trip.legs[self.leg])
            }
            finished = true
            return .arrived(here)
        }
        if at + 1 == last, !warned.contains(key(last)) {
            warned.insert(key(last))
            return .getReady(leg.all[last].name)
        }
        return .next(at: leg.all[at].name, next: leg.all[at + 1].name)
    }

    private func key(_ i: Int) -> String { "\(leg):\(i)" }

    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ß", with: "ss").folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}

/// What the camera sees, from Apple's on-phone image labels: inside a train, at a station, on a bus.
enum TransitScene: Equatable {
    case train, station, bus

    static func from(_ labels: [(String, Float)]) -> TransitScene? {
        func conf(_ ids: [String]) -> Float { labels.filter { ids.contains($0.0) }.map(\.1).max() ?? 0 }
        let station = conf(["train_station"])
        let train = conf(["train", "train_real", "monorail", "tramway", "railroad"])
        let bus = conf(["bus"])
        let seats = conf(["seat"])
        if station >= 0.3 { return .station }
        if train >= 0.3 || (train >= 0.15 && seats >= 0.2) { return .train }
        if bus >= 0.3 { return .bus }
        return nil
    }
}
