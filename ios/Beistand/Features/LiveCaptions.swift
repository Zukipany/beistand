import AVFoundation
import Observation
import Speech
import SwiftUI
import Translation
import UIKit

/// How loud something was, and how big its caption should be. Pure, so it is testable.
/// Levels are dBFS from the microphone (0 = maximum, about −60 = quiet room). Shown to people
/// as an approximate sound level (dB SPL ≈ dBFS + 94 for an iPhone mic; varies by device).
enum Loudness {
    static let quietDB: Float = -50, loudDB: Float = -10

    static func fontSize(_ db: Float, min: CGFloat = 18, max: CGFloat = 60) -> CGFloat {
        let t = CGFloat((Swift.min(Swift.max(db, quietDB), loudDB) - quietDB) / (loudDB - quietDB))
        return min + (max - min) * t
    }

    static func weight(_ db: Float) -> Font.Weight {
        db > -18 ? .heavy : db > -30 ? .semibold : .regular
    }

    static func approxSPL(_ db: Float) -> Int { Int((db + 94).rounded()) }

    static func label(_ db: Float) -> String {
        switch db {
        case ..<(-45): tr("very quiet", "sehr leise")
        case ..<(-32): tr("quiet voice", "leise Stimme")
        case ..<(-20): tr("normal voice", "normale Stimme")
        case ..<(-12): tr("loud voice", "laute Stimme")
        default: tr("shouting / very loud", "Rufen / sehr laut")
        }
    }

    /// RMS level of a buffer in dBFS.
    static func dbfs(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return -100 }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        return rms > 0 ? Swift.max(-100, 20 * log10(rms)) : -100
    }

    /// Average level over a time window from a history of (time, dB) samples.
    static func average(_ history: [(t: Double, db: Float)], from: Double, to: Double) -> Float? {
        let inWindow = history.filter { $0.t >= from - 0.05 && $0.t <= to + 0.05 }.map(\.db)
        guard !inWindow.isEmpty else { return nil }
        // Average in the power domain, so one loud moment counts like it sounds.
        let power = inWindow.map { pow(10, $0 / 10) }.reduce(0, +) / Float(inWindow.count)
        return 10 * log10(power)
    }
}

struct CaptionWord: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var db: Float
    var end: Double? = nil      // audio time the word ended, to avoid repeating settled words
    static func == (a: Self, b: Self) -> Bool { a.text == b.text && a.db == b.db }
}

struct CaptionLine: Identifiable, Equatable {
    let id = UUID()
    var words: [CaptionWord]
    var translation: String? = nil
    var text: String { words.map(\.text).joined(separator: " ") }
    /// Loudness of the whole line, power-averaged, for sizing its translation.
    var db: Float {
        guard !words.isEmpty else { return -100 }
        return 10 * log10(words.map { pow(10, $0.db / 10) }.reduce(0, +) / Float(words.count))
    }
}

/// The language the other person speaks. Captions are translated into the app's language.
struct SpeakerLanguage: Identifiable, Hashable {
    let id: String          // BCP-47, e.g. "tr-TR"
    let name: String
    var locale: Locale { Locale(identifier: id) }
    var language: Locale.Language { locale.language }
    var isMine: Bool { locale.language.languageCode == Lang.locale.language.languageCode }

    /// Common languages in Munich first.
    static var all: [SpeakerLanguage] {
        let mine = SpeakerLanguage(id: Lang.speech, name: tr("Same as mine", "Wie meine"))
        let others: [(String, String, String)] = [
            ("de-DE", "German", "Deutsch"), ("en-US", "English", "Englisch"), ("tr-TR", "Turkish", "Türkisch"),
            ("uk-UA", "Ukrainian", "Ukrainisch"), ("ar-SA", "Arabic", "Arabisch"), ("pl-PL", "Polish", "Polnisch"),
            ("it-IT", "Italian", "Italienisch"), ("es-ES", "Spanish", "Spanisch"), ("fr-FR", "French", "Französisch"),
            ("ru-RU", "Russian", "Russisch"), ("ro-RO", "Romanian", "Rumänisch"), ("hr-HR", "Croatian", "Kroatisch"),
            ("el-GR", "Greek", "Griechisch"), ("zh-CN", "Chinese", "Chinesisch"),
        ]
        return [mine] + others.map { SpeakerLanguage(id: $0.0, name: tr($0.1, $0.2)) }.filter { !$0.isMine }
    }
}

