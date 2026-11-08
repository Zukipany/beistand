import AVFoundation
import Speech

/// A recognised word with when it was said (seconds from the start of the audio), if known.
struct HeardWord: Equatable {
    var text: String
    var start: Double?
    var end: Double?
}

/// Apple's newer on-device speech recognizer (SpeechAnalyzer + SpeechTranscriber, iOS 26+):
/// better accuracy, long-form audio without the 1-minute limit, punctuation, and exact time per word.
/// The language model downloads once and is then fully offline.
@available(iOS 26, *)
final class ModernSpeech {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private var results: Task<Void, Never>?

    /// The supported locale closest to the one asked for, or nil.
    static func supported(_ locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    static func installed(_ locale: Locale) async -> Bool {
        guard let l = await supported(locale) else { return false }
        let t = SpeechTranscriber(locale: l, preset: .transcription)
        return await AssetInventory.status(forModules: [t]) == .installed
    }

    /// `onResult(words, isFinal)` is called on the main queue. Volatile results replace the previous
    /// volatile ones; final results are settled text.
    func start(locale: Locale, inputFormat: AVAudioFormat,
               onResult: @escaping ([HeardWord], Bool) -> Void) async throws {
        guard let l = await Self.supported(locale) else { throw CocoaError(.featureUnsupported) }
        let transcriber = SpeechTranscriber(locale: l, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()      // one time, then offline
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? inputFormat
        outFormat = format
        converter = format == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        results = Task {
            do {
                for try await r in transcriber.results {
                    let words = Self.words(in: r.text)
                    let final = r.isFinal
                    await MainActor.run { onResult(words, final) }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Called from the audio tap (any thread).
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let input else { return }
        guard let converter, let outFormat else { input.yield(AnalyzerInput(buffer: buffer)); return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() {
        input?.finish()
        input = nil
        let a = analyzer
        analyzer = nil
        Task { try? await a?.finalizeAndFinishThroughEndOfInput() }
        results?.cancel()
    }

    /// Splits a result into words, each with the audio time of the run it came from.
    static func words(in text: AttributedString) -> [HeardWord] {
        var out: [HeardWord] = []
        for (range, r) in text.runs[\.audioTimeRange] {
            let piece = String(text[r].characters)
            let start = range.map { $0.start.seconds }, end = range.map { $0.end.seconds }
            for w in piece.split(whereSeparator: \.isWhitespace) {
                out.append(HeardWord(text: String(w), start: start, end: end))
            }
        }
        return out
    }
}
