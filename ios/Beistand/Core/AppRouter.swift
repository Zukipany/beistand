import Foundation
import Observation

/// Every place the app can take the person. Voice commands and the step-by-step story both go
/// through here, so they open exactly the same screens as the buttons.
enum Destination: Equatable {
    case guide, map, captions, sounds, counter, read, magnifier, scam, settings, story
    case ride(to: String?)          // "take the U-Bahn to Odeonsplatz"
    case find(String)               // "find ice cream"
    case whereAmI, departures, callFamily, help
    case back                       // close what is open
}

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    private(set) var request: Destination?
    private(set) var requestID = 0
    func open(_ d: Destination) { request = d; requestID += 1 }
}

/// Understands what the person says, in English and German. Pure, testable.
enum CommandParser {
    static func parse(_ said: String) -> Destination? {
        let s = " " + said.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "'-")).inverted).joined()
            + " "
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }

        // Safety first ("is this a scam call?" is about a scam, not a call).
        if has([" help ", " hilfe", " notfall", " emergency", " sos "]) { return .help }
        if has([" scam", " betrug", " fraud"]) { return .scam }
        if has([" call ", " anrufen", " ruf ", " telefonier"]) { return .callFamily }
        if has([" back ", " close ", " stop ", " cancel ", " zurück", " schließen", " schliessen", " beenden", " abbrechen"]) { return .back }

        // Trains, with the station if one was said ("to Odeonsplatz", "nach Odeonsplatz").
        if has([" u-bahn", " ubahn", " u bahn", " s-bahn", " subway", " metro", " underground", " tram"]) || has([" train ", " zug ", " bahn "]) {
            if has([" departure", " abfahrt", " next train", " nächste bahn", " naechste bahn", " when does", " wann fährt", " wann faehrt"]) {
                return .departures
            }
            return .ride(to: station(after: s))
        }
        if has([" departure", " abfahrt"]) { return .departures }

        if has([" where am i", " wo bin ich"]) { return .whereAmI }
        if has([" i'm lost", " im lost", " i am lost", " lost ", " verlaufen", " verirrt", " guide me", " begleit", " camera guide"]) { return .guide }

        // "find ice cream", "where is a toilet", "ich suche eine Apotheke".
        if let c = PlaceSearch.category(for: s), has([" find", " where is", " where's", " looking for", " need ", " want ", " such", " wo ist", " wo gibt", " brauche", " möchte"]) || s.split(separator: " ").count <= 3 {
            return .find(c.name)
        }
        if has([" find ", " suche "]), let rest = after(s, [" find ", " suche "]) { return .find(rest) }

        if has([" caption", " untertitel", " what are they saying", " was sagen"]) { return .captions }
        if has([" sound", " geräusch", " geraeusch", " alarm"]) { return .sounds }
        if has([" counter", " schalter", " desk "]) { return .counter }
        if has([" magnif", " lupe", " bigger", " größer", " zoom"]) { return .magnifier }
        if has([" scam", " betrug", " fraud", " fake"]) { return .scam }
        if has([" read", " vorlesen", " lesen", " letter", " brief "]) { return .read }
        if has([" map", " karte", " destination", " ziel"]) { return .map }
        if has([" step by step", " schritt für schritt", " schritt fuer schritt"]) { return .story }
        if has([" setting", " einstellung"]) { return .settings }
        return nil
    }

    /// "… to Odeonsplatz" / "… nach Odeonsplatz" → "Odeonsplatz".
    static func station(after s: String) -> String? {
        after(s, [" to ", " nach ", " zum ", " zur "])
    }

    private static func after(_ s: String, _ markers: [String]) -> String? {
        for m in markers {
            if let r = s.range(of: m, options: .backwards) {
                let rest = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if rest.count >= 3 { return rest.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
            }
        }
        return nil
    }

    /// What the app says before opening it, so the person knows it understood.
    static func confirmation(_ d: Destination) -> String {
        switch d {
        case .guide: tr("Opening the camera guide.", "Ich öffne die Kamera-Begleitung.")
        case .map: tr("Opening the map.", "Ich öffne die Karte.")
        case .captions: tr("Live captions.", "Live-Untertitel.")
        case .sounds: tr("Sound alerts.", "Geräusch-Alarme.")
        case .counter: tr("Counter mode.", "Schalter-Modus.")
        case .read: tr("Hold the letter under the camera.", "Halten Sie den Brief unter die Kamera.")
        case .magnifier: tr("Magnifier.", "Lupe.")
        case .scam: tr("Scam check.", "Betrugs-Prüfung.")
        case .settings: tr("Settings.", "Einstellungen.")
        case .story: tr("Step by step.", "Schritt für Schritt.")
        case .ride(let to): to.map { tr("U-Bahn to \($0).", "U-Bahn nach \($0).") } ?? tr("On the U-Bahn. Where do you get off?", "In der U-Bahn. Wo steigen Sie aus?")
        case .find(let what): tr("Looking for \(what).", "Ich suche \(what).")
        case .whereAmI: tr("One moment.", "Einen Moment.")
        case .departures: tr("Next departures.", "Nächste Abfahrten.")
        case .callFamily: tr("Calling.", "Ich rufe an.")
        case .help: tr("Getting help.", "Ich hole Hilfe.")
        case .back: tr("Closed.", "Geschlossen.")
        }
    }

    static var examples: String {
        tr("You can say: I'm lost. Where am I? Read this. Find ice cream. U-Bahn to Odeonsplatz. Captions. Call family. Help.",
           "Sie können sagen: Ich habe mich verlaufen. Wo bin ich? Vorlesen. Eis finden. U-Bahn nach Odeonsplatz. Untertitel. Familie anrufen. Hilfe.")
    }
}
