import SwiftUI
import UserNotifications

// MARK: speech: picture board and type to speak

/// For people who cannot speak: tap a picture and the phone says it (in their own voice when they set up
/// Personal Voice). Topics first, so a phrase is two taps away. Type to speak at the top.
struct PictureBoard: View {
    @Environment(\.dismiss) private var dismiss
    @State private var topic = 0
    @State private var typed = ""
    @State private var german = Lang.german

    struct Card: Identifiable { let icon: String; let en: String; let de: String; var id: String { en } }
    static let topics: [(icon: String, en: String, de: String, cards: [Card])] = [
        ("hand.raised.fill", "Needs", "Bedürfnisse", [
            Card(icon: "drop.fill", en: "I need water, please.", de: "Ich brauche bitte Wasser."),
            Card(icon: "toilet.fill", en: "Where is the toilet?", de: "Wo ist die Toilette?"),
            Card(icon: "fork.knife", en: "I am hungry.", de: "Ich habe Hunger."),
            Card(icon: "bed.double.fill", en: "I need to rest.", de: "Ich muss mich ausruhen."),
            Card(icon: "cross.case.fill", en: "I am in pain.", de: "Ich habe Schmerzen."),
            Card(icon: "sos", en: "Please call help.", de: "Bitte rufen Sie Hilfe."),
        ]),
        ("bubble.left.fill", "Talk", "Reden", [
            Card(icon: "hand.thumbsup.fill", en: "Yes.", de: "Ja."),
            Card(icon: "hand.thumbsdown.fill", en: "No.", de: "Nein."),
            Card(icon: "heart.fill", en: "Thank you!", de: "Danke!"),
            Card(icon: "arrow.counterclockwise", en: "Please say it again.", de: "Bitte noch einmal."),
            Card(icon: "tortoise.fill", en: "Please speak slowly.", de: "Bitte sprechen Sie langsam."),
            Card(icon: "pencil", en: "Please write it down.", de: "Bitte schreiben Sie es auf."),
        ]),
        ("face.smiling.fill", "Feelings", "Gefühle", [
            Card(icon: "face.smiling", en: "I am fine.", de: "Mir geht es gut."),
            Card(icon: "cloud.rain.fill", en: "I feel sad.", de: "Ich bin traurig."),
            Card(icon: "exclamationmark.triangle.fill", en: "I am scared.", de: "Ich habe Angst."),
            Card(icon: "thermometer.medium", en: "I feel ill.", de: "Mir ist schlecht."),
            Card(icon: "snowflake", en: "I am cold.", de: "Mir ist kalt."),
            Card(icon: "sun.max.fill", en: "I am too hot.", de: "Mir ist zu warm."),
        ]),
        ("figure.walk", "Out", "Unterwegs", [
            Card(icon: "tram.fill", en: "Which train goes to the city centre?", de: "Welche Bahn fährt ins Zentrum?"),
            Card(icon: "mappin.and.ellipse", en: "Can you show me the way?", de: "Können Sie mir den Weg zeigen?"),
            Card(icon: "cart.fill", en: "How much does this cost?", de: "Wie viel kostet das?"),
            Card(icon: "creditcard.fill", en: "Can I pay by card?", de: "Kann ich mit Karte zahlen?"),
            Card(icon: "house.fill", en: "I want to go home.", de: "Ich möchte nach Hause."),
            Card(icon: "person.2.fill", en: "Please call my family.", de: "Bitte rufen Sie meine Familie an."),
        ]),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField(tr("Type, and I say it", "Tippen, und ich sage es"), text: $typed, axis: .vertical)
                            .font(.title2).lineLimit(1...3).padding(12).surface(cornerRadius: 18)
                            .onSubmit { say(typed) }
                        Button { say(typed) } label: {
                            Image(systemName: "speaker.wave.3.fill").font(.title.bold()).foregroundStyle(.white)
                                .frame(width: 64, height: 64).surface(.blue, cornerRadius: 32, interactive: true)
                        }
                        .buttonStyle(.plain).disabled(typed.isEmpty)
                        .accessibilityLabel(tr("Say it", "Sagen"))
                    }
                    Picker(tr("Topic", "Thema"), selection: $topic) {
                        ForEach(Self.topics.indices, id: \.self) { i in
                            Label(Lang.german ? Self.topics[i].de : Self.topics[i].en, systemImage: Self.topics[i].icon).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(Self.topics[topic].cards) { c in
                            Tile(title: Lang.german ? c.de : c.en, icon: c.icon, tint: topic == 0 && c.icon == "sos" ? .red : .indigo) {
                                say(german ? c.de : c.en)
                            }
                        }
                    }
                    if !Lang.german {
                        Toggle(tr("Say it in German (for people around me)", "Auf Deutsch sagen"), isOn: $german).font(.headline)
                    }
                }
                .padding(16)
            }
            .background(BeistandBackground())
            .navigationTitle(tr("Talk with pictures", "Mit Bildern sprechen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(tr("Close", "Schließen")) { dismiss() } }
        }
    }

    private func say(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Speaker.shared.say(t, language: german ? "de-DE" : nil)
    }
}

