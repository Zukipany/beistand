import SwiftUI
import AVFoundation

/// Sign-up asks what is hard, never for a diagnosis. Everything is spoken
/// and can be answered by voice or by tapping, so a blind person can sign up alone.
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @State private var step = 0
    @State private var modes: Set<Mode> = []
    @State private var name = ""
    @State private var contactName = ""
    @State private var contactPhone = "+49"
    @State private var listener = Listener()
    @State private var timeout: Task<Void, Never>?
    /// From the iPhone's own accessibility settings; those questions are skipped.
    @State private var detected: [SystemAccessibility.Hint] = []

    struct Question {
        let text: String
        let answers: [(label: String, modes: [Mode])]
        /// What happens when nobody taps: a blind person cannot see the buttons.
        let silenceMeans: [Mode]?
        var playsTone = false
        /// Skip the question when the iPhone settings already answered it.
        var answeredBy: Set<Mode> = []
    }

    private var questions: [Question] {
        let yes = tr("Yes", "Ja"), no = tr("No", "Nein")
        return [
            Question(text: tr("Can you read this text?", "Können Sie diesen Text lesen?"),
                     answers: [(yes, []), (tr("Only with effort", "Nur mit Mühe"), [.lowVision]), (no, [.sight])],
                     silenceMeans: [.sight], answeredBy: [.sight, .lowVision]),
            Question(text: tr("Can you hear this tone?", "Hören Sie diesen Ton?"),
                     answers: [(yes, []), (no, [.hearing])], silenceMeans: nil, playsTone: true, answeredBy: [.hearing]),
            Question(text: tr("Would you like a simple home screen with four big buttons?",
                              "Möchten Sie eine einfache Startseite mit vier großen Knöpfen?"),
                     answers: [(yes, [.older]), (no, [])], silenceMeans: [.older]),
            Question(text: tr("Do you use a wheelchair, walker or pram?",
                              "Nutzen Sie einen Rollstuhl, Rollator oder Kinderwagen?"),
                     answers: [(yes, [.wheelchair]), (no, [])], silenceMeans: nil),
            Question(text: tr("Do you sometimes forget the way home?", "Vergessen Sie manchmal den Weg nach Hause?"),
                     answers: [(yes, [.dementia]), (no, [])], silenceMeans: nil),
            Question(text: tr("Is speaking hard for you?", "Fällt Ihnen das Sprechen schwer?"),
                     answers: [(yes, [.speech]), (no, [])], silenceMeans: nil),
            Question(text: tr("Do crowds, noise or long texts stress you?",
                              "Stressen Sie Menschenmengen, Lärm oder lange Texte?"),
                     answers: [(yes, [.calm, .easyReading]), (no, [])], silenceMeans: nil),
        ]
    }

    /// Questions the iPhone settings did not already answer; numbering counts only these.
    private var asked: [Int] {
        let known = Set(detected.map(\.mode))
        return questions.indices.filter { questions[$0].answeredBy.isDisjoint(with: known) }
    }

    var body: some View {
        FitScroll {
        VStack(spacing: 24) {
            VolumeBanner()
            if step == 0 {
                welcome
            } else if step <= questions.count {
                question(questions[step - 1])
            } else {
                contactForm
            }
        }
        .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task { VolumeMonitor.shared.start(); _ = await Listener.requestPermission() }
        .onAppear {
            detected = SystemAccessibility.hints()
            modes.formUnion(detected.map(\.mode))
        }
    }

    // MARK: steps

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(tr("Welcome to Beistand", "Willkommen bei Beistand")).font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text(tr("What is your name?", "Wie heißen Sie?")).font(.title)
            TextField(tr("Your name", "Ihr Name"), text: $name)
                .font(.title).textFieldStyle(.roundedBorder).textContentType(.givenName)
            if listener.isListening { Label(tr("Listening …", "Ich höre zu …"), systemImage: "mic.fill").font(.title3) }
            Spacer()
            BigButton(title: tr("Next", "Weiter"), color: .green) { next() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear {
            let found = SystemAccessibility.hints()
            let intro = found.isEmpty ? "" :
                tr("I can see: ", "Ich sehe: ") + found.map(\.reason).joined(separator: ", ") +
                tr(". I'll set the app up to match. ", ". Das stelle ich gleich passend ein. ")
            Speaker.shared.say(tr("Welcome to Beistand. \(intro)I'll ask you a few short questions. You can answer out loud or tap. What is your name?",
                                  "Willkommen bei Beistand. \(intro)Ich stelle Ihnen ein paar kurze Fragen. Sie können antworten oder tippen. Wie heißen Sie?")) {
                listener.start()
            }
        }
        .onChange(of: listener.transcript) { _, t in
            let words = t.split(separator: " ")
            if let last = words.last, words.count <= 4 { name = String(last).capitalized }
        }
    }

    private func question(_ q: Question) -> some View {
        VStack(spacing: 20) {
            Text(tr("Question \((asked.firstIndex(of: step - 1) ?? 0) + 1) of \(asked.count)",
                    "Frage \((asked.firstIndex(of: step - 1) ?? 0) + 1) von \(asked.count)")).font(.headline).foregroundStyle(.secondary)
            Spacer()
            Text(q.text).scaledFont(40, maxFactor: 1.6).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            ForEach(q.answers.indices, id: \.self) { i in
                BigButton(title: q.answers[i].label, color: i == 0 ? .green : .blue) { answer(q.answers[i].modes) }
            }
        }
        .id(step)
        .onAppear { ask(q) }
        // The tone question waits for the volume: on a quiet phone "No" would wrongly mean hearing loss.
        .onChange(of: VolumeMonitor.shared.tooQuiet) { _, quiet in
            if q.playsTone, !quiet { ask(q) }
        }
        .onChange(of: listener.transcript) { _, t in
            guard let yes = Listener.yesNo(t) else { return }
            let match = yes ? q.answers.first : q.answers.last
            if let match { answer(match.modes) }
        }
    }

    private var contactForm: some View {
        VStack(spacing: 20) {
            Text(tr("Who should we call when you need help?", "Wen sollen wir anrufen, wenn Sie Hilfe brauchen?")).font(.title.bold()).multilineTextAlignment(.center)
            TextField(tr("Name, e.g. Anna", "Name, z. B. Anna"), text: $contactName).font(.title2).textFieldStyle(.roundedBorder)
            TextField(tr("Phone number", "Telefonnummer"), text: $contactPhone).font(.title2).textFieldStyle(.roundedBorder)
                .keyboardType(.phonePad).textContentType(.telephoneNumber)
            Text(tr("A relative can fill this in, too.", "Auch ein Angehöriger kann das ausfüllen.")).font(.body).foregroundStyle(.secondary)
            Spacer()
            BigButton(title: tr("Done", "Fertig"), color: .green) { finish() }.disabled(!phoneValid || contactName.isEmpty)
        }
        .onAppear {
            listener.stop()
            Speaker.shared.say(tr("Last question. Who should we call when you need help? You can ask a relative to type in the number.",
                                  "Letzte Frage. Wen sollen wir anrufen, wenn Sie Hilfe brauchen? Bitten Sie gern einen Angehörigen, die Nummer einzutippen."))
        }
    }

    // MARK: logic

    private var phoneValid: Bool {
        contactPhone.range(of: #"^\+[1-9]\d{6,14}$"#, options: .regularExpression) != nil
    }

    private func ask(_ q: Question) {
        listener.stop()
        timeout?.cancel()
        if q.playsTone, VolumeMonitor.shared.tooQuiet {
            Speaker.shared.say(tr("Please turn the volume up first, with the button on the left side.",
                                  "Bitte stellen Sie zuerst lauter, mit der Taste links am Telefon."))
            return
        }
        let speak = q.playsTone ? tr("Can you hear this tone? Tap Yes or No.", "Hören Sie diesen Ton? Tippen Sie auf Ja oder Nein.")
                                : q.text + tr(" Say yes or no.", " Sagen Sie Ja oder Nein.")
        if q.playsTone { Tone.play(hz: 1000, seconds: 1.0) }
        Speaker.shared.say(speak) { listener.start() }
        guard let silence = q.silenceMeans else { return }
        timeout = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { answer(silence) }
        }
    }

    private func answer(_ m: [Mode]) {
        timeout?.cancel()
        listener.stop()
        modes.formUnion(m)
        next()
    }

    private func next() {
        step += 1
        while step >= 1, step <= questions.count, !asked.contains(step - 1) { step += 1 }
    }

    private func finish() {
        store.profile = Profile(userId: UUID().uuidString.lowercased(), name: name, language: Lang.code, modes: modes,
                                contacts: [EmergencyContact(name: contactName, phone: contactPhone)])
        UserDefaults.standard.set(detected.map(\.mode.rawValue), forKey: "a11ySeen")
        SafetyService.shared.startMonitoring()
        Speaker.shared.say(tr("Thank you, \(name). Beistand is ready.", "Danke, \(name). Beistand ist bereit."))
    }
}

/// A plain sine tone for the hearing question.
enum Tone {
    private static let engine = AVAudioEngine()
    private static var player = AVAudioPlayerNode()

    static func play(hz: Double, seconds: Double, rising: Bool = false, volume: Float = 0.6) {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(seconds * fmt.sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        var phase = 0.0
        for i in 0..<Int(frames) {
            let f = rising ? hz * (1 + Double(i) / Double(frames)) : hz
            phase += 2 * .pi * f / fmt.sampleRate
            buf.floatChannelData![0][i] = Float(sin(phase)) * volume
        }
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
        }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buf, at: nil, options: .interrupts)
        player.play()
    }

    static func stop() { player.stop() }
}
