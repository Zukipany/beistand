import Foundation

/// What the person is doing, which decides what the guide talks about.
/// Navigate (default, and always while a destination is set): the way, the goal, obstacles in the path.
/// Explore: also the shops, cafés and places around. Everything: every recognised thing (for testing).
enum GuideDetail: Int, CaseIterable, Identifiable {
    case calm = 0           // navigate
    case places = 1         // explore
    case everything = 2

    var id: Int { rawValue }
    var name: String {
        switch self {
        case .calm: tr("Navigate: only the way", "Navigieren: nur der Weg")
        case .places: tr("Explore: places around me", "Erkunden: Orte um mich herum")
        case .everything: tr("Dev: everything it sees", "Dev: alles, was es sieht")
        }
    }
    var short: String {
        switch self {
        case .calm: tr("Navigate", "Navigieren")
        case .places: tr("Explore", "Erkunden")
        case .everything: "Dev"
        }
    }
    var icon: String {
        switch self { case .calm: "location.north.line.fill"; case .places: "sparkle.magnifyingglass"; case .everything: "eye.fill" }
    }
}

/// "What are you looking for?": what people ask for while walking, matched to map places.
enum PlaceSearch {
    struct Category: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: String
        let words: [String]          // spoken words that mean this (English and German)
        let kinds: [String]          // landmark kinds that match (as the backend labels them)
    }

    static var categories: [Category] {[
        Category(id: "station", name: tr("Station", "Bahnhof"), icon: "tram.fill.tunnel",
                 words: ["station", "u-bahn", "s-bahn", "subway", "metro", "train", "tram", "bus", "bahnhof", "haltestelle", "zug"],
                 kinds: ["u-bahn", "station", "bahnhof", "stop", "halte", "tram"]),
        Category(id: "icecream", name: tr("Ice cream", "Eis"), icon: "birthday.cake.fill",
                 words: ["ice cream", "icecream", "gelato", "eis", "eisdiele"], kinds: ["ice cream", "eisdiele"]),
        Category(id: "cafe", name: tr("Café", "Café"), icon: "cup.and.saucer.fill",
                 words: ["coffee", "café", "cafe", "kaffee"], kinds: ["café", "cafe"]),
        Category(id: "food", name: tr("Food", "Essen"), icon: "fork.knife",
                 words: ["food", "eat", "restaurant", "lunch", "dinner", "essen", "imbiss", "hunger"],
                 kinds: ["restaurant", "fast food", "imbiss", "bakery", "bäckerei"]),
        Category(id: "toilet", name: tr("Toilet", "Toilette"), icon: "toilet.fill",
                 words: ["toilet", "wc", "restroom", "bathroom", "toilette", "klo"], kinds: ["toilets", "toilette"]),
        Category(id: "pharmacy", name: tr("Pharmacy", "Apotheke"), icon: "cross.case.fill",
                 words: ["pharmacy", "chemist", "medicine", "apotheke"], kinds: ["pharmacy", "apotheke"]),
        Category(id: "supermarket", name: tr("Supermarket", "Supermarkt"), icon: "cart.fill",
                 words: ["supermarket", "groceries", "supermarkt", "lebensmittel"], kinds: ["supermarket", "supermarkt"]),
        Category(id: "bank", name: tr("Cash", "Geld"), icon: "banknote.fill",
                 words: ["bank", "cash", "atm", "money", "geld", "geldautomat"], kinds: ["bank"]),
    ]}

    static func category(for words: String) -> Category? {
        let w = words.lowercased()
        return categories.first { c in c.words.contains { w.contains($0) } }
    }

    /// The nearest place that matches what was said: a category ("ice cream") or a name ("Rossmann").
    static func find(_ words: String, in landmarks: [Landmark], here: Coord) -> Landmark? {
        let w = words.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard w.count >= 2 else { return nil }
        let places = landmarks.filter { !$0.isStreet }.sorted { Geo.distance(here, $0.coord) < Geo.distance(here, $1.coord) }
        if let c = category(for: w) {
            if c.id == "station" { return Orientation.nearestEntrance(landmarks, here: here, within: 1000) }
            return places.first { l in c.kinds.contains { l.kind.lowercased().contains($0) } }
        }
        return places.first { $0.name.lowercased().contains(w) || w.contains($0.name.lowercased()) }
    }
}

