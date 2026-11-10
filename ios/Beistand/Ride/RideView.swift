import SwiftUI

/// "On the U-Bahn": choose where to get off; then the screen shows the next stop in big letters,
/// turns red when it is time to get off, and has a help card to show other passengers.
struct RideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var ride = RideController.shared
    @State private var query = ""
    @State private var showHelp = false

    var body: some View {
        NavigationStack {
            Group {
                switch ride.phase {
                case .choosing, .planning: choosing
                case .waiting, .riding, .arrived: riding
                }
            }
            .navigationTitle(tr("On the U-Bahn", "In der U-Bahn"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("End", "Ende")) { ride.stop(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHelp = true } label: { Label(tr("Help", "Hilfe"), systemImage: "hand.raised.fill") }
                        .tint(.red)
                }
            }
            .fullScreenCover(isPresented: $showHelp) { HelpCard(station: ride.tracker?.destination?.name) }
        }
    }

    // MARK: where to

    private var choosing: some View {
        List {
            Section {
                TextField(tr("Where do you get off? e.g. Odeonsplatz", "Wo steigen Sie aus? z. B. Odeonsplatz"), text: $query)
                    .font(.title2).autocorrectionDisabled()
                    .onChange(of: query) { _, q in Task { await ride.search(q) } }
                if ride.phase == .planning { ProgressView(ride.headline) }
                if let p = ride.problem { Text(p).foregroundStyle(.red) }
            }
            Section {
                ForEach(ride.results) { s in
                    Button { ride.start(to: s) } label: {
                        Label(s.name, systemImage: "tram.fill.tunnel").font(.title3)
                    }
                    #if DEBUG
                    .swipeActions {
                        if store.devMode {
                            Button(tr("Dev: ride ×20", "Dev: Fahrt ×20")) { ride.start(to: s, simulate: true) }.tint(.purple)
                        }
                    }
                    #endif
                }
            } footer: {
                if store.devMode {
                    Text(tr("Dev: swipe a station to the left for a ride 20 times faster than real time.",
                            "Dev: Station nach links wischen für eine Fahrt 20-mal schneller als echt."))
                }
            }
        }
    }

    // MARK: riding

    private var riding: some View {
        VStack(spacing: 16) {
            Text(ride.headline)
                .font(.system(size: 40, weight: .heavy)).multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: 140)
                .padding()
                .foregroundStyle(ride.getOffNow ? .white : .primary)
                .background(ride.getOffNow ? Color.red : Color.yellow.opacity(0.35), in: RoundedRectangle(cornerRadius: 24))
                .accessibilityAddTraits(.isHeader)
            Text(ride.detail).font(.title3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let t = ride.tracker, let leg = t.current {
                stopList(leg, at: t.at)
            }
            Spacer(minLength: 0)
            if ride.phase == .waiting {
                BigButton(title: tr("Find the open door", "Offene Tür finden"), systemImage: "door.left.hand.open", color: .green,
                          explanation: tr("When the train is here: hold the phone towards it. I guide you to the open door.",
                                          "Wenn der Zug da ist: Telefon zum Zug halten. Ich führe Sie zur offenen Tür.")) { ride.findDoor() }
            }
            if ride.phase == .arrived {
                BigButton(title: tr("Guide me out", "Hinausführen"), systemImage: "figure.walk", color: .green,
                          explanation: tr("The camera guide leads you to the nearest exit, then on to your destination.",
                                          "Die Kamera-Begleitung führt Sie zum nächsten Ausgang, dann weiter zum Ziel.")) {
                    ride.guideOut(); dismiss()
                }
            }
            HStack(spacing: 12) {
                BigButton(title: tr("Where am I?", "Wo bin ich?"), color: .blue,
                          explanation: tr("Says the line, the next stop and how many stops are left.",
                                          "Sagt die Linie, die nächste Station und wie viele noch kommen.")) { ride.sayStatus() }
                BigButton(title: tr("Help", "Hilfe"), color: .red,
                          explanation: tr("Shows a card asking other passengers for help, and reads it aloud.",
                                          "Zeigt eine Karte, die andere Fahrgäste um Hilfe bittet, und liest sie vor.")) { showHelp = true }
            }
            if ride.simulated { Text("Dev: ×20").font(.caption.bold()).foregroundStyle(.purple) }
        }
        .padding()
    }

    private func stopList(_ leg: RideTrip.Leg, at: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(leg.all.enumerated()), id: \.offset) { i, s in
                    HStack {
                        Image(systemName: i < at ? "checkmark.circle.fill" : i == at ? "tram.fill" : i == leg.all.count - 1 ? "flag.checkered" : "circle")
                            .foregroundStyle(i == at ? .orange : i < at ? .secondary : .primary)
                        Text(s.name).font(i == leg.all.count - 1 ? .headline : .body)
                            .foregroundStyle(i < at ? .secondary : .primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .accessibilityHidden(true)       // "Where am I?" says the same in one sentence
    }
}

/// Shown to other people: big, in German first (Munich), English below, and read aloud in German.
struct HelpCard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let station: String?

    /// The card's words (German, English), from the person's modes; used by the story too.
    static func words(store: AppStore, station: String?) -> (de: String, en: String) {
        let who: (String, String)
        if store.has(.deafblind) { who = ("Ich bin taubblind.", "I am deafblind.") }
        else if store.has(.sight) { who = ("Ich bin blind.", "I am blind.") }
        else if store.has(.lowVision) { who = ("Ich sehe sehr schlecht.", "I have very low vision.") }
        else if store.has(.hearing) { who = ("Ich bin gehörlos.", "I am deaf.") }
        else if store.has(.speech) { who = ("Ich kann nicht sprechen.", "I cannot speak.") }
        else if store.has(.dementia) { who = ("Ich habe Gedächtnisprobleme.", "I have memory problems.") }
        else { who = ("Ich brauche Hilfe.", "I need help.") }
        let ask = station.map { ("Bitte helfen Sie mir, an \($0) auszusteigen.", "Please help me get off at \($0).") }
            ?? ("Bitte helfen Sie mir.", "Please help me.")
        return ("\(who.0) \(ask.0)", "\(who.1) \(ask.1)")
    }
    private var who: (de: String, en: String) { Self.words(store: store, station: station) }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text(who.de).font(.system(size: 44, weight: .heavy)).multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
            Text(who.en).font(.title).multilineTextAlignment(.center)
            Spacer()
            Button { Speaker.shared.say(who.de, language: "de-DE") } label: {
                Label(tr("Say it aloud again", "Nochmal vorlesen"), systemImage: "speaker.wave.3.fill").font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent).tint(.black)
            Button { SafetyService.shared.requestHelp(); dismiss() } label: {
                Label(tr("Call my contact", "Meinen Kontakt anrufen"), systemImage: "phone.fill").font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            Button(tr("Close", "Schließen")) { dismiss() }.font(.title3).padding(.bottom)
        }
        .padding()
        .foregroundStyle(.black)
        .background(Color.yellow.ignoresSafeArea())
        .onAppear { Speaker.shared.say(who.de, language: "de-DE") }
    }
}
