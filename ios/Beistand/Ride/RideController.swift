import CoreMotion
import Foundation
import Observation
import UIKit

/// The ride helper: plans the trip to a station, then follows it underground and tells the person
/// the next stop, warns one stop before (strong vibration), and says when to get off and where to change.
@MainActor
@Observable
final class RideController {
    static let shared = RideController()

    /// waiting: on the platform (boarding help); riding: on the train; arrived: get off, guide out.
    enum Phase: Equatable { case choosing, planning, waiting, riding, arrived }
    struct Station: Decodable, Identifiable, Equatable { let id: String; let name: String; let place: String? }

    private(set) var phase = Phase.choosing
    private(set) var tracker: RideTracker?
    private(set) var headline = ""            // the big line on screen
    private(set) var detail = ""
    private(set) var getOffNow = false        // red screen
    private(set) var results: [Station] = []
    private(set) var problem: String?
    var requestedOpen = false
    /// Where the person wants to go after the ride (a place from the guide), so "Guide me out" continues there.
    var afterRide: GuideAPI.Place?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var saidRelax = false
    // Dev: a sped-up ride on a clock that runs `speed` times faster.
    @ObservationIgnored private var speed = 1.0
    @ObservationIgnored private var clockStart = Date()
    @ObservationIgnored private var tripStart = 0.0
    private(set) var simulated = false

    private var now: Double { simulated ? tripStart + Date().timeIntervalSince(clockStart) * speed : Date().timeIntervalSince1970 }

    // MARK: choosing the station

    func search(_ q: String) async {
        guard q.count >= 2 else { results = []; return }
        struct R: Decodable { let data: [Station] }
        results = (try? await GuideAPI.get("stations/search", ["q": q]) as R)?.data ?? []
    }

    /// Plan from the nearest station to `station`, then follow the ride.
    func start(to station: Station, simulate: Bool = false) {
        phase = .planning
        problem = nil
        headline = tr("Planning the trip to \(station.name) …", "Plane die Fahrt nach \(station.name) …")
        Task {
            var q = ["to_id": station.id]
            if let l = await LocationService.shared.current() {
                q["lat"] = "\(l.coordinate.latitude)"; q["lon"] = "\(l.coordinate.longitude)"
            } else {
                q["lat"] = "48.1374"; q["lon"] = "11.5755"           // no location: Marienplatz
            }
            struct R: Decodable { let data: RideTrip }
            do {
                let r: R = try await GuideAPI.get("trip", q)
                begin(r.data, simulate: simulate)
            } catch {
                phase = .choosing
                problem = tr("I can't plan this trip right now.", "Ich kann diese Fahrt gerade nicht planen.")
                Speaker.shared.say(problem!)
            }
        }
    }

    func begin(_ trip: RideTrip, simulate: Bool = false) {
        guard let first = trip.legs.first else { return }
        tracker = RideTracker(trip: trip)
        simulated = simulate
        speed = simulate ? 20 : 1
        clockStart = Date()
        tripStart = (first.from.time ?? Date().timeIntervalSince1970) - (simulate ? 20 : 0)
        phase = .waiting
        saidRelax = false
        getOffNow = false
        let stops = first.all.count - 1
        let platform = first.from.platform.map { tr(", platform \($0)", ", Gleis \($0)") } ?? ""
        headline = "\(first.line ?? "") → \(first.direction ?? "")"
        let text = tr("Take the \(first.line ?? "train") towards \(first.direction ?? "")\(platform). \(stops) stops to \(first.to.name).",
                      "Nehmen Sie die \(first.line ?? "Bahn") Richtung \(first.direction ?? "")\(platform). \(stops) Stationen bis \(first.to.name).")
        detail = text
        Speaker.shared.say(text)
        startFollowing()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        timer?.invalidate(); timer = nil
        TrainMotionWatcher.shared.onChange = nil
        LocationService.shared.onRide = nil
        tracker = nil
        phase = .choosing
        getOffNow = false
        simulated = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// "Where am I?" during the ride.
    func sayStatus() {
        guard let t = tracker, let leg = t.current else { Speaker.shared.say(headline); return }
        let next = t.nextStop?.name ?? leg.to.name
        let left = t.stopsLeft
        Speaker.shared.say(tr("\(leg.line ?? "") towards \(leg.direction ?? ""). Next: \(next). \(left) \(left == 1 ? "stop" : "stops") to \(leg.to.name).",
                              "\(leg.line ?? "") Richtung \(leg.direction ?? ""). Nächste: \(next). Noch \(left) bis \(leg.to.name)."))
    }

    /// A station sign the camera read (guide camera or the ride screen's camera).
    func saw(_ text: String) { handle(tracker?.saw(text)) }

    // MARK: following

    private func startFollowing() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        guard !simulated else { return }
        // Feel the train: moving → "relax"; stopping when a stop is due → that stop.
        TrainMotionWatcher.shared.start()
        TrainMotionWatcher.shared.onChange = { [weak self] s in
            guard let self else { return }
            switch s {
            case .riding: self.departed()
            case .still: if self.phase == .riding { self.handle(self.tracker?.feltStop(now: self.now)) }
            default: break
            }
        }
        // Where there is location (stations, S-Bahn above ground), reaching a station moves the ride there.
        LocationService.shared.setTracking(true)
        LocationService.shared.onRide = { [weak self] l in
            guard let self, self.phase == .riding || self.phase == .waiting else { return }
            let p = Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
            if self.phase == .waiting, (self.tracker?.trip.legs.first?.from.coord).map({ Geo.distance($0, p) > 250 }) == true {
                self.departed()
            }
            self.handle(self.tracker?.reached(p, accuracy: l.horizontalAccuracy))
        }
    }

