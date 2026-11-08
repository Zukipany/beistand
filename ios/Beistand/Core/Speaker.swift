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
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.85

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
        let lang = language
        queue.async { [self] in _ = voice(for: lang) }  // warm up early
    }

    /// `word` is called on the main queue with the range of each word as it is spoken (for highlighting).
    func say(_ text: String, interrupt: Bool = true, word: ((NSRange) -> Void)? = nil, then done: (() -> Void)? = nil) {
        let lang = language, rate = rate
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
        let v = AVSpeechSynthesisVoice(language: lang)
        voices[lang] = v
        return v
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
