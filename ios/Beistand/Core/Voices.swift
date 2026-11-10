import AVFoundation

/// Which voice the app speaks with. iOS has three qualities: Standard (small, robotic), Enhanced and
/// Premium (natural; free, but downloaded once in Settings → Accessibility → Spoken Content → Voices).
/// We pick the best installed calm voice, and people can choose their own per language.
enum Voices {
    /// Calm, clear voices people recommend, best first. Used to rank voices of the same quality.
    static let calmNames: [String: [String]] = [
        "en": ["Ava", "Zoe", "Evan", "Serena", "Jamie", "Matilda", "Samantha", "Allison", "Nathan", "Tom"],
        "de": ["Anna", "Petra", "Helena", "Markus", "Yannick", "Viktor", "Martin"],
    ]

    /// Joke and old formant voices: never offered (Bad News, Bubbles, Zarvox, the Eloquence voices …).
    static func isNovelty(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        return id.contains("speech.synthesis.voice") || id.contains("eloquence")
    }

    static func rank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q { case .premium: 3; case .enhanced: 2; default: 1 }
    }

    /// Voices for a language ("en", "de"), best first: personal voice, then quality, then calm names.
    static func list(for lang: String) -> [AVSpeechSynthesisVoice] {
        let calm = calmNames[lang] ?? []
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) && !isNovelty($0.identifier) }
            .sorted { a, b in
                let pa = personal(a), pb = personal(b)
                if pa != pb { return pa }
                if rank(a.quality) != rank(b.quality) { return rank(a.quality) > rank(b.quality) }
                let ia = calm.firstIndex(of: a.name) ?? 99, ib = calm.firstIndex(of: b.name) ?? 99
                if ia != ib { return ia < ib }
                return a.name < b.name
            }
    }

    static func personal(_ v: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 17, *) { return v.voiceTraits.contains(.isPersonalVoice) }
        return false
    }

    /// The voice to speak `language` (BCP-47) with: the person's choice, else the best installed
    /// one for the region (de-DE before de-AT), else any for the language.
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let lang = String(language.prefix(2))
        if let id = AppStore.shared.voiceID(for: lang), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let all = list(for: lang).filter { !personal($0) }                 // personal voice only when chosen
        guard let top = all.first.map({ rank($0.quality) }) else { return AVSpeechSynthesisVoice(language: language) }
        // The best quality there is; within it, the person's region (de-DE rather than de-AT) if it has one.
        let best = all.filter { rank($0.quality) == top }
        return best.first { $0.language == language } ?? best.first
    }

    static func qualityName(_ v: AVSpeechSynthesisVoice) -> String {
        if personal(v) { return tr("Your voice", "Ihre Stimme") }
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return tr("Enhanced", "Erweitert")
        default: return tr("Standard", "Standard")
        }
    }

    /// The preview sentence, in the voice's own language.
    static func sample(_ v: AVSpeechSynthesisVoice) -> String {
        v.language.hasPrefix("de")
            ? "Hallo, ich bin \(v.name). Ich begleite Sie ruhig und Schritt für Schritt."
            : "Hello, I'm \(v.name). I'll guide you calmly, one step at a time."
    }
}

/// How fast the app speaks. Calm is the default: a little slower and lower than iOS.
enum SpeechPace: Int, CaseIterable, Identifiable {
    case calm = 0, normal = 1, quick = 2
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .calm: tr("Calm", "Ruhig")
        case .normal: tr("Normal", "Normal")
        case .quick: tr("Quick", "Zügig")
        }
    }
    var rate: Float {
        switch self {
        case .calm: AVSpeechUtteranceDefaultSpeechRate * 0.86
        case .normal: AVSpeechUtteranceDefaultSpeechRate * 0.96
        case .quick: AVSpeechUtteranceDefaultSpeechRate * 1.08
        }
    }
    var pitch: Float { self == .calm ? 0.96 : 1.0 }
}
