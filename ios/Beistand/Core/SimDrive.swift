import CoreLocation
import Foundation
import Observation
import UIKit
import WebKit

/// Where the virtual walker is and which way they look.
struct WalkerState: Equatable {
    var position: Coord
    var heading: Double          // compass degrees
    var pitch: Double = 0        // up/down, -30 … 30
}

/// Movement of the virtual walker. Pure, so it is testable.
enum WalkerPhysics {
    static let walkSpeed = 1.4           // m/s, normal walking
    static let fastFactor = 4.0          // hold Shift / push the stick hard to cover ground quickly
    static let turnRate = 90.0           // degrees per second at full turn
    static let pitchRate = 45.0

    /// - Parameters: forward/strafe/turn/look in -1 … 1 (forward = +1, strafe right = +1, turn right = +1, look up = +1).
    static func step(_ s: WalkerState, forward: Double, strafe: Double, turn: Double, look: Double = 0,
                     fast: Bool = false, dt: Double) -> WalkerState {
        var n = s
        n.heading = (s.heading + clamp(turn) * turnRate * dt + 360).truncatingRemainder(dividingBy: 360)
        n.pitch = max(-30, min(30, s.pitch + clamp(look) * pitchRate * dt))
        let speed = walkSpeed * (fast ? fastFactor : 1)
        let h = n.heading * .pi / 180
        // Metres east and north: forward along the heading, strafe 90° to the right of it.
        let east = (sin(h) * clamp(forward) + cos(h) * clamp(strafe)) * speed * dt
        let north = (cos(h) * clamp(forward) - sin(h) * clamp(strafe)) * speed * dt
        n.position = Coord(lat: s.position.lat + north / 111_320,
                           lon: s.position.lon + east / (111_320 * cos(s.position.lat * .pi / 180)))
        return n
    }

    private static func clamp(_ v: Double) -> Double { max(-1, min(1, v)) }
}

enum SimEstimate {
    /// Distance to something of known height from how tall its box is in the picture.
    static func distance(boxHeight: Double, realHeight: Double, verticalFOV: Double) -> Double {
        guard boxHeight > 0.01 else { return 50 }
        let visible = 2 * tan(verticalFOV / 2 * .pi / 180)          // picture height in metres at 1 m distance
        return min(50, realHeight / (boxHeight * visible))
    }

    /// Fetch a new street picture only after moving or turning enough (and not more often than every 0.4 s).
    static func needsPicture(last: WalkerState?, now: WalkerState, minMove: Double = 5, minTurn: Double = 12) -> Bool {
        guard let last else { return true }
        return Geo.distance(last.position, now.position) >= minMove
            || abs(Orientation.relative(now.heading, heading: last.heading)) >= minTurn
            || abs(now.pitch - last.pitch) >= 10
    }
}

/// Footpaths and sidewalks (from /walkways): the walker stays on them, like a real pedestrian.
enum Walkways {
    /// Nearest point on a polyline (flat-earth, fine for a few hundred metres).
    static func nearest(_ p: Coord, on line: [Coord]) -> Coord? {
        guard line.count > 1 else { return line.first }
        var best: Coord?, bestD = Double.infinity
        for (a, b) in zip(line, line.dropFirst()) {
            let (bx, by) = Geo.offset(from: a, to: b)
            let (px, py) = Geo.offset(from: a, to: p)
            let len2 = bx * bx + by * by
            let t = len2 > 0 ? max(0, min(1, (px * bx + py * by) / len2)) : 0
            let q = Coord(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
            let d = Geo.distance(p, q)
            if d < bestD { bestD = d; best = q }
        }
        return best
    }

    /// Where the walker may go: the step as wanted if it stays on a walkway (within `width`), else the
    /// nearest walkway point, so walking into a building slides along its pavement instead.
    /// No walkway data nearby: free movement.
    static func constrain(to wanted: Coord, lines: [[Coord]], width: Double = 2.5) -> Coord {
        let candidates = lines.compactMap { nearest(wanted, on: $0) }
        guard let q = candidates.min(by: { Geo.distance(wanted, $0) < Geo.distance(wanted, $1) }) else { return wanted }
        let d = Geo.distance(wanted, q)
        if d <= width || d > 30 { return wanted }          // on the path, or no path anywhere near
        // Back onto the edge of the walkway.
        let f = width / d
        return Coord(lat: q.lat + (wanted.lat - q.lat) * f, lon: q.lon + (wanted.lon - q.lon) * f)
    }
}

/// What the walking viewer should do for the held keys / sticks. Pure, testable.
enum ViewerInput {
    /// A step for the strongest move input (forward wins over sideways), or nil.
    static func step(forward: Double, strafe: Double) -> String? {
        if abs(forward) >= 0.3, abs(forward) >= abs(strafe) { return forward > 0 ? "StepForward" : "StepBackward" }
        if abs(strafe) >= 0.3 { return strafe > 0 ? "StepRight" : "StepLeft" }
        return nil
    }

