import UIKit

/// Reads the iPhone's own accessibility settings, so a person who already set up
/// VoiceOver, large text or captions does not have to answer those questions again.
enum SystemAccessibility {
    struct Hint: Equatable {
        let mode: Mode
        let reason: String   // spoken, e.g. "VoiceOver ist an"
    }

    struct Flags {
        var voiceOver = false
        var largeText = false
        var boldText = false
        var invertColors = false
        var darkerColors = false
        var captions = false
        var monoAudio = false
        var switchControl = false
        var assistiveTouch = false
    }

    @MainActor static func current() -> Flags {
        Flags(voiceOver: UIAccessibility.isVoiceOverRunning,
              largeText: UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory,
              boldText: UIAccessibility.isBoldTextEnabled,
              invertColors: UIAccessibility.isInvertColorsEnabled,
              darkerColors: UIAccessibility.isDarkerSystemColorsEnabled,
              captions: UIAccessibility.isClosedCaptioningEnabled,
              monoAudio: UIAccessibility.isMonoAudioEnabled,
              switchControl: UIAccessibility.isSwitchControlRunning,
              assistiveTouch: UIAccessibility.isAssistiveTouchRunning)
    }

    /// Pure mapping, so it is testable. Only clear signals count: bold text alone
    /// is a taste, not a need, so it only adds weight to large text.
    static func hints(_ f: Flags) -> [Hint] {
        var out: [Hint] = []
        if f.voiceOver {
            out.append(Hint(mode: .sight, reason: tr("VoiceOver is on", "VoiceOver ist an")))
        } else if f.largeText || f.invertColors || (f.darkerColors && f.boldText) {
            out.append(Hint(mode: .lowVision, reason: f.largeText ? tr("Very large text is on", "Sehr große Schrift ist an")
                                                      : tr("Colours are set for low vision", "Die Farben sind für schwaches Sehen eingestellt")))
        }
        if f.captions || f.monoAudio {
            out.append(Hint(mode: .hearing, reason: f.captions ? tr("Captions are on", "Untertitel sind an") : tr("Mono audio is on", "Mono-Audio ist an")))
        }
        if f.switchControl || f.assistiveTouch {
            out.append(Hint(mode: .tremor, reason: f.switchControl ? tr("Switch Control is on", "Schaltersteuerung ist an") : tr("AssistiveTouch is on", "AssistiveTouch ist an")))
        }
        return out
    }

    @MainActor static func hints() -> [Hint] { hints(current()) }

    /// For people already set up: a setting switched on later (e.g. VoiceOver after losing sight)
    /// adds its mode once. Turning a setting off never removes a mode; the family can do that.
    @MainActor static func applyNewSettings(to store: AppStore) {
        guard var p = store.profile else { return }
        let seen = Set(UserDefaults.standard.stringArray(forKey: "a11ySeen") ?? [])
        let fresh = hints().filter { !seen.contains($0.mode.rawValue) && !p.modes.contains($0.mode) }
        UserDefaults.standard.set(Array(seen.union(hints().map(\.mode.rawValue))), forKey: "a11ySeen")
        guard !fresh.isEmpty else { return }
        p.modes.formUnion(fresh.map(\.mode))
        store.profile = p
        Speaker.shared.say(fresh.map { tr("\($0.reason). I switched on \($0.mode.label).", "\($0.reason). Ich habe \($0.mode.label) eingeschaltet.") }.joined(separator: " "))
    }
}
