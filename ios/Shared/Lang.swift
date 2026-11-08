import Foundation

/// The app speaks the phone's language: German if the phone is set to German, English otherwise.
/// Both texts sit side by side in the code, so a missing translation cannot happen.
enum Lang {
    /// Set by tests or a launch argument (`-lang de`) to force a language.
    static var override: String? = UserDefaults.standard.string(forKey: "lang")

    static var german: Bool {
        if let o = override { return o.hasPrefix("de") }
        return Locale.preferredLanguages.first?.hasPrefix("de") ?? false
    }
    static var code: String { german ? "de" : "en" }          // backend, Gemini
    static var speech: String { german ? "de-DE" : "en-US" }  // voices and speech recognition
    static var locale: Locale { Locale(identifier: german ? "de_DE" : "en_US") }
}

/// English first, German second.
func tr(_ en: String, _ de: String) -> String { Lang.german ? de : en }