/// Listens to the surroundings and turns speech into captions, each word sized by how loud it was said.
/// Speech engine: Apple's newer SpeechAnalyzer on iOS 26+ (better, exact word timing), else SFSpeechRecognizer.
/// Both run on the device. Optionally translates each line into the app's language (on-device Translation).
@Observable
final class LiveCaptioner {
    private(set) var lines: [CaptionLine] = []
    private(set) var current: [CaptionWord] = []
    private(set) var level: Float = -100            // smoothed, for the meter
    private(set) var listening = false
    private(set) var loudAlert = false
    private(set) var problem: String?
    private(set) var engine = "–"
    /// A named sound (siren, doorbell …) heard in the last few seconds, from the same microphone.
    private(set) var heardSound: SoundKind?
    @ObservationIgnored private var sounds: SoundClassifier?
    var speaker = SpeakerLanguage.all[0]
    /// Set when translation models for the chosen pair are installed (iOS 26+).
    @ObservationIgnored var translate: ((String) async -> String?)?

    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private var modern: AnyObject?              // ModernSpeech on iOS 26+
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var history: [(t: Double, db: Float)] = []   // main thread
    @ObservationIgnored private var requestStart: Double = 0
    @ObservationIgnored private var engineTime: Double = 0
    @ObservationIgnored private var lastResult = Date.distantPast
    @ObservationIgnored private var loudSince: Date?
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var demo: Task<Void, Never>?
    // Modern engine: settled words of the current line, and the end time of what is already shown in lines.
    @ObservationIgnored private var settled: [CaptionWord] = []
    @ObservationIgnored private var committedUntil: Double = -1

