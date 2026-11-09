import CoreLocation
import Foundation
import Observation
import UIKit
import os

private let log = Logger(subsystem: "app.beistand.ios", category: "guide")

/// Backend calls the guide needs.
enum GuideAPI {
    struct Prompt: Decodable {
        let system_prompt: String
        let voice_language: String
        let tools: [AnyJSON]
    }
    struct Token: Decodable { let token: String; let model: String }
    struct Place: Decodable { let name: String; let address: String?; let lat: Double; let lon: Double }
    struct Places: Decodable { let data: [Place] }
    struct Route: Decodable {
        let distance_m: Double
        let steps: [RouteStep]
        let geometry: [[Double]]   // [lon, lat]
        let direct: Bool?
        let crossings: [RouteCrossing]?
        let provider: String?
    }
    struct Crossings: Decodable {
        struct Item: Decodable { let name: String?; let signal: String; let distance_m: Int; let say: String }
        let crossings: [Item]
    }
    struct Described: Decodable { let spoken: String }
    struct Landmarks: Decodable { let data: [Landmark] }
    struct Access: Decodable {
        struct Data: Decodable {
            struct Elevator: Decodable { let distance_m: Int; let level: String?; let wheelchair: String? }
            struct Place: Decodable { let name: String; let wheelchair: String? }
            let place: Place?
            let elevators: [Elevator]
            let spoken: String
        }
        let data: Data
    }

    static func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var c = URLComponents(url: AppStore.shared.backendURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await run(URLRequest(url: c.url!))
    }

    static func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var r = URLRequest(url: AppStore.shared.backendURL.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await run(r)
    }

    private static func run<T: Decodable>(_ r: URLRequest) async throws -> T {
        var r = r
        r.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Passes arbitrary JSON (the tool declarations) straight through to Gemini.
struct AnyJSON: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode([String: AnyJSON].self) { value = v.mapValues(\.value) }
        else if let v = try? c.decode([AnyJSON].self) { value = v.map(\.value) }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else { value = NSNull() }
    }
}

/// "I'm lost": one press opens the camera guide, which says where the person is,
/// asks where they want to go, and leads them there step by step.
@MainActor
@Observable
final class GuideController {
    static let shared = GuideController()

    enum Mode: Equatable { case off, connecting, live, simple }
    struct Line: Identifiable { let id = UUID(); let fromGuide: Bool; var text: String }

    var mode: Mode = .off
    var lines: [Line] = []
    var status = ""
    var requestedOpen = false          // set by the App Intent / Action Button
    var destination: String?
    var listening = false
    /// Where the destination pin is, for the live view's arrow.
    var destinationCoord: Coord?
    /// What the map says about the destination's accessibility (lifts, step-free, toilets).
    var destinationAccess: String?

    // Live view ("look around"): the camera picture with places and recognised things on top.
    var lookAround = false { didSet { sweep.reset(); saidSigns = [] } }
    private(set) var pose = CameraPose()
    private(set) var signs: [SeenText] = []
    private(set) var liveObjects: [SeenObject] = []
    private(set) var landmarks: [Landmark] = []
    private var landmarksAt: Coord?
    private var sweep = SweepPolicy()
    private var saidSigns: Set<String> = []
    private var lastAimHint = Date.distantPast
    /// Destination chosen on the map before the guide was open.
    private var pending: GuideAPI.Place?

    let camera = GuideCamera()
    private let beeper = Beeper()
    private var objectAlerts = ObjectAlerts()
    private var memory = SceneMemory()
    /// Latest obstacle lanes, for the on-screen indicator.
    private(set) var zones = ObstacleZones()
    private let audio = LiveAudio()
    private let client = LiveClient()
    private let listener = Listener()
    private var follower: RouteFollower?
    private var misses = 0
    private var lastReplan = Date.distantPast
    private var lastContext = Date.distantPast
    private var guideTurnOpen = false
    // Live session resumption: the server closes camera sessions after ~2 minutes and sends goAway first.
    private var liveToken: GuideAPI.Token?
    private var livePrompt: GuideAPI.Prompt?
    private var resumeHandle: String?
    private var resume = ResumePolicy()
    private var resumed = false
    private(set) var reconnects = 0

    // MARK: start / stop