    /// Degrees to turn this tick.
    static func turn(_ input: Double, dt: Double) -> Double { max(-1, min(1, input)) * WalkerPhysics.turnRate * dt }
}

/// Test drive: walk around a real street from a desk. Keyboard (W A S D, arrows, Q E, Shift) or the
/// on-screen sticks move a virtual walker; it feeds position, direction and street pictures into the
/// app exactly where the GPS, compass and camera would, so every guide feature runs as outside.
@MainActor
@Observable
final class SimDrive {
    static let shared = SimDrive()

    private(set) var active = false
    private(set) var state = WalkerState(position: Coord(lat: 48.1374, lon: 11.5755), heading: 0)
    private(set) var picture: UIImage?
    private(set) var provider: String?
    private(set) var captured: String?
    private(set) var problem: String?
    private(set) var loading = false

    /// `.viewer`: Mapillary's walking viewer (animated steps between photos) shows the street;
    /// `.pictures`: one still picture per spot and direction (Google Street View or Mapillary), or none.
    enum Source { case pictures, viewer }
    private(set) var source = Source.pictures
    /// The walking viewer's web page, to send it steps and turns.
    @ObservationIgnored weak var web: WKWebView?
    @ObservationIgnored private var lastStep = Date.distantPast
    @ObservationIgnored private var pendingTurn = 0.0
    @ObservationIgnored private var lastTurnSent = Date.distantPast
    @ObservationIgnored private var imageId: String?
    @ObservationIgnored private var recognisedHeading: Double?
    /// Walkways around the walker (Dev: drawn on the mini-map).
    private(set) var walkways: [[Coord]] = []
    @ObservationIgnored private var walkwaysAt: Coord?

    // Inputs: keys held down and the two sticks.
    var keys: Set<String> = []
    var moveStick = CGVector.zero        // dx = strafe, dy = forward
    var lookStick = CGVector.zero        // dx = turn, dy = look up/down

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var lastInjected = Date.distantPast
    @ObservationIgnored private var pictureFor: WalkerState?
    @ObservationIgnored private var lastFetch = Date.distantPast
    @ObservationIgnored private var fetching = false

    func start(at p: Coord? = nil, heading: Double? = nil) {
        if let p { state.position = p }
        if let heading { state.heading = heading }
        active = true
        problem = nil
        pictureFor = nil
        GuideController.shared.camera.simulated = true
        lastTick = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)          // keeps running while a finger drags a stick
        timer = t
        source = .pictures
        walkways = []; walkwaysAt = nil
        loadWalkways()
        inject(force: true)
        // With a Mapillary token on the server, walk in the animated viewer instead of still pictures.
        Task {
            struct Status: Decodable { let providers: [String] }
            if let st: Status = try? await GuideAPI.get("streetview/status"), st.providers.contains("mapillary") {
                source = .viewer
                picture = nil
            }
        }
    }

    /// The viewer page's URL, starting where the walker stands.
    var viewerURL: URL {
        var c = URLComponents(url: AppStore.shared.backendURL.appendingPathComponent("drive/viewer"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "lat", value: "\(state.position.lat)"), .init(name: "lon", value: "\(state.position.lon)"),
                        .init(name: "heading", value: String(format: "%.0f", state.heading))]
        return c.url!
    }

