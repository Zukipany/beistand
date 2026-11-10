import SwiftUI

/// "Step by step": for people who see but do not speak, or want more guidance. One question at a
/// time, big answers; an answer leads to the next question, shows the information right there,
/// or opens the tool. Nothing to type, nothing to say.
struct StoryStep: Identifiable, Equatable {
    struct Answer: Identifiable, Equatable {
        enum Then: Equatable { case step(String), open(Destination), show(StoryInfo) }
        let title: String
        let icon: String
        var tint: Color = .blue
        let then: Then
        var id: String { title }
    }
    let id: String
    let question: String
    var hint: String? = nil
    let answers: [Answer]
}

/// Information shown inside the story instead of opening another screen.
enum StoryInfo: Equatable { case whereAmI, departures, helpCard }

enum Story {
    static let start = "start"

    static var steps: [String: StoryStep] {
        let list: [StoryStep] = [
            StoryStep(id: start, question: tr("What do you need?", "Was brauchen Sie?"), answers: [
                .init(title: tr("Get somewhere", "Irgendwo hinkommen"), icon: "figure.walk", tint: .teal, then: .step("go")),
                .init(title: tr("Read something", "Etwas lesen"), icon: "doc.text.magnifyingglass", tint: .indigo, then: .step("read")),
                .init(title: tr("Talk with someone", "Mit jemandem sprechen"), icon: "bubble.left.and.bubble.right.fill", tint: .blue, then: .step("talk")),
                .init(title: tr("I need help", "Ich brauche Hilfe"), icon: "hand.raised.fill", tint: .red, then: .step("help")),
            ]),
            StoryStep(id: "go", question: tr("Where do you want to go?", "Wohin möchten Sie?"), answers: [
                .init(title: tr("Where am I?", "Wo bin ich?"), icon: "location.fill", tint: .indigo, then: .show(.whereAmI)),
                .init(title: tr("Find something nearby", "Etwas in der Nähe finden"), icon: "magnifyingglass", tint: .teal, then: .step("find")),
                .init(title: tr("Take the U-Bahn", "U-Bahn fahren"), icon: "tram.fill.tunnel", tint: .blue, then: .open(.ride(to: nil))),
                .init(title: tr("Next trains here", "Nächste Bahnen hier"), icon: "clock.fill", tint: .green, then: .show(.departures)),
                .init(title: tr("A place on the map", "Ein Ort auf der Karte"), icon: "map.fill", tint: .brown, then: .open(.map)),
            ]),
            StoryStep(id: "find", question: tr("What are you looking for?", "Was suchen Sie?"),
                      hint: tr("I lead you to the nearest one.", "Ich führe Sie zum nächsten."),
                      answers: PlaceSearch.categories.map { c in
                .init(title: c.name, icon: c.icon, tint: c.id == "station" ? .green : .indigo, then: .open(.find(c.name)))
            }),
            StoryStep(id: "read", question: tr("What do you want to read?", "Was möchten Sie lesen?"), answers: [
                .init(title: tr("A letter", "Einen Brief"), icon: "envelope.open.fill", tint: .indigo, then: .open(.read)),
                .init(title: tr("Small print", "Kleingedrucktes"), icon: "plus.magnifyingglass", tint: .purple, then: .open(.magnifier)),
                .init(title: tr("Is this message a scam?", "Ist diese Nachricht Betrug?"), icon: "exclamationmark.shield.fill", tint: .orange, then: .open(.scam)),
            ]),
            StoryStep(id: "talk", question: tr("How can I help you talk?", "Wie kann ich beim Sprechen helfen?"), answers: [
                .init(title: tr("Show me what people say", "Zeig mir, was gesagt wird"), icon: "captions.bubble.fill", tint: .indigo, then: .open(.captions)),
                .init(title: tr("At a counter or desk", "Am Schalter"), icon: "rectangle.split.1x2", tint: .blue, then: .open(.counter)),
                .init(title: tr("Show a card to people", "Eine Karte zeigen"), icon: "person.text.rectangle.fill", tint: .orange, then: .show(.helpCard)),
                .init(title: tr("Sounds around me", "Geräusche um mich"), icon: "ear.badge.waveform", tint: .teal, then: .open(.sounds)),
            ]),
            StoryStep(id: "help", question: tr("Do you need help now?", "Brauchen Sie jetzt Hilfe?"), answers: [
                .init(title: tr("Yes, alert my contact", "Ja, meinen Kontakt alarmieren"), icon: "sos", tint: .red, then: .open(.help)),
                .init(title: tr("Call my family", "Meine Familie anrufen"), icon: "phone.fill", tint: .green, then: .open(.callFamily)),
                .init(title: tr("Show a card to people nearby", "Eine Karte für Menschen in der Nähe"), icon: "person.text.rectangle.fill", tint: .orange, then: .show(.helpCard)),
                .init(title: tr("No, go back", "Nein, zurück"), icon: "arrow.uturn.backward", tint: .gray, then: .step(start)),
            ]),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
}

struct StoryView: View {
    /// Embedded on the home screen (no close button) or shown on its own.
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = [Story.start]
    @State private var info: StoryInfo?
    @State private var infoText = ""
    @State private var loading = false

    private var step: StoryStep? { Story.steps[path.last ?? Story.start] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let info { infoCard(info) } else if let step { answers(step) }
        }
        .animation(.snappy, value: path)
        .animation(.snappy, value: info)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Step by step", "Schritt für Schritt")).font(.subheadline.bold()).foregroundStyle(.secondary)
                Text(info.map(infoTitle) ?? step?.question ?? "").font(.title.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if info == nil, let hint = step?.hint { Text(hint).font(.headline).foregroundStyle(.secondary) }
            }
            Spacer()
            if path.count > 1 || info != nil {
                Button { back() } label: {
                    Image(systemName: "chevron.backward").font(.title2.bold()).frame(width: 52, height: 52)
                        .surface(cornerRadius: 26, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Back", "Zurück"))
            }
            if !embedded {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title2.bold()).frame(width: 52, height: 52)
                        .surface(cornerRadius: 26, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Close", "Schließen"))
            }
        }
    }

    private func answers(_ step: StoryStep) -> some View {
        GlassGroup(spacing: 12) {
            VStack(spacing: 12) {
                ForEach(step.answers) { a in
                    BigButton(title: a.title, systemImage: a.icon, color: a.tint) { choose(a) }
                }
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        .id(step.id)
    }

    private func choose(_ a: StoryStep.Answer) {
        switch a.then {
        case .step(let id):
            if id == Story.start { path = [Story.start] } else { path.append(id) }
        case .open(let d):
            if !embedded { dismiss() }
            AppRouter.shared.open(d)
        case .show(let i):
            info = i
            Task { await load(i) }
        }
    }

    private func back() {
        if info != nil { info = nil } else if path.count > 1 { path.removeLast() }
    }

    // MARK: information shown in place

    private func infoTitle(_ i: StoryInfo) -> String {
        switch i {
        case .whereAmI: tr("You are here", "Sie sind hier")
        case .departures: tr("Next trains", "Nächste Bahnen")
        case .helpCard: tr("Show this to someone", "Zeigen Sie das jemandem")
        }
    }

    @ViewBuilder private func infoCard(_ i: StoryInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if i == .helpCard {
                HelpCardContent()
            } else if loading {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text(infoText).font(.system(size: 30, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .surface(i == .helpCard ? .yellow : nil, cornerRadius: 26)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        if i != .helpCard {
            BigButton(title: tr("Take me somewhere", "Führe mich irgendwo hin"), systemImage: "figure.walk", color: .teal) {
                info = nil; path = [Story.start, "go"]
            }
        }
    }

    private func load(_ i: StoryInfo) async {
        loading = true
        defer { loading = false }
        switch i {
        case .whereAmI:
            guard let l = await LocationService.shared.current() else {
                infoText = tr("I can't find your position right now.", "Ich finde Ihre Position gerade nicht."); return
            }
            infoText = await LocationService.shared.describe(l)
        case .departures:
            let r = await GuideController.shared.nextDepartures()
            guard r["ok"] as? Bool == true, let stop = r["stop"] as? String, let deps = r["departures"] as? [[String: Any]], !deps.isEmpty else {
                infoText = r["message"] as? String ?? tr("No departures found.", "Keine Abfahrten gefunden."); return
            }
            let lines = deps.prefix(4).map { d -> String in
                let m = d["minutes"] as? Int ?? 0
                return "\(d["line"] as? String ?? "") → \(d["destination"] as? String ?? "")  " + (m == 0 ? tr("now", "jetzt") : "\(m) min")
            }
            infoText = "\(stop)\n" + lines.joined(separator: "\n")
        case .helpCard:
            break
        }
        if !infoText.isEmpty { Speaker.shared.say(infoText.replacingOccurrences(of: "→", with: tr("to", "nach"))) }
    }
}

/// The help card's words without the buttons, for the story.
struct HelpCardContent: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        let (de, en) = HelpCard.words(store: store, station: nil)
        VStack(alignment: .leading, spacing: 10) {
            Text(de).font(.system(size: 32, weight: .heavy)).foregroundStyle(.black)
            Text(en).font(.title2).foregroundStyle(.black)
        }
        .onAppear { Speaker.shared.say(de, language: "de-DE") }
    }
}