    func start() {
        guard mode == .off else { return }
        lines = []; misses = 0; follower = nil; destination = nil
        mode = .connecting
        status = tr("Connecting …", "Verbinde …")
        UIApplication.shared.isIdleTimerDisabled = true
        // Fast layer: obstacles and objects on the phone, every frame, independent of the network.
        beeper.enabled = AppStore.shared.obstacleWarnings
        beeper.sound = !AppStore.shared.has(.hearing) && !AppStore.shared.has(.deafblind)
        objectAlerts = ObjectAlerts()
        memory = SceneMemory()
        camera.onZones = { [weak self] z in self?.obstaclesChanged(z) }
        camera.onObjects = { [weak self] objects in self?.objectsSeen(objects) }
        camera.onPose = { [weak self] p in self?.poseChanged(p) }
        camera.onText = { [weak self] t in self?.textSeen(t) }
        Task { await loadLandmarks() }
        WalkRecorder.shared.begin()
        camera.start()
        LocationService.shared.setTracking(true)
        LocationService.shared.onUpdate = { [weak self] loc in
            self?.maybeReloadLandmarks(loc)
            WalkRecorder.shared.log(.init(t: 0, kind: "fix", lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                          acc: loc.horizontalAccuracy, heading: LocationService.shared.heading))
            self?.moved(loc)
        }

        Task {
            let context = await self.locationContext()
            do {
                let prompt: GuideAPI.Prompt = try await GuideAPI.get("guide/prompt", ["mode": guideMode, "lang": Lang.code])
                let token: GuideAPI.Token = try await GuideAPI.post("gemini/token", [:])
                startLive(token: token, prompt: prompt, context: context)
            } catch {
                startSimple(context: context)
            }
            if let p = pending {
                pending = nil
                try? await Task.sleep(for: .seconds(mode == .simple ? 4 : 2))   // after the greeting
                await routeToChosen(p)
            }
        }
    }

    func stop() {
        lookAround = false
        #if DEBUG
        demoTimer?.invalidate(); demoTimer = nil
        #endif
        liveToken = nil; livePrompt = nil; resumeHandle = nil; resume = ResumePolicy(); reconnects = 0
        client.close()
        audio.stop()
        camera.stop()
        beeper.stop()
        WalkRecorder.shared.end()
        listener.stop()
        Speaker.shared.stop()
        LocationService.shared.onUpdate = nil
        if SafetyService.shared.incident == nil { LocationService.shared.setTracking(false) }
        UIApplication.shared.isIdleTimerDisabled = false
        mode = .off
    }

    private var guideMode: String { AppStore.shared.has(.lowVision) && !AppStore.shared.has(.sight) ? "low_vision" : "sight" }

    // MARK: live (Gemini)

    private func startLive(token: GuideAPI.Token, prompt: GuideAPI.Prompt, context: String) {
        liveToken = token
        livePrompt = prompt
        client.onEvent = { [weak self] in self?.handle($0, initialContext: context) }
        client.onClose = { [weak self] reason in
            guard let self, self.mode == .live || self.mode == .connecting else { return }
            // Same conversation, new connection: the person hears no interruption beyond a short pause.
            if self.resume.shouldReconnect(hasHandle: self.resumeHandle != nil) {
                self.reconnect()
                return
            }
            self.audio.stop()
            self.status = tr("Live connection ended", "Live-Verbindung beendet")
            self.startSimple(context: "", announce: tr("The live connection dropped. I'll keep helping you in simple mode.",
                                                       "Die Live-Verbindung ist abgebrochen. Ich helfe Ihnen im einfachen Modus weiter."))
            _ = reason
        }
        connectLive(handle: nil)
    }

    private func connectLive(handle: String?) {
        guard let token = liveToken, let prompt = livePrompt else { return }
        let tools = prompt.tools.map(\.value).compactMap { $0 as? [String: Any] }
        client.connect(token: token.token, setup: LiveProtocol.setup(
            model: token.model, systemPrompt: prompt.system_prompt, tools: tools,
            language: prompt.voice_language, resumeHandle: handle))
    }

    /// Reconnects with the latest resume handle. Microphone and camera keep running.
    private func reconnect() {
        reconnects += 1
        resumed = true
        status = tr("Reconnecting …", "Verbinde neu …")
        log.info("live reconnect #\(self.reconnects)")
        client.close()
        connectLive(handle: resumeHandle)
    }

