import AVFoundation

/// Speaks one short message at a time. Slower for older users.
///
/// All synthesizer work runs on a private serial queue: the first
/// `AVSpeechSynthesisVoice(language:)` lookup can block for a long time
/// (voice catalogue sync), and on the main thread that froze the whole app.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    private let queue = DispatchQueue(label: "beistand.speaker", qos: .userInitiated)
    private var voices: [String: AVSpeechSynthesisVoice] = [:]  // only touched on `queue`
    private var onDone: (() -> Void)?                           // only touched on `queue`
    private var onWord: ((NSRange) -> Void)?                    // only touched on `queue`
    var language: String { Lang.speech }
    /// Calm by default; Settings → Voice changes it.
    var rate: Float { AppStore.shared.speechPace.rate }

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
        let lang = language
        queue.async { [self] in _ = voice(for: lang) }  // warm up early
    }

    /// `word` is called on the main queue with the range of each word as it is spoken (for highlighting).
    /// `language`: a BCP-47 voice language other than the app's (e.g. counter mode speaking to staff).
    func say(_ text: String, interrupt: Bool = true, language: String? = nil,
             word: ((NSRange) -> Void)? = nil, then done: (() -> Void)? = nil) {
        let lang = language ?? self.language, rate = rate
        // Fallback: if speech stalls (voice lookup can hang on a fresh device),
        // still continue after roughly the time the sentence would take.
        if let done {
            var fired = false
            let once = { if !fired { fired = true; done() } }
            let wrapped = once
            let estimate = 1.5 + Double(text.count) * 0.085
            DispatchQueue.main.asyncAfter(deadline: .now() + estimate, execute: wrapped)
            say(text, interrupt: interrupt, lang: lang, rate: rate, word: word, done: { DispatchQueue.main.async(execute: wrapped) })
            return
        }
        say(text, interrupt: interrupt, lang: lang, rate: rate, word: word, done: nil)
    }

    private func say(_ text: String, interrupt: Bool, lang: String, rate: Float, word: ((NSRange) -> Void)?, done: (() -> Void)?) {
        queue.async { [self] in
            if interrupt, synth.isSpeaking {
                onDone = nil
                onWord = nil
                synth.stopSpeaking(at: .immediate)
            }
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playAndRecord, mode: .spokenAudio,
                               options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try? s.setActive(true)
            let u = AVSpeechUtterance(string: text)
            u.voice = voice(for: lang)
            u.rate = rate
            u.pitchMultiplier = AppStore.shared.speechPace.pitch
            u.postUtteranceDelay = 0.08             // a breath between sentences
            onDone = done
            onWord = word
            synth.speak(u)
        }
    }

    func stop() {
        queue.async { [self] in
            onDone = nil
            onWord = nil
            synth.stopSpeaking(at: .immediate)
        }
    }

    private func voice(for lang: String) -> AVSpeechSynthesisVoice? {
        if let v = voices[lang] { return v }
        let v = Voices.voice(for: lang)
        voices[lang] = v
        return v
    }

    /// A different voice was chosen (or downloaded): look them up again.
    func voicesChanged() { queue.async { [self] in voices = [:] } }

    /// Preview a voice in Settings, whatever is chosen.
    func preview(_ v: AVSpeechSynthesisVoice) {
        queue.async { [self] in
            synth.stopSpeaking(at: .immediate)
            let u = AVSpeechUtterance(string: Voices.sample(v))
            u.voice = v
            u.rate = rate
            u.pitchMultiplier = AppStore.shared.speechPace.pitch
            synth.speak(u)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance u: AVSpeechUtterance) {
        queue.async { [self] in
            if let w = onWord { DispatchQueue.main.async { w(range) } }
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        queue.async { [self] in
            onWord = nil
            let d = onDone; onDone = nil
            if let d { DispatchQueue.main.async(execute: d) }
        }
    }
}
