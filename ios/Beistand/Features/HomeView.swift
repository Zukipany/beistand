import SwiftUI

/// The home screen: sections for what the person needs first (getting around, hearing, reading),
/// the rest under "More for other needs", and call family / help always at the bottom.
/// Older people on their own and people with memory problems get a few big buttons instead.
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
    @State private var askDriveStart = false
    @State private var showRide = false
    @State private var showMore = false
    @State private var showStory = false
    @State private var status = ""
    @State private var tip: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    statusCard
                    if !storyHome {
                        Button { showStory = true } label: {
                            Label(tr("Step by step: answer a few questions", "Schritt für Schritt: ein paar Fragen beantworten"),
                                  systemImage: "list.number")
                                .font(.title3.bold()).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .surface(.teal, cornerRadius: 30, interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                    if storyHome {
                        StoryView(embedded: true)
                    } else if simpleHome {
                        simpleButtons
                    } else {
                        ForEach(primarySections, id: \.self) { section($0) }
                        if !otherSections.isEmpty {
                            DisclosureGroup(isExpanded: $showMore) {
                                VStack(alignment: .leading, spacing: 26) {
                                    ForEach(otherSections, id: \.self) { section($0) }
                                }
                                .padding(.top, 12)
                            } label: {
                                Label(tr("More for other needs", "Mehr für andere Bedürfnisse"), systemImage: "square.grid.2x2")
                                    .font(.title3.bold())
                            }
                            .tint(.primary)
                        }
                    }
                    #if DEBUG
                    if store.devMode { devSection }
                    #endif
                }
                .padding(16)
                .padding(.bottom, 12)
            }
            .background(BeistandBackground())
            .safeAreaInset(edge: .bottom) { safetyBar }
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
            .fullScreenCover(isPresented: $showRide) { RideView() }
            .fullScreenCover(isPresented: $showStory) {
                ScrollView { StoryView().padding(16) }.background(BeistandBackground())
            }
            .onChange(of: AppRouter.shared.requestID) { _, _ in
                if let d = AppRouter.shared.request { go(d) }
            }
            .onChange(of: RideController.shared.requestedOpen) { _, open in
                if open { showRide = true; RideController.shared.requestedOpen = false }
            }
            .onAppear {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "openMagnifier") { showMagnifier = true }   // test hook
                if UserDefaults.standard.bool(forKey: "openCaptions") { showCaptions = true }     // test hook
                if UserDefaults.standard.bool(forKey: "openDiagnostics") { showDiagnostics = true } // test hook
                if UserDefaults.standard.bool(forKey: "openSounds") { showSounds = true }           // test hook
                if UserDefaults.standard.bool(forKey: "openCounter") { showCounter = true }         // test hook
                if UserDefaults.standard.bool(forKey: "openMap") { showMap = true }                 // test hook
                // `-rideSim de:09162:500` starts a Dev ride (×20) to that station from the nearest one.
                if let id = UserDefaults.standard.string(forKey: "rideSim") {
                    showRide = true
                    RideController.shared.start(to: .init(id: id, name: id, place: nil), simulate: true)
                }
                #endif
            }
            .task { await loadWeather() }
            .onAppear { watchForTrain() }
        }
    }

    /// While the app is open: feels like a moving train and no ride is set → vibrate and offer the ride helper.
    private func watchForTrain() {
        let w = TrainMotionWatcher.shared
        w.onRidingNoticed = {
            guard RideController.shared.phase == .choosing, !showRide else { return }
            RideHaptics.getReady()
            Speaker.shared.say(tr("It feels like you're on a train. Where are you getting off?",
                                  "Es fühlt sich an, als wären Sie in einer Bahn. Wo steigen Sie aus?"))
            showRide = true
        }
        w.start()
    }

    private func startDrive(_ p: Coord, heading: Double) {
        SimDrive.shared.start(at: p, heading: heading)
        GuideController.shared.requestedOpen = true
    }


    /// People who don't speak or want easy steps: the story is their home screen.
    private var storyHome: Bool { store.has(.speech) || store.has(.easyReading) }

    /// Voice commands and the story open things through here.
    private func go(_ d: Destination) {
        switch d {
        case .guide: closeAll(); GuideController.shared.requestedOpen = true
        case .map: closeAll(); showMap = true
        case .captions: closeAll(); showCaptions = true
        case .sounds: closeAll(); showSounds = true
        case .counter: closeAll(); showCounter = true
        case .read: closeAll(); showRead = true
        case .magnifier: closeAll(); showMagnifier = true
        case .scam: closeAll(); showScam = true
        case .settings: closeAll(); showSettings = true
        case .story: closeAll(); showStory = true
        case .ride(let to):
            closeAll(); showRide = true
            if let to {
                Task {
                    await RideController.shared.search(to)
                    if let s = RideController.shared.results.first { RideController.shared.start(to: s) }
                }
            }
        case .find(let what):
            closeAll()
            GuideController.shared.pendingFind = what
            GuideController.shared.requestedOpen = true
        case .whereAmI: whereAmI()
        case .departures: GuideController.shared.sayDepartures()
        case .callFamily: callFamily()
        case .help: safety.requestHelp()
        case .back: closeAll()
        }
    }

    private func closeAll() {
        showRead = false; showScam = false; showSettings = false; showMagnifier = false; showCaptions = false
        showSounds = false; showCounter = false; showMap = false; showStory = false; showDiagnostics = false
        if showRide { RideController.shared.stop(); showRide = false }
        GuideController.shared.requestedOpen = false
    }

    // MARK: sections by what the person needs

    enum HomeSection: Hashable { case around, hearing, reading }

    /// How much a section matters for this person (0 = not their need).
    private func relevance(_ s: HomeSection) -> Int {
        switch s {
        case .around:
            return [Mode.sight, .deafblind, .wheelchair].contains(where: store.has) ? 3
                 : [Mode.lowVision, .dementia].contains(where: store.has) ? 2 : 1
        case .hearing:
            return store.has(.hearing) || store.has(.deafblind) ? 3 : 0
        case .reading:
            return [Mode.lowVision, .easyReading].contains(where: store.has) ? 3
                 : [Mode.older, .dementia].contains(where: store.has) ? 2 : 0
        }
    }

    private var primarySections: [HomeSection] {
        [HomeSection.around, .hearing, .reading].filter { relevance($0) >= 2 }.sorted { relevance($0) > relevance($1) }
    }
    private var otherSections: [HomeSection] {
        [HomeSection.around, .hearing, .reading].filter { relevance($0) < 2 }
    }

    /// Older people on their own, or memory problems: few big buttons, nothing to get lost in.
    private var simpleHome: Bool {
        store.has(.dementia) || store.profile?.modes.subtracting([.older, .calm, .tremor, .lowEnergy]).isEmpty == true
    }

    @ViewBuilder private func section(_ s: HomeSection) -> some View {
        switch s {
        case .around:
            TileSection(title: tr("Getting around", "Unterwegs"), icon: "figure.walk",
                        subtitle: tr("Find your way, trains, step-free places", "Weg finden, Bahn, stufenlose Orte")) {
                Tile(title: tr("I'm lost", "Ich habe mich verlaufen"), icon: "figure.walk.motion", tint: .orange,
                     subtitle: tr("Camera guide", "Kamera-Begleitung"),
                     explanation: tr("Opens the camera guide. It tells you where you are and leads you.",
                                     "Öffnet die Kamera-Begleitung. Sie sagt, wo Sie sind, und führt Sie.")) {
                    GuideController.shared.requestedOpen = true
                }
                Tile(title: tr("On the U-Bahn", "In der U-Bahn"), icon: "tram.fill.tunnel", tint: .blue,
                     subtitle: tr("Told when to get off", "Gesagt, wann aussteigen"),
                     explanation: tr("Tell me where you get off. I warn you one stop before and tell you when to get off.",
                                     "Sagen Sie, wo Sie aussteigen. Ich warne eine Station vorher und sage, wann Sie aussteigen.")) {
                    showRide = true
                }
                Tile(title: tr("Choose destination", "Ziel wählen"), icon: "map.fill", tint: .teal,
                     subtitle: tr("Lifts and step-free access", "Aufzüge und stufenlos"),
                     explanation: tr("Pick a place on the map, see lifts and step-free access there, and get led there.",
                                     "Ort auf der Karte wählen, Aufzüge und stufenlosen Zugang sehen und hinführen lassen.")) { showMap = true }
                Tile(title: tr("Where am I?", "Wo bin ich?"), icon: "location.fill", tint: .indigo,
                     subtitle: tr("Your address, read aloud", "Ihre Adresse, vorgelesen"),
                     explanation: tr("Tells you where you are right now.", "Sagt Ihnen, wo Sie gerade sind.")) { whereAmI() }
            }
        case .hearing:
            TileSection(title: tr("Hearing", "Hören"), icon: "ear",
                        subtitle: tr("See what is said and what sounds", "Sehen, was gesagt wird und was klingt")) {
                Tile(title: tr("Live captions", "Live-Untertitel"), icon: "captions.bubble.fill", tint: .indigo,
                     subtitle: tr("Louder shows bigger", "Lauter wird größer"),
                     explanation: tr("Writes down what people around you say. Louder speech shows bigger.",
                                     "Schreibt auf, was Menschen um Sie herum sagen. Lautes erscheint größer.")) { showCaptions = true }
                Tile(title: tr("Sound alerts", "Geräusch-Alarme"), icon: "ear.badge.waveform", tint: .orange,
                     subtitle: tr("Siren, doorbell, baby", "Sirene, Klingel, Baby"),
                     explanation: tr("Shows and vibrates when there is a siren, alarm, horn, the doorbell or a baby crying.",
                                     "Zeigt und vibriert bei Sirene, Alarm, Hupe, Türklingel oder weinendem Baby.")) { showSounds = true }
                Tile(title: tr("Counter mode", "Schalter-Modus"), icon: "rectangle.split.1x2", tint: .blue,
                     subtitle: tr("Talk at a desk", "Am Schalter reden"),
                     explanation: tr("Lay the phone between you and the staff. Each side reads the other's words.",
                                     "Legen Sie das Telefon zwischen sich und das Personal. Jede Seite liest die Worte der anderen.")) { showCounter = true }
            }
        case .reading:
            TileSection(title: tr("Reading", "Lesen"), icon: "doc.text.magnifyingglass",
                        subtitle: tr("Letters, labels, small print", "Briefe, Etiketten, Kleingedrucktes")) {
                Tile(title: tr("Read this", "Vorlesen"), icon: "doc.text.viewfinder", tint: .indigo,
                     subtitle: tr("In simple words", "In einfachen Worten"),
                     explanation: tr("Take a photo of a letter. I read it out in simple words.",
                                     "Fotografieren Sie einen Brief. Ich lese ihn in einfachen Worten vor.")) { showRead = true }
                Tile(title: tr("Magnifier", "Lupe"), icon: "plus.magnifyingglass", tint: .purple,
                     subtitle: tr("Big, bright, read aloud", "Groß, hell, vorgelesen"),
                     explanation: tr("Makes small print big. Tap Explain and it reads it to you.",
                                     "Macht kleine Schrift groß. Tippen Sie auf Erklären, dann wird vorgelesen.")) { showMagnifier = true }
                Tile(title: tr("Is this a scam?", "Ist das Betrug?"), icon: "exclamationmark.shield.fill", tint: .orange,
                     subtitle: tr("Check a message", "Nachricht prüfen"),
                     explanation: tr("Paste or photograph a message. I check it for the usual tricks.",
                                     "Fügen Sie eine Nachricht ein oder fotografieren Sie sie. Ich prüfe sie auf die üblichen Tricks.")) { showScam = true }
            }
        }
    }

    /// Older people / memory: the calm layout, now on glass.
    private var simpleButtons: some View {
        GlassGroup(spacing: 16) {
            VStack(spacing: 16) {
                BigButton(title: tr("Where am I?", "Wo bin ich?"), systemImage: "location.fill", color: .blue,
                          explanation: tr("Tells you where you are right now.", "Sagt Ihnen, wo Sie gerade sind.")) { whereAmI() }
                BigButton(title: tr("Read this", "Vorlesen"), systemImage: "doc.text.viewfinder", color: .indigo,
                          explanation: tr("Take a photo of a letter. I read it out in simple words.",
                                          "Fotografieren Sie einen Brief. Ich lese ihn in einfachen Worten vor.")) { showRead = true }
                BigButton(title: tr("On the U-Bahn", "In der U-Bahn"), systemImage: "tram.fill.tunnel", color: .teal,
                          explanation: tr("Tell me where you get off. I tell you when to get off.",
                                          "Sagen Sie, wo Sie aussteigen. Ich sage, wann Sie aussteigen.")) { showRide = true }
                BigButton(title: tr("I'm lost", "Ich habe mich verlaufen"), systemImage: "figure.walk.motion", color: .orange,
                          explanation: tr("Opens the camera guide. It tells you where you are and leads you.",
                                          "Öffnet die Kamera-Begleitung. Sie sagt, wo Sie sind, und führt Sie.")) {
                    GuideController.shared.requestedOpen = true
                }
            }
        }
    }

    /// Weather, volume and the last answer, on one glass card.
    @ViewBuilder private var statusCard: some View {
        let hasTip = tip != nil
        VStack(alignment: .leading, spacing: 10) {
            VolumeBanner()
            if let tip {
                Label(tip, systemImage: "cloud.sun.fill").font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !status.isEmpty {
                Label(status, systemImage: "location.fill").font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !hasTip, status.isEmpty {
                Text(tr("Hold any button to hear what it does.", "Halten Sie eine Taste gedrückt, um zu hören, was sie tut."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: 22)
    }

    /// Always at hand, at the bottom: call family and help.
    private var safetyBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                SpeakButton()
                Button { callFamily() } label: {
                    Label(tr("Call \(store.profile?.contacts.first?.name ?? "family")", "\(store.profile?.contacts.first?.name ?? "Familie") anrufen"),
                          systemImage: "phone.fill")
                        .font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .surface(.green, cornerRadius: 32, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint(tr("Calls your family.", "Ruft Ihre Familie an."))
                Button { safety.requestHelp() } label: {
                    Label(tr("Help", "Hilfe"), systemImage: "sos")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .surface(.red, cornerRadius: 32, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint(tr("Calls your emergency contact right away.", "Ruft sofort Ihren Notfallkontakt."))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    #if DEBUG
    private var devSection: some View {
        TileSection(title: "Dev", icon: "hammer.fill", subtitle: tr("Testing tools, not part of the app", "Test-Werkzeuge, nicht Teil der App")) {
            Tile(title: tr("Dev: Test drive", "Dev: Testfahrt"), icon: "gamecontroller.fill", tint: .purple,
                 subtitle: tr("Walk real street photos", "Echte Straßenfotos ablaufen")) { askDriveStart = true }
                .confirmationDialog(tr("Where should the test drive start?", "Wo soll die Testfahrt starten?"),
                                    isPresented: $askDriveStart, titleVisibility: .visible) {
                    Button(tr("Marienplatz, Munich", "Marienplatz, München")) { startDrive(Coord(lat: 48.1388, lon: 11.5672), heading: 90) }
                    Button(tr("Where I am now", "Wo ich gerade bin")) {
                        Task {
                            let l = await LocationService.shared.current()
                            startDrive(l.map { Coord(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
                                       ?? Coord(lat: 48.1388, lon: 11.5672), heading: 0)
                        }
                    }
                    Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
                } message: {
                    Text(tr("Then tap Find or Map to choose a destination; the guide leads you there.",
                            "Dann auf Suchen oder Karte tippen und ein Ziel wählen; die Begleitung führt Sie hin."))
                }
            Tile(title: tr("Dev: Diagnostics", "Dev: Diagnose"), icon: "stethoscope", tint: .gray,
                 subtitle: tr("Test every feature", "Jede Funktion testen")) { showDiagnostics = true }
        }
    }
    #endif

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
                            VoiceSettingsView()
                        } label: {
                            Label(tr("Voice", "Stimme"), systemImage: "waveform")
                        }
                        Picker(tr("What the guide says", "Was die Begleitung sagt"), selection: $store.guideDetail) {
                            ForEach(GuideDetail.allCases.filter { store.devMode || $0 != .everything }) { Text($0.name).tag($0) }
                        }
                        Toggle(tr("Obstacle beeps and warnings in the camera guide", "Hindernis-Töne und Warnungen in der Kamera-Begleitung"), isOn: $store.obstacleWarnings)
                    } header: {
                        Text(tr("Guide", "Begleitung"))
                    } footer: {
                        Text(tr("People with little or no sight also feel a triple vibration when walking towards an e-scooter or bike.",
                                "Menschen mit wenig oder keiner Sehkraft spüren außerdem ein dreifaches Vibrieren, wenn sie auf einen E-Roller oder ein Rad zugehen."))
                    }
                    Section {
                        Toggle(tr("Dev mode (testing tools)", "Dev-Modus (Test-Werkzeuge)"), isOn: $store.devMode)
                    } footer: {
                        Text(tr("Shows the tools for testing, all marked Dev. Turn off to see the app as people will use it.",
                                "Zeigt die Test-Werkzeuge, alle mit Dev markiert. Ausschalten, um die App so zu sehen, wie Menschen sie nutzen."))
                    }
                    if store.devMode {
                    Section {
                        NavigationLink {
                            DiagnosticsView()
                        } label: {
                            Label(tr("Dev: Diagnostics, test every feature", "Dev: Diagnose, jede Funktion testen"), systemImage: "stethoscope")
                        }
                        NavigationLink {
                            DevScooterMapView()
                        } label: {
                            Label(tr("Dev: Scooter map (compare with real life)", "Dev: Roller-Karte (mit der Wirklichkeit vergleichen)"), systemImage: "scooter")
                        }
                    }
                    }
                    Section("Server") {
                        TextField(tr("Backend address", "Backend-Adresse"), text: $url).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onSubmit { if let u = URL(string: url) { store.backendURL = u } }
                    }
                    if store.devMode {
                    Section("Dev") {
                        Toggle(tr("Dev: a phone fall counts as a fall of the person", "Dev: Sturz des Telefons zählt als Sturz der Person"), isOn: $store.demoPhoneImpactIsFall)
                        Picker(tr("Dev: the guide uses", "Dev: die Begleitung nutzt"), selection: $store.testDrive) {
                            Text(tr("Camera and GPS", "Kamera und GPS")).tag(false)
                            Text(tr("Test drive (street photos)", "Testfahrt (Straßenfotos)")).tag(true)
                        }
                        Button(tr("Simulate a fall now", "Sturz jetzt simulieren")) { SafetyService.shared.trigger(.fall); dismiss() }
                        Button(tr("Start the phone finder now", "Telefon-Finder jetzt starten")) { SafetyService.shared.startDropFinder(); dismiss() }
                        Button(tr("Open the camera guide", "Kamera-Begleitung öffnen")) { dismiss(); GuideController.shared.requestedOpen = true }
                        Button(tr("Simulate a wrist fall (watch)", "Sturz am Handgelenk simulieren (Uhr)")) { WatchLink.shared.handle(.wristFall(at: Date())); dismiss() }
                    }
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
