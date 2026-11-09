import SwiftUI

/// Older people mode: four big buttons, nothing else to get lost in.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(SafetyService.self) private var safety
    @Environment(\.openURL) private var openURL
    @State private var showRead = false
    @State private var showScam = false
    @State private var showSettings = false
    @State private var showMagnifier = false
    @State private var showCaptions = false
    @State private var showDiagnostics = false
    @State private var showSounds = false
    @State private var showCounter = false
    @State private var showMap = false
    @State private var status = ""
    @State private var tip: String?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 16) {
                VolumeBanner()
                if let tip {
                    Label(tip, systemImage: "cloud.sun.fill").font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(.yellow.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                }
                if store.has(.sight) || store.has(.lowVision) {
                    BigButton(title: tr("I'm lost", "Ich habe mich verlaufen"), systemImage: "figure.walk.motion", color: .orange,
                              explanation: tr("Opens the camera guide. It tells you where you are and leads you.",
                                              "Öffnet die Kamera-Begleitung. Sie sagt, wo Sie sind, und führt Sie.")) {
                        GuideController.shared.requestedOpen = true
                    }
                }
                if store.has(.hearing) || store.has(.deafblind) {
                    BigButton(title: tr("Live captions", "Live-Untertitel"), systemImage: "captions.bubble.fill", color: .indigo,
                              explanation: tr("Writes down what people around you say. Louder speech shows bigger.",
                                              "Schreibt auf, was Menschen um Sie herum sagen. Lautes erscheint größer.")) {
                        showCaptions = true
                    }
                }
                if store.has(.hearing) || store.has(.deafblind) {
                    BigButton(title: tr("Sound alerts", "Geräusch-Alarme"), systemImage: "ear.badge.waveform", color: .orange,
                              explanation: tr("Shows and vibrates when there is a siren, alarm, horn, the doorbell or a baby crying.",
                                              "Zeigt und vibriert bei Sirene, Alarm, Hupe, Türklingel oder weinendem Baby.")) {
                        showSounds = true
                    }
                }
                if store.has(.hearing) {
                    BigButton(title: tr("Counter mode", "Schalter-Modus"), systemImage: "rectangle.split.1x2", color: .blue,
                              explanation: tr("Lay the phone between you and the staff. Each side reads the other's words.",
                                              "Legen Sie das Telefon zwischen sich und das Personal. Jede Seite liest die Worte der anderen.")) {
                        showCounter = true
                    }
                }
                if store.has(.lowVision) {
                    BigButton(title: tr("Magnifier", "Lupe"), systemImage: "plus.magnifyingglass", color: .indigo,
                              explanation: tr("Makes small print big. Tap Explain and it reads it to you.",
                                              "Macht kleine Schrift groß. Tippen Sie auf Erklären, dann wird vorgelesen.")) {
                        showMagnifier = true
                    }
                }
                BigButton(title: tr("Call family", "Familie anrufen"), systemImage: "phone.fill", color: .green,
                          explanation: tr("Calls \(store.profile?.contacts.first?.name ?? "your family").",
                                          "Ruft \(store.profile?.contacts.first?.name ?? "Ihre Familie") an.")) { callFamily() }
                BigButton(title: tr("Where am I?", "Wo bin ich?"), systemImage: "location.fill", color: .blue,
                          explanation: tr("Tells you where you are right now.", "Sagt Ihnen, wo Sie gerade sind.")) { whereAmI() }
                BigButton(title: tr("Choose destination", "Ziel wählen"), systemImage: "map.fill", color: .teal,
                          explanation: tr("Pick a place on the map, see lifts and step-free access there, and get led there.",
                                          "Ort auf der Karte wählen, Aufzüge und stufenlosen Zugang sehen und hinführen lassen.")) { showMap = true }
                BigButton(title: tr("Read this", "Vorlesen"), systemImage: "doc.text.viewfinder", color: .indigo,
                          explanation: tr("Take a photo of a letter. I read it out in simple words.",
                                          "Fotografieren Sie einen Brief. Ich lese ihn in einfachen Worten vor.")) { showRead = true }
                BigButton(title: tr("Help", "Hilfe"), systemImage: "sos", color: .red,
                          explanation: tr("Calls your emergency contact right away.", "Ruft sofort Ihren Notfallkontakt.")) { safety.requestHelp() }
                Text(status).font(.title2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .accessibilityHidden(status.isEmpty)
                Button { showScam = true } label: {
                    Label(tr("Is this a scam?", "Ist das Betrug?"), systemImage: "exclamationmark.shield").font(.title3)
                        .frame(minHeight: 44)
                }
            }
            .padding(16)
            }
            .navigationTitle(tr("Hello", "Hallo") + " \(store.profile?.name ?? "")")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(tr("Settings for the family", "Einstellungen für die Familie"))
                }
            }
            .sheet(isPresented: $showRead) { ReadThisView() }
            .sheet(isPresented: $showScam) { ScamCheckView() }
            .sheet(isPresented: $showSettings) { FamilySettingsView() }
            .fullScreenCover(isPresented: $showMagnifier) { MagnifierView() }
            .fullScreenCover(isPresented: $showCaptions) { LiveCaptionsView() }
            .sheet(isPresented: $showDiagnostics) { NavigationStack { DiagnosticsView() } }
            .fullScreenCover(isPresented: $showSounds) { SoundAlertsView() }
            .fullScreenCover(isPresented: $showCounter) { CounterModeView() }
            .sheet(isPresented: $showMap) { DestinationMapView() }
            .onAppear {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "openMagnifier") { showMagnifier = true }   // test hook
                if UserDefaults.standard.bool(forKey: "openCaptions") { showCaptions = true }     // test hook
                if UserDefaults.standard.bool(forKey: "openDiagnostics") { showDiagnostics = true } // test hook
                if UserDefaults.standard.bool(forKey: "openSounds") { showSounds = true }           // test hook
                if UserDefaults.standard.bool(forKey: "openCounter") { showCounter = true }         // test hook
                if UserDefaults.standard.bool(forKey: "openMap") { showMap = true }                 // test hook
                #endif
            }
            .task { await loadWeather() }
        }
    }

    private func callFamily() {
        guard let c = store.profile?.contacts.first, let url = URL(string: "tel://\(c.phone)") else { return }
        Speaker.shared.say(tr("Calling \(c.name).", "Ich rufe \(c.name) an."))
        openURL(url)
    }

    private func whereAmI() {
        status = tr("One moment …", "Einen Moment …")
        Speaker.shared.say(tr("One moment, I'm checking.", "Einen Moment, ich schaue nach."))
        Task {
            guard let loc = await LocationService.shared.current() else {
                status = tr("I can't find your position right now.", "Ich finde Ihre Position gerade nicht.")
                Speaker.shared.say(status); return
            }
            status = await LocationService.shared.describe(loc)
            Speaker.shared.say(status)
        }
    }

    private func loadWeather() async {
        guard let loc = await LocationService.shared.current(),
              let w = try? await API.shared.warnings(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude) else { return }
        tip = w.data.tip
    }
}