extension ObjectAlerts {
    /// Calm warnings: only things in the walking path, close enough to matter; people only when
    /// about to bump into them. Benches or shop signs at the side are never spoken.
    static var calm: ObjectAlerts {
        var a = ObjectAlerts()
        a.announceWithin = 2.0
        a.peopleWithin = 1.0
        a.repeatAfter = 15
        a.minGap = 4
        a.onlyAhead = true
        return a
    }
}

extension Orientation {
    /// Public transport: what people most often need to find.
    static func isTransit(_ kind: String) -> Bool {
        let k = kind.lowercased()
        return ["u-bahn", "s-bahn", "station", "bahnhof", "stop", "halte", "tram"].contains { k.contains($0) }
    }

    /// One short sentence: which way you face, the street, and at most one useful place in view
    /// (transport first, then the nearest). Used while looking around in calm mode.
    static func shortSentence(heading: Double, here: Coord, landmarks: [Landmark], places: Int = 1, transportOnly: Bool = false) -> String {
        var s = tr("Facing \(compass(heading))", "Blick nach \(compass(heading))")
        if let street = around(landmarks, here: here, heading: heading, within: 30).first(where: { $0.landmark.isStreet }) {
            s += tr(", on \(street.landmark.name)", ", \(street.landmark.name)")
        }
        s += "."
        let seen = inView(landmarks, here: here, heading: heading).filter { !transportOnly || isTransit($0.landmark.kind) }
        // Transport first, then the nearest.
        let ordered = seen.filter { isTransit($0.landmark.kind) } + seen.filter { !isTransit($0.landmark.kind) }
        for pick in ordered.prefix(places) {
            let what = pick.landmark.name == pick.landmark.kind ? pick.landmark.name : "\(pick.landmark.name), \(pick.landmark.kind)"
            s += " " + tr("\(words(pick.relative).capitalizedFirst): \(what), \(Int(pick.distance.rounded())) metres.",
                          "\(words(pick.relative).capitalizedFirst): \(what), \(Int(pick.distance.rounded())) Meter.")
        }
        return s
    }

    /// The nearest way into public transport: a U-Bahn/S-Bahn entrance, else a station or stop.
    static func nearestEntrance(_ landmarks: [Landmark], here: Coord, within: Double = 400) -> Landmark? {
        let near = landmarks.filter { !$0.isStreet && isTransit($0.kind) && Geo.distance(here, $0.coord) <= within }
            .sorted { Geo.distance(here, $0.coord) < Geo.distance(here, $1.coord) }
        let entrance = near.first { $0.kind.lowercased().contains("entrance") || $0.kind.lowercased().contains("eingang") }
        return entrance ?? near.first
    }
}

/// Close to the goal (an entrance, a door): short direction updates, only when something changed.
/// "U-Bahn entrance, 15 metres, slightly left." Pure, testable.
struct HomingPolicy {
    var within = 60.0            // start helping this close to the goal
    var everyMetres = 10.0       // say it again after getting this much closer
    var minGap: TimeInterval = 6
    private var lastWords: String?
    private var lastDistance: Double?
    private var lastAt: TimeInterval = -.infinity

    mutating func feed(here: Coord, heading: Double?, goal: Coord, name: String, at t: TimeInterval) -> String? {
        let d = Geo.distance(here, goal)
        guard d <= within, d > 5, t - lastAt >= minGap else { return nil }
        let words = heading.map { Orientation.words(Orientation.relative(Geo.bearing(here, goal), heading: $0)) }
        let turned = words != nil && words != lastWords
        let closer = (lastDistance ?? .infinity) - d >= everyMetres
        guard turned || closer else { return nil }
        lastWords = words; lastDistance = d; lastAt = t
        let m = Int(d.rounded())
        if let words {
            return tr("\(name), \(m) metres, \(words).", "\(name), \(m) Meter, \(words).")
        }
        return tr("\(name), \(m) metres.", "\(name), \(m) Meter.")
    }

    mutating func reset() { lastWords = nil; lastDistance = nil; lastAt = -.infinity }
}