    func start() {
        guard !listening else { return }
        problem = nil
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "demoCaptions") { startDemo(); return }
        #endif
        Task { @MainActor in
            guard await Listener.requestPermission() else {
                problem = tr("Please allow the microphone and speech recognition in Settings.",
                             "Bitte erlauben Sie Mikrofon und Spracherkennung in den Einstellungen.")
                return
            }
            await startAudio()
        }
    }

    func stop() {
        demo?.cancel()
        silenceTimer?.invalidate()
        guard listening else { return }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        task?.cancel()
        if #available(iOS 26, *) { (modern as? ModernSpeech)?.stop() }
        modern = nil
        sounds = nil
        commit()
        listening = false
        level = -100
    }

    func clear() { lines = []; current = []; settled = [] }

    @MainActor private func startAudio() async {
        let s = AVAudioSession.sharedInstance()
        // Measurement mode turns off the automatic gain, so loud really reads as loud.
        try? s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? s.setActive(true)
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            problem = tr("No microphone found.", "Kein Mikrofon gefunden.")
            return
        }
        // Prefer the newer engine when it supports the speaker's language.
        if #available(iOS 26, *), await ModernSpeech.supported(speaker.locale) != nil {
            let m = ModernSpeech()
            modern = m
            engine = "SpeechAnalyzer"
            history = []; engineTime = 0; committedUntil = -1; settled = []
            Task { @MainActor in
                do {
                    try await m.start(locale: speaker.locale, inputFormat: format) { [weak self] words, final in
                        self?.modernResult(words, final: final)
                    }
                } catch {
                    self.problem = tr("The newer speech engine failed; using the standard one.",
                                      "Die neue Spracherkennung ging nicht; nutze die normale.")
                    self.modern = nil
                    self.engine = "SFSpeechRecognizer"
                    self.newRequest()
                }
            }
        } else {
            engine = "SFSpeechRecognizer"
        }
        input.removeTap(onBus: 0)
        var frames: Double = 0
        let sounds = SoundClassifier(format: format)
        sounds?.onAlert = { [weak self] kind in
            self?.heardSound = kind
            SoundHaptics.play(kind)
            WatchLink.shared.sound(kind)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self?.heardSound == kind { self?.heardSound = nil } }
        }
        self.sounds = sounds
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            sounds?.analyze(buf)
            if #available(iOS 26, *), let m = self.modern as? ModernSpeech { m.append(buf) }
            else { self.lock.lock(); self.request?.append(buf); self.lock.unlock() }
            frames += Double(buf.frameLength)
            let t = frames / format.sampleRate
            guard let ch = buf.floatChannelData else { return }
            let db = Loudness.dbfs(ch[0], count: Int(buf.frameLength))
            DispatchQueue.main.async { self.meter(db, at: t) }
        }
        audio.prepare()
        do { try audio.start() } catch {
            problem = tr("The microphone is busy.", "Das Mikrofon ist belegt.")
            return
        }
        listening = true
        if modern == nil { newRequest() }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.checkPause() }
    }

    private func meter(_ db: Float, at t: Double) {
        engineTime = t
        history.append((t, db))
        if history.count > 1200 { history.removeFirst(history.count - 1200) }   // ~25 s
        level = level < -90 ? db : level * 0.7 + db * 0.3
        // A sudden loud sound (alarm, horn, shout) is shown even without words.
        if db > -12 {
            if loudSince == nil { loudSince = Date() }
            if let s = loudSince, Date().timeIntervalSince(s) > 0.4, !loudAlert {
                loudAlert = true
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.loudAlert = false }
            }
        } else { loudSince = nil }
    }

    private func sized(_ w: HeardWord, previous: [CaptionWord], index: Int) -> CaptionWord {
        var db = level
        if let s = w.start, let e = w.end, e > s, let m = Loudness.average(history, from: s, to: e) { db = m }
        else if index < previous.count, previous[index].text == w.text { db = previous[index].db }
        return CaptionWord(text: w.text, db: db, end: w.end)
    }

    /// Modern engine: final results settle words; volatile results are the guess for what follows.
    private func modernResult(_ words: [HeardWord], final: Bool) {
        lastResult = Date()
        let fresh = words.filter { ($0.end ?? .infinity) > committedUntil }
        let sizedWords = fresh.enumerated().map { sized($1, previous: Array(current.dropFirst(settled.count)), index: $0) }
        if final {
            settled += sizedWords
            current = settled
        } else {
            current = settled + sizedWords
        }
    }

    // MARK: legacy engine (SFSpeechRecognizer)

    private func newRequest() {
        guard let recognizer = SFSpeechRecognizer(locale: speaker.locale), recognizer.isAvailable else {
            problem = tr("Speech recognition is not available for this language.",
                         "Spracherkennung ist für diese Sprache nicht verfügbar.")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        lock.lock(); request?.endAudio(); request = req; lock.unlock()
        requestStart = engineTime
        task?.cancel()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let r = result { self.legacyUpdate(r) }
                if result?.isFinal == true { self.commit(); if self.listening { self.newRequest() } }
                else if error != nil, self.listening, Date().timeIntervalSince(self.lastResult) > 1 {
                    self.commit(); self.newRequest()
                }
            }
        }
    }

    private func legacyUpdate(_ r: SFSpeechRecognitionResult) {
        lastResult = Date()
        current = r.bestTranscription.segments.enumerated().map { i, s in
            let w = HeardWord(text: s.substring,
                              start: s.duration > 0 ? requestStart + s.timestamp : nil,
                              end: s.duration > 0 ? requestStart + s.timestamp + s.duration : nil)
            return sized(w, previous: current, index: i)
        }
    }

    // MARK: lines

    /// A pause of 1.5 s ends the line, like a new subtitle.
    private func checkPause() {
        guard !current.isEmpty, Date().timeIntervalSince(lastResult) > 1.5 else { return }
        commit()
        if listening, modern == nil { newRequest() }
    }

    private func commit() {
        guard !current.isEmpty else { return }
        committedUntil = max(committedUntil, current.compactMap(\.end).max() ?? committedUntil)
        let line = CaptionLine(words: current)
        lines.append(line)
        if lines.count > 30 { lines.removeFirst(lines.count - 30) }
        current = []
        settled = []
        if let translate {
            let id = line.id, text = line.text
            Task { @MainActor in
                guard let out = await translate(text), let i = self.lines.firstIndex(where: { $0.id == id }) else { return }
                self.lines[i].translation = out
            }
        }
    }

    #if DEBUG
    /// Simulator test: a scripted conversation at different volumes (`-demoCaptions YES`).
    private func startDemo() {
        listening = true
        engine = "demo"
        let script: [(String, Float)] = [
            ("Good morning, how are you today?", -32), ("Excuse me!", -14), ("The next train is late", -26),
            ("WATCH OUT, BIKE!", -8), ("sorry, I didn't see you", -42), ("Platform two, please", -22),
        ]
        demo = Task { @MainActor in
            for (sentence, db) in script {
                for w in sentence.split(separator: " ") {
                    guard !Task.isCancelled else { return }
                    current.append(CaptionWord(text: String(w), db: db + Float.random(in: -3...3)))
                    level = db
                    loudAlert = db > -12
                    try? await Task.sleep(for: .milliseconds(280))
                }
                try? await Task.sleep(for: .milliseconds(900))
                commit()
            }
            loudAlert = false
        }
    }
    #endif
}

