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

    let camera = GuideCamera()
    private let beeper = Beeper()
    private var objectAlerts = ObjectAlerts()
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
        camera.onZones = { [weak self] z in self?.obstaclesChanged(z) }
        camera.onObjects = { [weak self] objects in self?.objectsSeen(objects) }
        WalkRecorder.shared.begin()
        camera.start()
        LocationService.shared.setTracking(true)
        LocationService.shared.onUpdate = { [weak self] loc in
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
        }
    }

    func stop() {
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
            if let h = LocationService.shared.heading { body["heading"] = h }
            if let question { body["question"] = question }
            do {
                let d: GuideAPI.Described = try await GuideAPI.post("describe", body)
                say(d.spoken)
            } catch {
                say(tr("I can't describe the picture right now.", "Ich kann das Bild gerade nicht beschreiben."))
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

    // MARK: tools

    private func runTool(name: String, args: [String: String]) async -> [String: Any] {
        switch name {
        case "plan_route":
            return await planRoute(to: args["destination"] ?? "")
        case "crossing_info":
            return await crossingInfo()
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
            // Blind: landmark-style instructions; wheelchair: no steps; otherwise walking that avoids steps.
            let profile = AppStore.shared.has(.wheelchair) ? "wheelchair" : AppStore.shared.has(.sight) ? "blind" : "foot-walking"
            let route: GuideAPI.Route = try await GuideAPI.get("route", [
                "from_lat": "\(p.lat)", "from_lon": "\(p.lon)", "to_lat": "\(place.lat)", "to_lon": "\(place.lon)", "profile": profile, "lang": Lang.code])
            follower = RouteFollower(destinationName: place.name, steps: route.steps,
                                     line: route.geometry.map { Coord(lat: $0[1], lon: $0[0]) })
            follower?.crossings = route.crossings ?? []
            self.destination = place.name
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

    private func obstaclesChanged(_ z: ObstacleZones) {
        zones = z
        beeper.update(z.centre)
        WalkRecorder.shared.log(.init(t: 0, kind: "zones", zones: z))
    }

    private func objectsSeen(_ objects: [SeenObject]) {
        guard AppStore.shared.obstacleWarnings, !objects.isEmpty else { return }
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
            Task { _ = await planRoute(to: dest) }
        case .crossing(let text)?:
            Haptics.pulses(1)
            tell(forGuide: tr("Tell the person now, in your own words: \(text) Do not say whether it is safe to cross.",
                              "Sag der Person jetzt in eigenen Worten: \(text) Sag nicht, ob es sicher ist zu gehen."),
                 forPerson: text)
        case .arrived?:
            Haptics.arrived()
            tell(forGuide: tr("The person has arrived at \(f.destinationName). Tell them and describe what you see.",
                              "Die Person ist am Ziel \(f.destinationName) angekommen. Sag es ihr und beschreibe, was du siehst."),
                 forPerson: tr("You have arrived: \(f.destinationName).", "Sie sind angekommen: \(f.destinationName)."))
            follower = nil
        case nil:
            // Keep the guide up to date without making it talk.
            if mode == .live, Date().timeIntervalSince(lastContext) > 15 {
                lastContext = Date()
                tell(forGuide: f.context(at: p, heading: LocationService.shared.heading), forPerson: nil, respond: false)
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
