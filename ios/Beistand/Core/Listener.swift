import AVFoundation
import Speech

/// On-device speech recognition for short answers ("ja", "nein", a name).
@Observable
final class Listener {
    var transcript = ""
    var isListening = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Lang.speech))

    static func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    func start() {
        guard !isListening, let recognizer, recognizer.isAvailable else { return }
        transcript = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
            req.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { return }
        isListening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                if let r = result { self?.transcript = r.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) { self?.stop() }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        isListening = false
    }

    /// Interprets a spoken yes/no. Returns nil when unclear.
    static func yesNo(_ text: String) -> Bool? {
        // Whole words only: "know" is not "no", "Japan" is not "ja".
        let words = Set(text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init))
        let no: Set = ["nein", "nö", "nicht", "no", "nope", "not", "don't"]
        let yes: Set = ["ja", "jawohl", "genau", "stimmt", "yes", "gut", "yeah", "yep", "sure", "okay", "ok"]
        if !words.isDisjoint(with: no) { return false }     // "nicht gut" is a no
        if !words.isDisjoint(with: yes) { return true }
        return nil
    }
}
