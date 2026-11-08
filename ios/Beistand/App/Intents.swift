import AppIntents

/// Expose the key actions to the Action Button, Back Tap, Siri and Shortcuts.
struct HelpIntent: AppIntent {
    static let title: LocalizedStringResource = "Call for help"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        SafetyService.shared.trigger(.help_button)
        return .result()
    }
}

/// "I'm lost": map this to the Action Button or Back Tap.
struct ImLostIntent: AppIntent {
    static let title: LocalizedStringResource = "I'm lost"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        GuideController.shared.requestedOpen = true
        return .result()
    }
}

struct WhereAmIIntent: AppIntent {
    static let title: LocalizedStringResource = "Where am I"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let loc = await LocationService.shared.current() else { return .result(dialog: "\(tr("I can't find your position.", "Ich finde Ihre Position nicht."))") }
        let text = await LocationService.shared.describe(loc)
        return .result(dialog: "\(text)")
    }
}

struct FindPhoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Find my phone"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        SafetyService.shared.startDropFinder()
        return .result()
    }
}

struct BeistandShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // English and German phrases side by side, so Siri understands either.
        AppShortcut(intent: ImLostIntent(), phrases: ["I'm lost with \(.applicationName)", "\(.applicationName) I'm lost",
                                                      "Ich habe mich verlaufen mit \(.applicationName)", "\(.applicationName) ich bin verloren"],
                    shortTitle: "I'm lost", systemImageName: "figure.walk.motion")
        AppShortcut(intent: HelpIntent(), phrases: ["Help with \(.applicationName)", "\(.applicationName) help",
                                                    "Hilfe mit \(.applicationName)", "\(.applicationName) Hilfe"],
                    shortTitle: "Help", systemImageName: "sos")
        AppShortcut(intent: WhereAmIIntent(), phrases: ["Where am I with \(.applicationName)", "Wo bin ich mit \(.applicationName)"],
                    shortTitle: "Where am I", systemImageName: "location.fill")
        AppShortcut(intent: FindPhoneIntent(), phrases: ["Find my phone with \(.applicationName)", "Finde mein Telefon mit \(.applicationName)"],
                    shortTitle: "Find phone", systemImageName: "iphone.radiowaves.left.and.right")
    }
}