    /// The train has left with the person on it: say once how long, then stay quiet until one stop before.
    func departed() {
        guard phase == .waiting else { return }
        phase = .riding
        GuideController.shared.boardingDone()
        guard !saidRelax, let t = tracker, let leg = t.current else { return }
        saidRelax = true
        let n = t.stopsLeft
        headline = "\(leg.line ?? "") → \(leg.direction ?? "")"
        say(tr("You're on your way. Relax: \(n) \(n == 1 ? "stop" : "stops") to \(leg.to.name). I'll tell you one stop before.",
               "Sie sind unterwegs. Entspannen Sie sich: \(n) \(n == 1 ? "Station" : "Stationen") bis \(leg.to.name). Ich sage eine Station vorher Bescheid."))
    }

    /// At the platform: open the camera and find the open door.
    func findDoor() {
        GuideController.shared.boarding = true
        GuideController.shared.requestedOpen = true
    }

    /// After getting off: the camera guide leads to the nearest station exit, then on to `afterRide`.
    func guideOut() {
        let station = tracker?.trip.legs.last?.to
        let then = afterRide
        stop()
        GuideController.shared.leaveStation(at: station?.coord, name: station?.name, then: then)
        GuideController.shared.requestedOpen = true
    }

    private func tick() {
        guard var t = tracker else { return }
        // No motion data (or a Dev ride): the timetable says the train has left.
        if phase == .waiting, let dep = t.current?.from.time, now >= dep + (simulated ? 0 : 60) { departed() }
        let e = t.tick(now: now)
        tracker = t
        handle(e)
        if let next = t.nextStop, let time = next.time {
            let s = max(0, Int(time - now))
            detail = tr("Next: \(next.name) in \(s / 60):\(String(format: "%02d", s % 60)) · \(t.stopsLeft) to \(t.current?.to.name ?? "")",
                        "Nächste: \(next.name) in \(s / 60):\(String(format: "%02d", s % 60)) · noch \(t.stopsLeft) bis \(t.current?.to.name ?? "")")
        }
        // Dev ride: the train "stops" at every station on time.
        if simulated, let next = t.nextStop, let time = next.time, now >= time { handle(tracker?.feltStop(now: now)) }
    }

    private func handle(_ e: RideTracker.Event?) {
        guard let e else { return }
        switch e {
        case .next(let at, let next):
            getOffNow = false
            // Calm: on screen and for VoiceOver; spoken only when the person wants everything.
            detail = tr("\(at). Next: \(next).", "\(at). Nächste: \(next).")
            UIAccessibility.post(notification: .announcement, argument: detail)
            if AppStore.shared.guideDetail == .everything { Speaker.shared.say(detail) }
        case .getReady(let name):
            headline = tr("Next stop: \(name)", "Nächste Station: \(name)")
            RideHaptics.getReady()
            say(tr("Next stop: \(name). Get ready to get off.", "Nächste Station: \(name). Machen Sie sich zum Aussteigen bereit."))
        case .getOff(let name, let change):
            getOffNow = true
            headline = tr("Get off: \(name)", "Aussteigen: \(name)")
            RideHaptics.getOff()
            let next = change.map { c in
                tr(" Change to the \(c.line ?? "") towards \(c.direction ?? "")\(c.from.platform.map { ", platform \($0)" } ?? "").",
                   " Umsteigen in die \(c.line ?? "") Richtung \(c.direction ?? "")\(c.from.platform.map { ", Gleis \($0)" } ?? "").")
            } ?? ""
            say(tr("Get off now: \(name).", "Jetzt aussteigen: \(name).") + next)
            Task { try? await Task.sleep(for: .seconds(20)); getOffNow = false }
        case .arrived(let name):
            getOffNow = true
            phase = .arrived
            headline = tr("Get off: \(name)", "Aussteigen: \(name)")
            RideHaptics.getOff()
            let to = tracker?.trip.legs.last?.to
            var extra = to?.exit.map { tr(" Take exit \($0).", " Nehmen Sie Ausgang \($0).") } ?? ""
            if to?.lift_out_of_order == true { extra += tr(" The lift here is out of order.", " Der Aufzug hier ist außer Betrieb.") }
            if to?.escalator_out_of_order == true { extra += tr(" An escalator is out of order.", " Eine Rolltreppe ist außer Betrieb.") }
            say(tr("Get off now: \(name). You have arrived.", "Jetzt aussteigen: \(name). Sie sind angekommen.") + extra
                + tr(" Then tap Guide me out and I'll lead you to the exit.", " Dann tippen Sie auf Hinausführen, ich führe Sie zum Ausgang."))
            timer?.invalidate(); timer = nil
            TrainMotionWatcher.shared.onChange = nil
            LocationService.shared.onRide = nil
        }
    }

    private func say(_ text: String) {
        detail = text
        Speaker.shared.say(text, interrupt: true)
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// Felt, so it works in a loud train and for deaf people: a long warning one stop before, an
/// unmistakable pattern to get off.
enum RideHaptics {
    static func getReady() {
        let g = UINotificationFeedbackGenerator()
        for i in 0..<2 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) { g.notificationOccurred(.warning) } }
        WatchLink.shared.cue(.arrived)
    }
    static func getOff() {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        for i in 0..<6 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) { g.impactOccurred(intensity: 1) } }
        WatchLink.shared.cue(.arrived)
    }
}