/// Hearing mode: what people around say, written out. Louder speech is bigger and bolder,
/// so you can tell a whisper from a shout. Loud sounds without words still show a warning.
/// "They speak" translates another language into yours, on the phone.
struct LiveCaptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var captioner = LiveCaptioner()
    @State private var translationNote: String?
    @State private var downloadConfig: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let k = captioner.heardSound { soundBanner(k) } else if captioner.loudAlert { loudBanner }
            captions
            controls
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { captioner.start() }
        .onDisappear { captioner.stop() }
        .translationTask(downloadConfig) { session in
            // Shows Apple's download sheet for the language pack once; afterwards translation is offline.
            try? await session.prepareTranslation()
            await setUpTranslation()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(tr("Live captions", "Live-Untertitel"), systemImage: "captions.bubble.fill").font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
                .accessibilityLabel(tr("Close", "Schließen"))
            }
            meter
            HStack {
                Menu {
                    ForEach(SpeakerLanguage.all) { l in
                        Button(l.name) { choose(l) }
                    }
                } label: {
                    Label(tr("They speak: \(captioner.speaker.name)", "Sie sprechen: \(captioner.speaker.name)"),
                          systemImage: "globe").font(.headline)
                }
                Spacer()
                Text(captioner.engine).font(.caption).foregroundStyle(.secondary)
            }
            if let translationNote {
                HStack {
                    Text(translationNote).font(.footnote)
                    if downloadConfig == nil, translationNote.contains("…") == false, canDownload {
                        Button(tr("Download", "Laden")) {
                            downloadConfig = TranslationSession.Configuration(source: captioner.speaker.language,
                                                                              target: Lang.locale.language)
                        }
                        .font(.footnote.bold())
                    }
                }
            }
            Text(tr("Bigger text = louder voice", "Größere Schrift = lautere Stimme"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }

    @State private var canDownload = false

    private func choose(_ l: SpeakerLanguage) {
        captioner.stop()
        captioner.speaker = l
        captioner.translate = nil
        translationNote = nil
        canDownload = false
        downloadConfig = nil
        Task {
            await setUpTranslation()
            captioner.start()
        }
    }

    /// Uses on-device translation when the language pack is installed; otherwise offers the download.
    @MainActor private func setUpTranslation() async {
        let l = captioner.speaker
        guard !l.isMine else { translationNote = nil; return }
        let status = await LanguageAvailability().status(from: l.language, to: Lang.locale.language)
        switch status {
        case .installed:
            if #available(iOS 26, *) {
                let session = TranslationSession(installedSource: l.language, target: Lang.locale.language)
                captioner.translate = { text in try? await session.translate(text).targetText }
                translationNote = tr("Translating into your language on this phone.",
                                     "Übersetzt in Ihre Sprache, auf dem Telefon.")
            } else {
                translationNote = tr("Translation needs iOS 26.", "Übersetzung braucht iOS 26.")
            }
        case .supported:
            canDownload = true
            translationNote = tr("To translate, download the language pack once.",
                                 "Zum Übersetzen einmal das Sprachpaket laden.")
        default:
            translationNote = tr("This language pair can't be translated on the phone.",
                                 "Diese Sprachen kann das Telefon nicht übersetzen.")
        }
    }

    private var meter: some View {
        let t = Double((min(max(captioner.level, -70), 0) + 70) / 70)
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(captioner.level > -12 ? Color.red : captioner.level > -30 ? Color.orange : Color.green)
                        .frame(width: g.size.width * t)
                }
            }
            .frame(height: 14)
            Text(captioner.listening
                 ? "≈ \(Loudness.approxSPL(captioner.level)) dB · \(Loudness.label(captioner.level))"
                 : (captioner.problem ?? tr("Starting …", "Starte …")))
                .font(.headline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private var loudBanner: some View {
        Label(tr("Loud sound nearby", "Lautes Geräusch in der Nähe"), systemImage: "exclamationmark.triangle.fill")
            .font(.title2.bold())
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(.white)
            .background(A11yColor.fill(.red))
            .accessibilityAddTraits(.updatesFrequently)
    }

    private func soundBanner(_ k: SoundKind) -> some View {
        Label(k.name, systemImage: k.icon)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(.white)
            .background(A11yColor.fill(k.urgent ? .red : .indigo))
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(captioner.lines.enumerated()), id: \.element.id) { i, line in
                        lineView(line)
                            .opacity(i >= captioner.lines.count - 3 ? 1 : 0.55)
                    }
                    if !captioner.current.isEmpty {
                        lineText(captioner.current)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: captioner.current) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: captioner.lines) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    @ViewBuilder private func lineView(_ line: CaptionLine) -> some View {
        if let t = line.translation {
            VStack(alignment: .leading, spacing: 4) {
                Text(t)
                    .font(.system(size: Loudness.fontSize(line.db), weight: Loudness.weight(line.db)))
                    .fixedSize(horizontal: false, vertical: true)
                Text(line.text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            lineText(line.words)
        }
    }

    /// One caption line: each word at its own size. Text concatenation keeps it wrapping as one paragraph.
    private func lineText(_ words: [CaptionWord]) -> some View {
        words.reduce(Text("")) { acc, w in
            acc + Text(w.text + " ").font(.system(size: Loudness.fontSize(w.db), weight: Loudness.weight(w.db)))
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(words.map(\.text).joined(separator: " "))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            BigButton(title: captioner.listening ? tr("Pause", "Pause") : tr("Listen", "Zuhören"),
                      systemImage: captioner.listening ? "pause.fill" : "mic.fill", color: .blue) {
                captioner.listening ? captioner.stop() : captioner.start()
            }
            BigButton(title: tr("Clear", "Leeren"), color: .gray) { captioner.clear() }
        }
        .padding()
    }
}
