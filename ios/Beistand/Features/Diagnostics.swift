import Speech
import SwiftUI
import Translation
import WatchConnectivity

/// Settings → Diagnostics: which engine each feature uses right now, and a button to test each one
/// for real. Meant for the family, testers and the demo, so problems show up before they matter.
struct DiagnosticsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var health: [String: Any] = [:]
    @State private var healthError: String?
    @State private var speech = "…"
    @State private var translation = "…"
    @State private var results: [String: String] = [:]
    @State private var running: Set<String> = []
    @State private var recordWalks = WalkRecorder.shared.enabled
    @State private var walkFiles = Array(WalkRecorder.files.prefix(5))

    var body: some View {
        List {
            Section {
                Button {
                    let start = LocationService.shared.last.map { Coord(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
                    SimDrive.shared.start(at: start ?? Coord(lat: 48.1374, lon: 11.5755))
                    GuideController.shared.requestedOpen = true
                    dismiss()
                } label: {
                    Label(tr("Test drive: walk real streets from here", "Testfahrt: echte Straßen von hier aus ablaufen"),
                          systemImage: "gamecontroller.fill").font(.headline)
                }
            } footer: {
                Text(tr("Move with the sticks or W A S D. The guide gets street pictures instead of the camera. Needs GOOGLE_MAPS_API_KEY or MAPILLARY_TOKEN on the server for real pictures.",
                        "Bewegen mit den Sticks oder W A S D. Der Guide bekommt Straßenbilder statt der Kamera. Für echte Bilder braucht der Server GOOGLE_MAPS_API_KEY oder MAPILLARY_TOKEN."))
            }
            Section(tr("Server", "Server")) {
                row(tr("Address", "Adresse"), store.backendURL.absoluteString)
                row(tr("Status", "Status"), healthError ?? (health["ok"] as? Bool == true ? tr("reachable", "erreichbar") : "…"),
                    ok: healthError == nil && health["ok"] as? Bool == true)
                row(tr("Messages to contacts", "Nachrichten an Kontakte"),
                    health["twilio"] as? Bool == true ? "Twilio" : tr("dry run (shown in /outbox)", "Testlauf (siehe /outbox)"))
            }
            Section(tr("Seeing (vision model)", "Sehen (Bildmodell)")) {
                let models = ((health["vision"] as? [String]) ?? []).filter { $0 != "offline" }
                row(tr("Models in order", "Modelle der Reihe nach"),
                    models.isEmpty ? tr("no key on the server → text reading on the phone", "kein Schlüssel am Server → Textlesen auf dem Telefon")
                                   : (models + [tr("on-phone text reading", "Textlesen auf dem Telefon")]).joined(separator: " → "),
                    ok: !models.isEmpty)
                row(tr("Live guide reconnects (this walk)", "Live-Neuverbindungen (dieser Weg)"), "\(GuideController.shared.reconnects)")
                row(tr("Live camera guide", "Live-Kamera-Begleitung"),
                    health["gemini"] as? Bool == true ? "Gemini Live (\(health["gemini_model"] as? String ?? ""))"
                                                      : tr("simple mode (no Gemini key)", "einfacher Modus (kein Gemini-Schlüssel)"),
                    ok: health["gemini"] as? Bool == true)
                test("vision", tr("Read a sample label", "Beispiel-Etikett lesen")) { await testVision() }
            }
            Section(tr("Obstacles (on the phone)", "Hindernisse (auf dem Telefon)")) {
                row(tr("LiDAR depth", "LiDAR-Tiefe"), GuideCamera.hasLiDAR ? tr("yes: beeps and distances", "ja: Töne und Abstände")
                                                                      : tr("no: camera only, no distances", "nein: nur Kamera, keine Abstände"),
                    ok: GuideCamera.hasLiDAR)
                row(tr("Warnings", "Warnungen"), store.obstacleWarnings ? tr("on", "an") : tr("off", "aus"), ok: store.obstacleWarnings)
                Toggle(tr("Record test walks", "Test-Wege aufzeichnen"), isOn: $recordWalks)
                    .onChange(of: recordWalks) { _, on in WalkRecorder.shared.enabled = on }
                ForEach(walkFiles, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section(tr("Routes", "Wege")) {
                row(tr("Router", "Routenplaner"), (health["routes"] as? String) ?? "…")
                test("route", tr("Sendlinger Tor → Hauptbahnhof (your profile)", "Sendlinger Tor → Hauptbahnhof (Ihr Profil)")) { await testRoute() }
                test("crossings", tr("Traffic lights near Hauptbahnhof (city data)", "Ampeln am Hauptbahnhof (Daten der Stadt)")) { await testCrossings() }
            }
            Section(tr("Listening and translating", "Hören und Übersetzen")) {
                row(tr("Speech to text", "Sprache zu Text"), speech)
                row(tr("Translation", "Übersetzung"), translation)
                test("scam", tr("Scam check with a sample message", "Betrugs-Check mit Beispiel")) { await testScam() }
                test("voice", tr("Speak a sample sentence", "Beispielsatz sprechen")) {
                    Speaker.shared.say(tr("This is how Beistand sounds.", "So klingt Beistand."))
                    return tr("Speaking now (volume \(Int(VolumeMonitor.shared.level * 100)) %).",
                              "Spricht jetzt (Lautstärke \(Int(VolumeMonitor.shared.level * 100)) %).")
                }
            }
            Section(tr("Watch", "Uhr")) {
                row(tr("Connection", "Verbindung"), watchStatus, ok: WCSession.isSupported() && WCSession.default.isWatchAppInstalled)
                test("watch", tr("Tap 'turn left' on the wrist", "„Links abbiegen“ am Handgelenk tippen")) {
                    WatchLink.shared.cue(.left)
                    return WCSession.default.isReachable ? tr("Sent. The watch should tap twice.", "Gesendet. Die Uhr sollte zweimal tippen.")
                                                         : tr("Watch app not open or not reachable.", "Uhr-App nicht offen oder nicht erreichbar.")
                }
            }
        }
        .navigationTitle(tr("Diagnostics", "Diagnose"))
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: rows

    private func row(_ label: String, _ value: String, ok: Bool? = nil) -> some View {
        HStack(alignment: .top) {
            if let ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                    .accessibilityLabel(ok ? tr("working", "funktioniert") : tr("limited", "eingeschränkt"))
            }
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func test(_ id: String, _ title: String, _ run: @escaping () async -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                running.insert(id)
                Task { results[id] = await run(); running.remove(id) }
            } label: {
                Label(running.contains(id) ? tr("Testing …", "Teste …") : title, systemImage: "play.circle")
            }
            .disabled(running.contains(id))
            if let r = results[id] { Text(r).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private var watchStatus: String {
        guard WCSession.isSupported() else { return tr("not supported", "nicht unterstützt") }
        let s = WCSession.default
        if !s.isPaired { return tr("no watch paired", "keine Uhr gekoppelt") }
        if !s.isWatchAppInstalled { return tr("watch app not installed", "Uhr-App nicht installiert") }
        return s.isReachable ? tr("connected", "verbunden") : tr("installed, app not open", "installiert, App nicht offen")
    }

    // MARK: checks

    private func load() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: store.backendURL.appendingPathComponent("health"))
            health = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            healthError = nil
        } catch {
            healthError = tr("not reachable", "nicht erreichbar")
        }
        walkFiles = Array(WalkRecorder.files.prefix(5))
        speech = await speechStatus()
        translation = await translationStatus()
    }

    private func speechStatus() async -> String {
        if #available(iOS 26, *) {
            guard await ModernSpeech.supported(Lang.locale) != nil else { return "SFSpeechRecognizer" }
            return await ModernSpeech.installed(Lang.locale)
                ? tr("SpeechAnalyzer (newer, on device)", "SpeechAnalyzer (neu, auf dem Gerät)")
                : tr("SpeechAnalyzer (model downloads on first use)", "SpeechAnalyzer (Modell lädt beim ersten Mal)")
        }
        let r = SFSpeechRecognizer(locale: Lang.locale)
        return "SFSpeechRecognizer" + (r?.supportsOnDeviceRecognition == true ? tr(" (on device)", " (auf dem Gerät)") : "")
    }

    private func translationStatus() async -> String {
        let other: Locale.Language = Lang.german ? Locale.Language(identifier: "en") : Locale.Language(identifier: "de")
        switch await LanguageAvailability().status(from: other, to: Lang.locale.language) {
        case .installed: return tr("on device, installed", "auf dem Gerät, installiert")
        case .supported: return tr("on device, language packs load on first use", "auf dem Gerät, Sprachpakete laden beim ersten Mal")
        default: return tr("not available", "nicht verfügbar")
        }
    }

    private func testVision() async -> String {
        let img = TestPicture.medicineLabel()
        guard let jpeg = img.jpegData(compressionQuality: 0.8) else { return "–" }
        let started = Date()
        if let d: GuideAPI.Described = try? await GuideAPI.post("describe", [
            "image_b64": jpeg.base64EncodedString(), "lang": Lang.code, "purpose": "magnify"]) {
            return tr("Server model (\(Int(Date().timeIntervalSince(started))) s): ", "Server-Modell (\(Int(Date().timeIntervalSince(started))) s): ") + d.spoken
        }
        guard let r = await OnDeviceReader.read(img) else { return tr("Nothing read.", "Nichts gelesen.") }
        return tr("No server model; read on the phone: ", "Kein Server-Modell; auf dem Telefon gelesen: ") + r.text.replacingOccurrences(of: "\n", with: " · ")
    }

    private struct Route: Decodable {
        struct Step: Decodable { let instruction: String; let distance_m: Int }
        let distance_m: Int
        let provider: String?
        let steps: [Step]
        let crossings: [RouteCrossing]?
        let alternatives_checked: Int?
    }

    private func testCrossings() async -> String {
        do {
            let r: GuideAPI.Crossings = try await GuideAPI.get("crossings", ["lat": "48.1405", "lon": "11.5600",
                                                                            "radius_m": "250", "lang": Lang.code])
            guard !r.crossings.isEmpty else { return tr("No traffic lights found.", "Keine Ampeln gefunden.") }
            return r.crossings.map { "\($0.distance_m) m · \($0.signal) · \($0.name ?? "")" }.joined(separator: "\n")
        } catch {
            return tr("Failed: ", "Fehler: ") + error.localizedDescription
        }
    }

    private func testRoute() async -> String {
        let profile = store.has(.wheelchair) ? "wheelchair" : store.has(.sight) ? "blind" : "foot-walking"
        do {
            let r: Route = try await GuideAPI.get("route", ["from_lat": "48.1340", "from_lon": "11.5671",
                                                             "to_lat": "48.1405", "to_lon": "11.5600",
                                                             "profile": profile, "lang": Lang.code])
            let steps = r.steps.prefix(3).map { "\($0.distance_m) m: \($0.instruction)" }.joined(separator: "\n")
            let cs = (r.crossings ?? []).map { "🚦 \($0.signal) · \($0.name ?? "")" }.joined(separator: "\n")
            return "\(r.provider ?? "?") · \(profile) · \(r.distance_m) m · \(r.alternatives_checked ?? 1) " +
                tr("option(s) checked", "Variante(n) geprüft") + "\n\(steps)" + (cs.isEmpty ? "" : "\n\(cs)")
        } catch {
            return tr("Failed: ", "Fehler: ") + error.localizedDescription
        }
    }

    private func testScam() async -> String {
        let sample = tr("Hi mum, this is my new number. Can you transfer 900 pounds today?",
                        "Hallo Mama, das ist meine neue Nummer. Kannst du mir heute noch 900 € überweisen?")
        guard let v = try? await API.shared.scamCheck(sample, lang: Lang.code) else { return tr("Server not reachable.", "Server nicht erreichbar.") }
        return "\(v.level): \(v.spoken)"
    }
}