    /// Messages from the viewer: where the walker is and looks now.
    func viewerEvent(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "image":
            if let lat = m["lat"] as? Double, let lon = m["lon"] as? Double { state.position = Coord(lat: lat, lon: lon) }
            imageId = (m["id"] as? String) ?? (m["id"] as? NSNumber)?.stringValue
            loadWalkways()
            provider = "mapillary"
            if let ms = m["captured"] as? Double {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM"
                captured = f.string(from: Date(timeIntervalSince1970: ms / 1000))
            }
            problem = nil
            inject(force: true)
            recognise()
        case "position":
            if let lat = m["lat"] as? Double, let lon = m["lon"] as? Double { state.position = Coord(lat: lat, lon: lon) }
            inject(force: false)
        case "bearing":
            if let b = m["bearing"] as? Double { state.heading = (b + 360).truncatingRemainder(dividingBy: 360) }
            inject(force: false)
            if let r = recognisedHeading, abs(Orientation.relative(state.heading, heading: r)) >= 15 { recognise() }
        case "blocked":
            problem = tr("No street picture in that direction.", "In diese Richtung gibt es kein Straßenbild.")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error":
            problem = m["message"] as? String
        default:
            break
        }
    }

    /// Walkways within 250 m, reloaded after moving 100 m.
    private func loadWalkways() {
        let here = state.position
        guard walkwaysAt.map({ Geo.distance($0, here) > 100 }) ?? true else { return }
        walkwaysAt = here
        Task {
            struct R: Decodable { let data: [[[Double]]] }
            if let r: R = try? await GuideAPI.get("walkways", ["lat": "\(here.lat)", "lon": "\(here.lon)", "radius_m": "250"]) {
                walkways = r.data.map { $0.map { Coord(lat: $0[0], lon: $0[1]) } }
            }
        }
    }

    private func js(_ code: String) { web?.evaluateJavaScript(code, completionHandler: nil) }

    /// The viewer's current picture, cut to where the walker looks, goes through the phone's recognition.
    private func recognise() {
        guard let id = imageId, !fetching else { return }
        fetching = true
        recognisedHeading = state.heading
        let heading = state.heading
        Task {
            defer { fetching = false }
            var c = URLComponents(url: AppStore.shared.backendURL.appendingPathComponent("streetview"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "image_id", value: id), .init(name: "heading", value: String(format: "%.0f", heading))]
            if let (data, resp) = try? await URLSession.shared.data(from: c.url!), (resp as? HTTPURLResponse)?.statusCode == 200 {
                GuideController.shared.camera.inject(jpeg: data)
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        active = false
        keys = []; moveStick = .zero; lookStick = .zero
        GuideController.shared.camera.simulated = false
        LocationService.shared.endSimulation()
    }

    /// Tell the guide where the walker is now (when the guide starts listening), without moving the viewer.
    func announce() { inject(force: true) }

    /// Jump somewhere (tap on the mini-map, or a typed place).
    func teleport(to p: Coord) {
        state.position = p
        inject(force: true)
        if source == .viewer { js("drive.go(\(p.lat), \(p.lon), \(Int(state.heading)))") }
    }

    private func tick() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastTick))
        lastTick = now
        let k = keys
        let forward = (k.contains("w") || k.contains("up") ? 1.0 : 0) - (k.contains("s") || k.contains("down") ? 1 : 0) + Double(moveStick.dy)
        let strafe = (k.contains("d") ? 1.0 : 0) - (k.contains("a") ? 1 : 0) + Double(moveStick.dx)
        let turn = (k.contains("e") || k.contains("right") ? 1.0 : 0) - (k.contains("q") || k.contains("left") ? 1 : 0) + Double(lookStick.dx)
        let look = (k.contains("r") ? 1.0 : 0) - (k.contains("f") ? 1 : 0) + Double(lookStick.dy)
        let fast = k.contains("shift") || hypot(moveStick.dx, moveStick.dy) > 0.95
        guard forward != 0 || strafe != 0 || turn != 0 || look != 0 else { return }
        if source == .viewer {
            // The viewer moves in animated steps between photos; it reports back where we end up.
            if let step = ViewerInput.step(forward: forward, strafe: strafe), now.timeIntervalSince(lastStep) > 0.25 {
                lastStep = now
                js("drive.step('\(step)')")
            }
            pendingTurn += ViewerInput.turn(turn, dt: dt)
            if pendingTurn != 0, now.timeIntervalSince(lastTurnSent) > 1.0 / 15 {
                js("drive.turn(\(pendingTurn))")
                pendingTurn = 0
                lastTurnSent = now
            }
            if look != 0 { js("drive.look(\(look * dt * 0.5))") }
            return
        }
        var next = WalkerPhysics.step(state, forward: forward, strafe: strafe, turn: turn, look: look, fast: fast, dt: dt)
        next.position = Walkways.constrain(to: next.position, lines: walkways)
        state = next
        loadWalkways()
        inject(force: false)
    }

    /// GPS 2× per second while moving (like a phone), direction every tick, pictures when the view changed.
    private func inject(force: Bool) {
        let pose = CameraPose(heading: state.heading, pitch: state.pitch, hold: .portrait, fromCamera: true)
        GuideController.shared.camera.inject(pose: pose)
        if force || Date().timeIntervalSince(lastInjected) >= 0.5 {
            lastInjected = Date()
            let l = CLLocation(coordinate: CLLocationCoordinate2D(latitude: state.position.lat, longitude: state.position.lon),
                               altitude: 520, horizontalAccuracy: 5, verticalAccuracy: 5, course: state.heading,
                               speed: WalkerPhysics.walkSpeed, timestamp: Date())
            LocationService.shared.inject(l, heading: state.heading)
        }
        if source == .pictures, force || (SimEstimate.needsPicture(last: pictureFor, now: state) && Date().timeIntervalSince(lastFetch) > 0.4) {
            fetchPicture()
        }
    }

    private func fetchPicture() {
        guard !fetching else { return }
        fetching = true
        loading = true
        lastFetch = Date()
        let s = state
        pictureFor = s
        Task {
            defer { fetching = false; loading = false }
            var c = URLComponents(url: AppStore.shared.backendURL.appendingPathComponent("streetview"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "lat", value: "\(s.position.lat)"), .init(name: "lon", value: "\(s.position.lon)"),
                            .init(name: "heading", value: String(format: "%.0f", s.heading)),
                            .init(name: "pitch", value: String(format: "%.0f", s.pitch))]
            do {
                let (data, resp) = try await URLSession.shared.data(from: c.url!)
                let http = resp as? HTTPURLResponse
                guard http?.statusCode == 200, let img = UIImage(data: data) else {
                    let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                    problem = detail ?? tr("No street picture here.", "Kein Straßenbild hier.")
                    return
                }
                picture = img
                provider = http?.value(forHTTPHeaderField: "X-Provider")
                captured = http?.value(forHTTPHeaderField: "X-Captured")
                problem = nil
                GuideController.shared.camera.inject(jpeg: data)
            } catch {
                problem = tr("The server is not reachable.", "Der Server ist nicht erreichbar.")
            }
        }
    }
}