// MARK: older people: morning check-in, medicines

/// "How are you today?" once a day; "not so good" offers to call family.
struct CheckInCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var notGood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(notGood ? tr("Shall I call \(contact)?", "Soll ich \(contact) anrufen?") : tr("Good morning! How are you today?", "Guten Morgen! Wie geht es Ihnen heute?"))
                .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if notGood {
                    BigButton(title: tr("Yes, call", "Ja, anrufen"), systemImage: "phone.fill", color: .green) { call() }
                    BigButton(title: tr("No", "Nein"), color: .gray) { answer() }
                } else {
                    BigButton(title: tr("Good", "Gut"), systemImage: "face.smiling", color: .green) {
                        Speaker.shared.say(tr("Lovely. Have a good day!", "Schön. Einen guten Tag!")); answer()
                    }
                    BigButton(title: tr("Not so good", "Nicht so gut"), systemImage: "cloud.rain", color: .orange) {
                        notGood = true
                        Speaker.shared.say(tr("I'm sorry. Shall I call \(contact)?", "Das tut mir leid. Soll ich \(contact) anrufen?"))
                    }
                }
            }
        }
        .padding(16).surface(cornerRadius: 24)
    }

    private var contact: String { store.profile?.contacts.first?.name ?? tr("your family", "Ihre Familie") }
    private func answer() { store.lastCheckIn = Date(); notGood = false }
    private func call() {
        answer()
        if let c = store.profile?.contacts.first, let url = URL(string: "tel://\(c.phone)") { openURL(url) }
    }
}

/// The next (or missed) dose with a big "Taken" button.
struct MedicineCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let (m, time, due) = MedicineSchedule.current(store.medicines, taken: store.takenDoses, now: Date()) {
            HStack(spacing: 12) {
                Image(systemName: "pills.fill").font(.largeTitle).foregroundStyle(due ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.title2.bold())
                    Text((due ? tr("Due since ", "Fällig seit ") : tr("Next at ", "Nächste um ")) + time.formatted(date: .omitted, time: .shortened)
                         + (m.note.isEmpty ? "" : " · \(m.note)")).font(.headline).foregroundStyle(.secondary)
                }
                Spacer()
                if due {
                    Button {
                        store.takenDoses.insert(MedicineSchedule.key(m, time))
                        Speaker.shared.say(tr("Noted: \(m.name) taken.", "Notiert: \(m.name) genommen."))
                    } label: {
                        Text(tr("Taken", "Genommen")).font(.title3.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 18).frame(minHeight: 56).surface(.green, cornerRadius: 28, interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16).surface(cornerRadius: 24)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Settings → Medicines: name, times, note. Reminders as notifications at each time.
struct MedicinesView: View {
    @Environment(AppStore.self) private var store
    @State private var name = ""
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
    @State private var times: [DateComponents] = []
    @State private var note = ""

    var body: some View {
        @Bindable var store = store
        List {
            Section(tr("Medicines", "Medikamente")) {
                ForEach(store.medicines) { m in
                    VStack(alignment: .leading) {
                        Text(m.name).font(.headline)
                        Text(m.times.map { String(format: "%02d:%02d", $0.hour ?? 0, $0.minute ?? 0) }.joined(separator: ", ")
                             + (m.note.isEmpty ? "" : " · \(m.note)")).foregroundStyle(.secondary)
                    }
                }
                .onDelete { store.medicines.remove(atOffsets: $0); Reminders.schedule(store.medicines) }
            }
            Section(tr("Add a medicine", "Medikament hinzufügen")) {
                TextField(tr("Name, e.g. Ramipril", "Name, z. B. Ramipril"), text: $name)
                TextField(tr("Note, e.g. with food", "Hinweis, z. B. zum Essen"), text: $note)
                HStack {
                    DatePicker(tr("Time", "Uhrzeit"), selection: $time, displayedComponents: .hourAndMinute)
                    Button(tr("Add time", "Zeit dazu")) {
                        times.append(Calendar.current.dateComponents([.hour, .minute], from: time))
                    }
                }
                if !times.isEmpty {
                    Text(times.map { String(format: "%02d:%02d", $0.hour ?? 0, $0.minute ?? 0) }.joined(separator: ", "))
                }
                Button(tr("Save", "Speichern")) {
                    let t = times.isEmpty ? [Calendar.current.dateComponents([.hour, .minute], from: time)] : times
                    store.medicines.append(Medicine(name: name, times: t, note: note))
                    Reminders.schedule(store.medicines)
                    name = ""; note = ""; times = []
                }
                .disabled(name.isEmpty)
            }
        }
        .navigationTitle(tr("Medicines", "Medikamente"))
    }
}

/// Medicine reminders and the morning check-in as local notifications (nothing leaves the phone).
enum Reminders {
    static func schedule(_ meds: [Medicine], checkInHour: Int? = 9) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            c.removeAllPendingNotificationRequests()
            for m in meds {
                for (i, t) in m.times.enumerated() {
                    let content = UNMutableNotificationContent()
                    content.title = tr("Time for \(m.name)", "Zeit für \(m.name)")
                    content.body = m.note.isEmpty ? tr("Open Beistand and tap Taken.", "Öffnen Sie Beistand und tippen Sie auf Genommen.") : m.note
                    content.sound = .default
                    c.add(UNNotificationRequest(identifier: "med-\(m.id)-\(i)", content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: t, repeats: true)))
                }
            }
            if let h = checkInHour {
                let content = UNMutableNotificationContent()
                content.title = tr("Good morning", "Guten Morgen")
                content.body = tr("How are you today?", "Wie geht es Ihnen heute?")
                c.add(UNNotificationRequest(identifier: "checkin", content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: h, minute: 0), repeats: true)))
            }
        }
    }
}