/// Settings sit behind a family PIN, so nothing changes by accident.
struct FamilySettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("familyPIN") private var pin = "0000"
    @State private var entered = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                if entered != pin {
                    SecureField(tr("Family PIN", "Familien-PIN"), text: $entered).keyboardType(.numberPad).font(.title)
                } else {
                    @Bindable var store = store
                    Section {
                        NavigationLink {
                            DiagnosticsView()
                        } label: {
                            Label(tr("Diagnostics: test every feature", "Diagnose: jede Funktion testen"), systemImage: "stethoscope")
                        }
                    }
                    Section("Server") {
                        TextField(tr("Backend address", "Backend-Adresse"), text: $url).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onSubmit { if let u = URL(string: url) { store.backendURL = u } }
                    }
                    Section("Demo") {
                        Toggle(tr("A phone fall counts as a fall of the person", "Sturz des Telefons zählt als Sturz der Person"), isOn: $store.demoPhoneImpactIsFall)
                        Toggle(tr("Obstacle beeps and warnings in the camera guide", "Hindernis-Töne und Warnungen in der Kamera-Begleitung"), isOn: $store.obstacleWarnings)
                        Picker(tr("The guide uses", "Die Begleitung nutzt"), selection: $store.testDrive) {
                            Text(tr("Camera and GPS", "Kamera und GPS")).tag(false)
                            Text(tr("Test drive (street photos)", "Testfahrt (Straßenfotos)")).tag(true)
                        }
                        Button(tr("Simulate a fall now", "Sturz jetzt simulieren")) { SafetyService.shared.trigger(.fall); dismiss() }
                        Button(tr("Start the phone finder now", "Telefon-Finder jetzt starten")) { SafetyService.shared.startDropFinder(); dismiss() }
                        Button(tr("Open the camera guide", "Kamera-Begleitung öffnen")) { dismiss(); GuideController.shared.requestedOpen = true }
                        Button(tr("Simulate a wrist fall (watch)", "Sturz am Handgelenk simulieren (Uhr)")) { WatchLink.shared.handle(.wristFall(at: Date())); dismiss() }
                    }
                    Section {
                        ForEach(TestProfile.all) { p in
                            Button { store.setModes(p.modes); dismiss() } label: {
                                Label(p.name, systemImage: p.icon).font(.title3)
                            }
                        }
                    } header: {
                        Text(tr("Try the app as …", "App ausprobieren als …"))
                    } footer: {
                        Text(tr("Replaces all modes at once, to test or demo the app.",
                                "Ersetzt alle Modi auf einmal, zum Testen oder Vorführen."))
                    }
                    Section(tr("Modes", "Modi")) {
                        ForEach(Mode.allCases) { m in
                            Toggle(m.label, isOn: Binding(get: { store.has(m) }, set: { store.setMode(m, $0) }))
                        }
                    }
                    Section {
                        Button(tr("Set up again", "Neu einrichten"), role: .destructive) { store.profile = nil; dismiss() }
                    }
                }
            }
            .navigationTitle(tr("Settings", "Einstellungen"))
            .toolbar { Button(tr("Done", "Fertig")) { dismiss() } }
            .onAppear { url = store.backendURL.absoluteString }
        }
    }
}