    private func handle(_ e: LiveProtocol.Event, initialContext: String) {
        switch e {
        case .setupComplete where resumed:
            // Resumed: the model remembers the conversation; only refresh where the person is now.
            resumed = false
            resume.connected()
            status = "Live"
            if let f = follower, let l = LocationService.shared.last {
                let p = Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
                client.send(LiveProtocol.text(tr("[CONTEXT] ", "[KONTEXT] ") + f.context(at: p, heading: LocationService.shared.heading), respond: false))
            }
        case .setupComplete:
            mode = .live
            status = "Live"
            resume.connected()
            audio.onChunk = { [weak self] pcm in self?.client.send(LiveProtocol.audio(pcm)) }
            camera.onFrame = { [weak self] jpeg in self?.client.send(LiveProtocol.video(jpeg)) }
            do { try audio.start() } catch { status = tr("Microphone not available", "Mikrofon nicht verfügbar") }
            client.send(LiveProtocol.text(tr("[CONTEXT] \(initialContext) The person pressed 'I'm lost'.",
                                             "[KONTEXT] \(initialContext) Die Person hat 'Ich habe mich verlaufen' gedrückt."), respond: true))
        case .audio(let pcm):
            audio.play(pcm)
        case .guideText(let t):
            appendText(t, fromGuide: true, merge: guideTurnOpen)
            guideTurnOpen = true
        case .personText(let t):
            appendText(t, fromGuide: false, merge: true)
        case .turnComplete:
            guideTurnOpen = false
        case .interrupted:
            audio.flush()
        case .toolCall(let id, let name, let args):
            Task {
                let result = await runTool(name: name, args: args)
                client.send(LiveProtocol.toolResponse(id: id, name: name, response: result))
            }
        case .resumeHandle(let h):
            resumeHandle = h
        case .goAway:
            // Reconnect before the server closes, so speech is not cut mid-sentence.
            if resume.shouldReconnect(hasHandle: resumeHandle != nil) { reconnect() }
            else { status = tr("Connection ending soon", "Verbindung endet bald") }
        }
    }

    /// Live transcriptions arrive in pieces; `merge` joins them into the current line.
    private func appendText(_ t: String, fromGuide: Bool, merge: Bool = false) {
        if merge, let last = lines.last, last.fromGuide == fromGuide {
            lines[lines.count - 1].text += t
        } else {
            lines.append(Line(fromGuide: fromGuide, text: t.trimmingCharacters(in: .whitespaces)))
        }
        if lines.count > 30 { lines.removeFirst(lines.count - 30) }
    }

    /// `forGuide` goes to Gemini (live); `forPerson` is spoken directly in simple mode.
    private func tell(forGuide: String, forPerson: String?, respond: Bool = true) {
        if mode == .live {
            client.send(LiveProtocol.text(tr("[CONTEXT] ", "[KONTEXT] ") + forGuide, respond: respond))
        } else if let forPerson {
            say(forPerson)
        }
    }

    // MARK: simple mode (no Gemini key / connection lost)

    private func startSimple(context: String, announce: String? = nil) {
        mode = .simple
        status = tr("Simple mode", "Einfacher Modus")
        let place = context.isEmpty ? "" : (LocationService.shared.lastDescription ?? "")
        let intro = announce ?? [place, tr("Where would you like to go? Tap Say destination, or What's in front of me.",
                                           "Wohin möchten Sie? Tippen Sie auf Ziel sagen, oder auf Was ist vor mir.")]
            .filter { !$0.isEmpty }.joined(separator: " ")
        say(intro)
    }

    /// Simple mode: one photo, described by the backend.
    func describeAhead(question: String? = nil) {
        if mode == .live {
            client.send(LiveProtocol.text(question ?? tr("What's in front of me?", "Was ist vor mir?"), respond: true))
            return
        }
        guard let jpeg = camera.latestJPEG else {
            say(tr("I don't have a camera picture yet. Please hold the phone upright in front of you.",
                   "Ich habe noch kein Kamerabild. Halten Sie das Telefon bitte aufrecht vor sich."))
            return
        }
        status = tr("Looking …", "Schaue …")
        Task {
            var body: [String: Any] = ["image_b64": jpeg.base64EncodedString(), "lang": Lang.code]
            body["address"] = LocationService.shared.lastDescription
            if let h = camera.heading { body["heading"] = h }
            if let question { body["question"] = question }
            if let here = hereCoord, !landmarks.isEmpty {
                body["nearby"] = Orientation.grounding(landmarks, here: here, heading: camera.heading)
            }
            do {
                let d: GuideAPI.Described = try await GuideAPI.post("describe", body)
                say(d.spoken)
            } catch {
                // No AI key or no network: what the phone knows by itself (map, compass, signs, LiDAR).
                say(offlineDescription())
            }
            status = tr("Simple mode", "Einfacher Modus")
        }
    }

    /// Simple mode: ask for the destination by voice.
    func askDestination() {
        say(tr("Where would you like to go?", "Wohin möchten Sie?")) { [weak self] in
            Task { await self?.listenForDestination() }
        }
    }