// MARK: memory: day anchor and the way home

/// "Today is Monday, 10 November. It is afternoon. You are near Marienplatz." and one button home.
struct DayAnchorCard: View {
    @Environment(AppStore.self) private var store
    @State private var place: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(DayAnchor.sentence(now: Date(), place: place)).font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            if let home = store.home {
                BigButton(title: tr("Take me home", "Bring mich nach Hause"), systemImage: "house.fill", color: .green,
                          explanation: tr("The camera guide leads you home, step by step.", "Die Kamera-Begleitung führt Sie Schritt für Schritt nach Hause.")) {
                    GuideController.shared.go(to: home, name: tr("Home", "Zuhause"))
                    GuideController.shared.requestedOpen = true
                }
            }
        }
        .padding(16).surface(cornerRadius: 24)
        .onTapGesture { Speaker.shared.say(DayAnchor.sentence(now: Date(), place: place)) }
        .task {
            guard let l = await LocationService.shared.current() else { return }
            if let home = store.home, Geo.distance(home, Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude)) < 60 {
                place = tr("You are at home.", "Sie sind zu Hause.")
            } else {
                place = await LocationService.shared.describe(l)
            }
        }
    }
}

/// Settings: the home address for "Take me home".
struct HomeAddressRow: View {
    @Environment(AppStore.self) private var store
    @State private var address = ""
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading) {
            TextField(tr("Home address", "Wohnadresse"), text: $address).onSubmit(save)
            HStack {
                Button(tr("Here is home", "Hier ist zu Hause")) {
                    Task {
                        if let l = await LocationService.shared.current() {
                            store.home = Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
                            status = tr("Saved: this place is home.", "Gespeichert: dieser Ort ist zu Hause.")
                        }
                    }
                }
                Spacer()
                if store.home != nil { Image(systemName: "house.fill").foregroundStyle(.green) }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func save() {
        Task {
            let here = LocationService.shared.last?.coordinate
            let q = ["q": address, "lat": "\(here?.latitude ?? 48.137)", "lon": "\(here?.longitude ?? 11.575)", "lang": Lang.code]
            if let r: GuideAPI.Places = try? await GuideAPI.get("geocode", q), let p = r.data.first {
                store.home = Coord(lat: p.lat, lon: p.lon)
                status = tr("Saved: \(p.address ?? p.name)", "Gespeichert: \(p.address ?? p.name)")
            } else {
                status = tr("Address not found.", "Adresse nicht gefunden.")
            }
        }
    }
}