    private func listenForDestination() async {
        listening = true
        listener.start()
        var last = ""
        var stable = 0
        for _ in 0..<40 {   // up to ~10 s; stop after ~1.5 s of no change
            try? await Task.sleep(for: .milliseconds(250))
            let t = listener.transcript
            if !t.isEmpty, t == last { stable += 1 } else { stable = 0; last = t }
            if stable >= 6 { break }
        }
        listener.stop()
        listening = false
        let spoken = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { say(tr("I didn't understand you.", "Ich habe Sie nicht verstanden.")); return }
        appendText(spoken, fromGuide: false)
        let r = await planRoute(to: spoken)
        if r["ok"] as? Bool != true { say(r["message"] as? String ?? tr("I couldn't find that destination.", "Das Ziel habe ich nicht gefunden.")) }
    }

    /// Typed destination (also used by tests and sighted helpers).
    func go(to destination: String) {
        Task { _ = await planRoute(to: destination) }
    }

    /// A pin dropped on the map.
    func go(to pin: Coord, name: String) {
        let place = GuideAPI.Place(name: name, address: nil, lat: pin.lat, lon: pin.lon)
        guard mode == .live || mode == .simple else { pending = place; return }
        Task { await routeToChosen(place) }
    }

    private func routeToChosen(_ place: GuideAPI.Place) async {
        let r = await planRoute(to: place)
        if mode == .live {
            tell(forGuide: tr("The person chose \(place.name) on the map. Route: ", "Die Person hat \(place.name) auf der Karte gewählt. Weg: ")
                 + "\(r["distance_m"] ?? "?") m, \(r["first_instruction"] ?? ""). " + (destinationAccess ?? ""), forPerson: nil)
        } else if r["ok"] as? Bool != true, let m = r["message"] as? String {
            say(m)
        }
    }

    // MARK: tools

    private func runTool(name: String, args: [String: String]) async -> [String: Any] {
        switch name {
        case "plan_route":
            return await planRoute(to: args["destination"] ?? "")
        case "crossing_info":
            return await crossingInfo()
        case "next_departures":
            return await nextDepartures()
        case "where_is":
            let here = LocationService.shared.last.map { Coord(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
            return ["ok": true, "answer": memory.answer(args["thing"] ?? "", now: ProcessInfo.processInfo.systemUptime, here: here)]
        case "call_emergency_contact":
            SafetyService.shared.trigger(.lost)
            let who = AppStore.shared.profile?.contacts.first?.name ?? tr("Your contact", "Ihr Kontakt")
            return ["ok": true, "message": tr("\(who) is being called and gets your location.", "\(who) wird angerufen und bekommt Ihren Standort.")]
        default:
            return ["ok": false, "message": "Unknown tool"]
        }
    }

    @discardableResult
    func planRoute(to destination: String) async -> [String: Any] {
        guard let here = await LocationService.shared.current() else {
            return ["ok": false, "message": tr("I don't know the location right now.", "Ich kenne den Standort gerade nicht.")]
        }
        let p = Coord(lat: here.coordinate.latitude, lon: here.coordinate.longitude)
        do {
            let places: GuideAPI.Places = try await GuideAPI.get("geocode", ["q": destination, "lat": "\(p.lat)", "lon": "\(p.lon)", "lang": Lang.code])
            guard let place = places.data.first else {
                return ["ok": false, "message": tr("I can't find \(destination). Can you say it differently?",
                                                   "Ich finde \(destination) nicht. Können Sie es anders sagen?")]
            }
            return await planRoute(to: place, from: p)
        } catch {
            log.error("geocode failed: \(error.localizedDescription)")
            return ["ok": false, "message": tr("I can't plan a route right now.", "Ich kann gerade keinen Weg planen.")]
        }
    }

    @discardableResult
    func planRoute(to place: GuideAPI.Place, from start: Coord? = nil) async -> [String: Any] {
        var start = start
        if start == nil, let here = await LocationService.shared.current() {
            start = Coord(lat: here.coordinate.latitude, lon: here.coordinate.longitude)
        }
        guard let p = start else {
            return ["ok": false, "message": tr("I don't know the location right now.", "Ich kenne den Standort gerade nicht.")]
        }
        do {
            // Blind: landmark-style instructions; wheelchair: no steps; otherwise walking that avoids steps.
            let profile = AppStore.shared.has(.wheelchair) ? "wheelchair" : AppStore.shared.has(.sight) ? "blind" : "foot-walking"
            let route: GuideAPI.Route = try await GuideAPI.get("route", [
                "from_lat": "\(p.lat)", "from_lon": "\(p.lon)", "to_lat": "\(place.lat)", "to_lon": "\(place.lon)", "profile": profile, "lang": Lang.code])
            follower = RouteFollower(destinationName: place.name, steps: route.steps,
                                     line: route.geometry.map { Coord(lat: $0[1], lon: $0[0]) })
            follower?.crossings = route.crossings ?? []
            self.destination = place.name
            self.destinationCoord = Coord(lat: place.lat, lon: place.lon)
            self.destinationAccess = nil
            Task { await loadAccess(place) }
            lastReplan = Date()
            let first = follower?.firstInstruction ?? ""
            let summary = tr("Route to \(place.name), about \(Int(route.distance_m)) metres. \(first)",
                             "Weg zu \(place.name), etwa \(Int(route.distance_m)) Meter. \(first)")
            log.debug("route planned, mode=\(String(describing: self.mode))")
            if mode == .simple { say(summary) }
            let cs = route.crossings ?? []
            return ["ok": true, "destination": place.name, "address": place.address ?? "",
                    "distance_m": Int(route.distance_m), "first_instruction": first,
                    "straight_line_only": route.direct ?? false,
                    "traffic_light_crossings": cs.count,
                    "crossings_with_sound_signal": cs.filter { $0.signal == "sound" }.count]
        } catch {
            log.error("route failed: \(error.localizedDescription)")
            return ["ok": false, "message": tr("I can't plan a route right now.", "Ich kann gerade keinen Weg planen.")]
        }
    }

    struct Stations: Decodable {
        struct Station: Decodable { let globalId: String; let name: String; let distanceInMeters: Double? }
        let data: [Station]
    }
    struct Departures: Decodable {
        struct Departure: Decodable { let line: String?; let destination: String?; let platform: Int?; let minutes: Int; let type: String? }
        let data: [Departure]
        let age_s: Int?
    }

    /// Next departures at the nearest stop (MVG), as the guide's tool and for the person.
    func nextDepartures() async -> [String: Any] {
        guard let loc = await LocationService.shared.current() else {
            return ["ok": false, "message": tr("I don't know the location right now.", "Ich kenne den Standort gerade nicht.")]
        }
        do {
            let st: Stations = try await GuideAPI.get("stations", ["lat": "\(loc.coordinate.latitude)", "lon": "\(loc.coordinate.longitude)"])
            guard let stop = st.data.first else {
                return ["ok": false, "message": tr("No stop nearby.", "Keine Haltestelle in der Nähe.")]
            }
            let dep: Departures = try await GuideAPI.get("departures", ["global_id": stop.globalId, "limit": "8"])
            let next = dep.data.prefix(4).map { d -> [String: Any] in
                ["line": d.line ?? "", "destination": d.destination ?? "", "minutes": d.minutes, "platform": d.platform ?? 0]
            }
            return ["ok": true, "stop": stop.name, "distance_m": Int(stop.distanceInMeters ?? 0),
                    "departures": next, "data_age_s": dep.age_s ?? 0]
        } catch {
            return ["ok": false, "message": tr("Departures are not available right now.", "Abfahrten sind gerade nicht verfügbar.")]
        }
    }

    /// Nearest traffic lights and whether they have a signal for blind people (city data).
    func crossingInfo() async -> [String: Any] {
        guard let loc = await LocationService.shared.current() else {
            return ["ok": false, "message": tr("I don't know the location right now.", "Ich kenne den Standort gerade nicht.")]
        }
        do {
            let r: GuideAPI.Crossings = try await GuideAPI.get("crossings", [
                "lat": "\(loc.coordinate.latitude)", "lon": "\(loc.coordinate.longitude)", "radius_m": "150", "lang": Lang.code])
            guard let c = r.crossings.first else {
                return ["ok": true, "message": tr("No traffic light within 150 metres in the city's data.",
                                                  "Keine Ampel im Umkreis von 150 Metern in den Daten der Stadt.")]
            }
            return ["ok": true, "nearest": ["name": c.name ?? "", "distance_m": c.distance_m, "signal": c.signal, "say": c.say],
                    "others": r.crossings.dropFirst().map { ["name": $0.name ?? "", "distance_m": $0.distance_m, "signal": $0.signal] }]
        } catch {
            return ["ok": false, "message": tr("Crossing data is not available right now.", "Ampeldaten sind gerade nicht verfügbar.")]
        }
    }

    // MARK: obstacles (fast layer)

    /// Measured distances for the live guide, so it doesn't have to guess them from a 1 fps picture.
    private func obstacleContext() -> String {
        guard camera.usesLiDAR else { return "" }
        func m(_ d: Float?) -> String { d.map { String(format: "%.1f m", $0) } ?? tr("clear", "frei") }
        return tr(" LiDAR: ahead \(m(zones.centre)), left \(m(zones.left)), right \(m(zones.right)).",
                  " LiDAR: vorne \(m(zones.centre)), links \(m(zones.left)), rechts \(m(zones.right)).")
    }

    /// Simple mode: read the next departures aloud (the live guide uses the same data as a tool).
    func sayDepartures() {
        Task {
            let r = await nextDepartures()
            guard r["ok"] as? Bool == true, let stop = r["stop"] as? String,
                  let deps = r["departures"] as? [[String: Any]], !deps.isEmpty else {
                say(r["message"] as? String ?? tr("No departures found.", "Keine Abfahrten gefunden.")); return
            }
            let parts = deps.prefix(3).map { d -> String in
                let line = d["line"] as? String ?? "", dest = d["destination"] as? String ?? ""
                let min = d["minutes"] as? Int ?? 0
                let when = min == 0 ? tr("now", "jetzt") : tr("in \(min) min", "in \(min) Min.")
                return tr("\(line) to \(dest) \(when)", "\(line) nach \(dest) \(when)")
            }
            say("\(stop): " + parts.joined(separator: ". ") + ".")
        }
    }

    private func obstaclesChanged(_ z: ObstacleZones) {
        zones = z
        beeper.update(z.centre)
        WalkRecorder.shared.log(.init(t: 0, kind: "zones", zones: z))
    }

    private func objectsSeen(_ objects: [SeenObject]) {
        liveObjects = objects
        guard !objects.isEmpty else { return }
        let here = LocationService.shared.last.map { Coord(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        memory.add(objects, at: ProcessInfo.processInfo.systemUptime, position: here)
        guard AppStore.shared.obstacleWarnings else { return }
        WalkRecorder.shared.log(.init(t: 0, kind: "objects", objects: objects))
        guard let sentence = objectAlerts.feed(objects, at: ProcessInfo.processInfo.systemUptime) else { return }
        warn(sentence)
    }

    /// Warnings always win: they interrupt the guide's voice and are fixed phrases, never generated.
    private func warn(_ sentence: String) {
        WalkRecorder.shared.log(.init(t: 0, kind: "say", text: sentence))
        if mode == .live {
            audio.flush()
            client.send(LiveProtocol.text(tr("[CONTEXT] The phone just warned the person: ", "[KONTEXT] Das Telefon hat die Person gerade gewarnt: ") + sentence,
                                          respond: false))
        }
        Speaker.shared.say(sentence, interrupt: true)
        appendText(sentence, fromGuide: true)
    }

    // MARK: following

    private func moved(_ loc: CLLocation) {
        guard mode != .off, var f = follower else { return }
        let p = Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let event = f.update(p, accuracy: loc.horizontalAccuracy)
        log.debug("fix \(p.lat, format: .fixed(precision: 6)),\(p.lon, format: .fixed(precision: 6)) acc \(loc.horizontalAccuracy) away \(Geo.distance(p, toPolyline: f.line)) event \(String(describing: event))")
        follower = f

        switch event {
        case .announce(let text)?:
            Haptics.direction(for: text)
            tell(forGuide: tr("Announce now: \(text)", "Jetzt ansagen: \(text)"), forPerson: text)
        case .offRoute(let metres)?:
            // Count one miss per re-plan, not per GPS fix: a single detour reports many fixes.
            guard Date().timeIntervalSince(lastReplan) > 20, let dest = destination else { return }
            misses += 1
            WatchLink.shared.cue(.offRoute)
            if misses >= 3 {
                offerContact()
                return
            }
            tell(forGuide: tr("The person is about \(Int(metres)) metres off the route. I'm re-planning.",
                              "Die Person ist etwa \(Int(metres)) Meter vom Weg abgekommen. Ich plane neu."),
                 forPerson: tr("You are about \(Int(metres)) metres off the route. I'm planning it again.",
                               "Sie sind etwa \(Int(metres)) Meter vom Weg abgekommen. Ich plane den Weg neu."))
            if let c = destinationCoord {
                Task { _ = await planRoute(to: GuideAPI.Place(name: dest, address: nil, lat: c.lat, lon: c.lon)) }
            } else {
                Task { _ = await planRoute(to: dest) }
            }
        case .crossing(let text)?:
            Haptics.pulses(1)
            tell(forGuide: tr("Tell the person now, in your own words: \(text) Do not say whether it is safe to cross.",
                              "Sag der Person jetzt in eigenen Worten: \(text) Sag nicht, ob es sicher ist zu gehen."),
                 forPerson: text)
        case .arrived?:
            Haptics.arrived()
            tell(forGuide: tr("The person has arrived at \(f.destinationName). Tell them and describe what you see.",
                              "Die Person ist am Ziel \(f.destinationName) angekommen. Sag es ihr und beschreibe, was du siehst."),
                 forPerson: tr("You have arrived: \(f.destinationName).", "Sie sind angekommen: \(f.destinationName).")
                    + (destinationAccess.map { " " + $0 } ?? ""))
            follower = nil
        case nil:
            // Keep the guide up to date without making it talk.
            if mode == .live, Date().timeIntervalSince(lastContext) > 15 {
                lastContext = Date()
                tell(forGuide: f.context(at: p, heading: LocationService.shared.heading) + obstacleContext(), forPerson: nil, respond: false)
            }
        }
    }

    private func offerContact() {
        misses = 0
        if mode == .live {
            tell(forGuide: tr("The person has gone off the route three times. Ask whether you should alert their emergency contact.",
                              "Die Person ist dreimal vom Weg abgekommen. Frag sie, ob du ihren Notfallkontakt benachrichtigen sollst."), forPerson: nil)
            return
        }
        let who = AppStore.shared.profile?.contacts.first?.name ?? tr("your contact", "Ihren Kontakt")
        say(tr("We've lost the route three times. Shall I call \(who)? Say yes or no.",
               "Wir haben den Weg dreimal verloren. Soll ich \(who) anrufen? Sagen Sie Ja oder Nein.")) { [weak self] in
            Task { await self?.listenYesNoForContact() }
        }
    }

    private func listenYesNoForContact() async {
        listener.start()
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(250))
            if let yes = Listener.yesNo(listener.transcript) {
                listener.stop()
                if yes { _ = await runTool(name: "call_emergency_contact", args: ["reason": tr("lost", "verlaufen")]) }
                else { say(tr("OK. I'll plan the route again.", "Gut. Ich plane den Weg noch einmal.")); if let d = destination { _ = await planRoute(to: d) } }
                return
            }
        }
        listener.stop()
    }

    // MARK: live view (look around)

    private var hereCoord: Coord? {
        LocationService.shared.last.map { Coord(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
    }

    /// Named places around, once per ~60 m.
    func loadLandmarks() async {
        guard let loc = await LocationService.shared.current() else { return }
        let here = Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        landmarksAt = here
        if let r: GuideAPI.Landmarks = try? await GuideAPI.get("landmarks", ["lat": "\(here.lat)", "lon": "\(here.lon)", "lang": Lang.code]) {
            landmarks = r.data
        }
    }

    private func maybeReloadLandmarks(_ loc: CLLocation) {
        let p = Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        guard let at = landmarksAt, Geo.distance(at, p) > 60 else { return }
        landmarksAt = p
        Task { await loadLandmarks() }
    }

    func loadAccess(_ place: GuideAPI.Place) async {
        if let a: GuideAPI.Access = try? await GuideAPI.get("access", ["lat": "\(place.lat)", "lon": "\(place.lon)",
                                                                      "name": place.name, "lang": Lang.code]) {
            destinationAccess = a.data.spoken
        }
    }

    private func poseChanged(_ p: CameraPose) {
        #if DEBUG
        if demoTimer != nil { return }
        #endif
        pose = p
        guard lookAround else { return }
        if let hint = CameraAim.hint(pitch: p.pitch), Date().timeIntervalSince(lastAimHint) > 6 {
            lastAimHint = Date()
            Speaker.shared.say(hint, interrupt: true)
            return
        }
        guard CameraAim.hint(pitch: p.pitch) == nil, let h = p.heading, let here = hereCoord,
              let dir = sweep.feed(heading: h, at: ProcessInfo.processInfo.systemUptime) else { return }
        let text = Orientation.sentence(heading: dir, here: here, landmarks: landmarks, signs: signs.map(\.text))
        if mode == .live {
            tell(forGuide: tr("The person is looking around. The map says: ", "Die Person schaut sich um. Die Karte sagt: ") + text,
                 forPerson: nil, respond: false)
        }
        Speaker.shared.say(text, interrupt: true)
        appendText(text, fromGuide: true)
    }

    private func textSeen(_ t: [SeenText]) {
        signs = t
        guard lookAround, let here = hereCoord else { return }
        for (sign, l) in Orientation.matchSigns(t.map(\.text), landmarks: landmarks) where !saidSigns.contains(l.id) {
            saidSigns.insert(l.id)
            let d = Int(Geo.distance(here, l.coord).rounded())
            let text = tr("I can read \"\(sign)\": \(l.name), \(l.kind), \(d) metres.",
                          "Ich lese „\(sign)“: \(l.name), \(l.kind), \(d) Meter.")
            Speaker.shared.say(text, interrupt: false)
            appendText(text, fromGuide: true)
            return
        }
    }

    /// "What's in front of me?" without any AI: compass, map, signs the phone read, LiDAR.
    func offlineDescription() -> String {
        var parts: [String] = []
        if let hint = CameraAim.hint(pitch: pose.pitch) { parts.append(hint) }
        if let c = zones.centre, c < 3 {
            parts.append(tr("Something is in your way, \(String(format: "%.1f", c)) metres ahead.",
                            "Etwas ist im Weg, \(String(format: "%.1f", c)) Meter vor Ihnen."))
        }
        for o in liveObjects.sorted(by: { $0.distance < $1.distance }).prefix(2) where o.label != "obstacle" {
            parts.append(ObjectAlerts.phrase(o))
        }
        if let h = camera.heading, let here = hereCoord {
            parts.append(Orientation.sentence(heading: h, here: here, landmarks: landmarks, signs: signs.map(\.text)))
        } else if let d = LocationService.shared.lastDescription {
            parts.append(d)
        }
        let unmatched = signs.map(\.text).filter { s in Orientation.matchSigns([s], landmarks: landmarks).isEmpty }.prefix(3)
        if !unmatched.isEmpty {
            parts.append(tr("Text I can read: ", "Text, den ich lesen kann: ") + unmatched.joined(separator: ", ") + ".")
        }
        return parts.isEmpty ? tr("I can't see anything useful. Hold the phone upright and turn slowly.",
                                  "Ich sehe nichts Hilfreiches. Halten Sie das Telefon aufrecht und drehen Sie sich langsam.")
                             : parts.joined(separator: " ")
    }

    #if DEBUG
    private var demoTimer: Timer?
    /// Simulator: no camera or compass, so turn slowly on the spot and pretend to see a few things.
    func startDemoSweep() {
        demoTimer?.invalidate()
        var h = UserDefaults.standard.double(forKey: "fakeHeading")
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                h = (h + 1.2).truncatingRemainder(dividingBy: 360)
                let t = ProcessInfo.processInfo.systemUptime
                // Pause every 45° so the sweep logic speaks.
                let still = Int(t * 5) % 25 > 12
                if still { h -= 1.2 }
                self.pose = CameraPose(heading: h, pitch: -5, hold: .portrait, fromCamera: true)
                self.liveObjects = [
                    SeenObject(label: "person", distance: 3.2, side: .ahead, box: CGRect(x: 0.42, y: 0.25, width: 0.16, height: 0.45)),
                    SeenObject(label: "bicycle", distance: 2.1, side: .left, box: CGRect(x: 0.05, y: 0.2, width: 0.25, height: 0.22)),
                ]
                self.zones = ObstacleZones(left: 2.1, centre: 3.2, right: nil)
                if self.signs.isEmpty, let l = self.landmarks.first(where: { !$0.isStreet }) {
                    self.signs = [SeenText(text: l.name.uppercased(), box: CGRect(x: 0.6, y: 0.7, width: 0.3, height: 0.06))]
                }
                guard self.lookAround, let here = self.hereCoord,
                      let dir = self.sweep.feed(heading: h, at: t) else { return }
                let text = Orientation.sentence(heading: dir, here: here, landmarks: self.landmarks)
                Speaker.shared.say(text, interrupt: true)
                self.appendText(text, fromGuide: true)
            }
        }
    }
    #endif

    // MARK: helpers

    private func say(_ text: String, then done: (() -> Void)? = nil) {
        Speaker.shared.say(text, then: done)
        if mode == .simple, lines.last?.text != text { appendText(text, fromGuide: true) }
    }

    private func locationContext() async -> String {
        guard let loc = await LocationService.shared.current() else { return tr("Location unknown.", "Standort unbekannt.") }
        let place = await LocationService.shared.describe(loc)
        let gps = String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude)
        var s = tr("\(place) (GPS \(gps), accuracy \(Int(loc.horizontalAccuracy)) m.",
                   "\(place) (GPS \(gps), Genauigkeit \(Int(loc.horizontalAccuracy)) m.")
        if let h = LocationService.shared.heading {
            s += tr(" The phone points \(compass(h)).", " Das Telefon zeigt nach \(compass(h)).")
        }
        return s
    }

    private func compass(_ deg: Double) -> String {
        let names = Lang.german ? ["Norden", "Nordosten", "Osten", "Südosten", "Süden", "Südwesten", "Westen", "Nordwesten"]
                                : ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return names[Int(((deg.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45)) % 8]
    }
}

/// Phone vibrations as a stand-in for the watch: two pulses left, three right, one long for stop/arrival.
enum Haptics {
    static func direction(for text: String) {
        let t = text.lowercased()
        switch GuideCue.from(direction: t) { case .left?: pulses(2); case .right?: pulses(3); default: break }
        if let c = GuideCue.from(direction: text) { WatchLink.shared.cue(c) }
    }

    static func arrived() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        WatchLink.shared.cue(.arrived)
    }

    static func pulses(_ n: Int) {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        for i in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) { g.impactOccurred() }
        }
    }
}
