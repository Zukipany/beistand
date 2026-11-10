import Foundation

/// Colour names for people with low vision (clothes, pills, a bus): plain words, light/dark when it
/// matters. Pure, testable.
enum ColorName {
    static func name(r: Double, g: Double, b: Double) -> String {
        let (h, s, l) = hsl(r, g, b)
        let base: (en: String, de: String)
        if s < 0.12 || l < 0.08 || l > 0.94 {
            if l < 0.14 { return tr("black", "schwarz") }
            if l > 0.88 { return tr("white", "weiß") }
            base = ("grey", "grau")
        } else {
            switch h {
            case ..<15, 345...: base = ("red", "rot")
            case 15..<40: base = l < 0.42 && s < 0.75 ? ("brown", "braun") : ("orange", "orange")
            case 40..<68: base = l < 0.38 ? ("olive", "oliv") : ("yellow", "gelb")
            case 68..<165: base = ("green", "grün")
            case 165..<195: base = ("turquoise", "türkis")
            case 195..<255: base = ("blue", "blau")
            case 255..<290: base = ("purple", "lila")
            default: base = l > 0.6 ? ("pink", "rosa") : ("magenta", "magenta")
            }
        }
        // Brown and olive are dark already, pink is light already: no "dark brown" or "light pink".
        let plain = ["brown", "olive", "pink"].contains(base.en)
        if l < 0.3, !plain || l < 0.15 { return tr("dark \(base.en)", "dunkel\(base.de)") }
        if l > 0.75, !plain { return tr("light \(base.en)", "hell\(base.de)") }
        return tr(base.en, base.de)
    }

    /// r, g, b in 0…1 → hue in degrees, saturation and lightness in 0…1.
    static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
    }
}

/// "Is this my train?": text the camera reads on an arriving train (front display) against the
/// line and direction of the ride. Pure, testable.
enum TrainCheck {
    enum Verdict: Equatable { case yours, otherLine(String) }

    static func verdict(_ texts: [String], line: String, direction: String) -> Verdict? {
        let all = texts.joined(separator: " ")
        let lineNorm = norm(line)                                // "U3" → "u3"
        let found = lines(in: all)
        if found.contains(lineNorm) { return .yours }
        // Direction alone (the line number is often on the side, not the front).
        if !direction.isEmpty, norm(all).contains(norm(direction)), found.isEmpty { return .yours }
        if let other = found.first { return .otherLine(other.uppercased()) }
        return nil
    }

    /// Line labels like "U3", "U 6", "S8", "Tram 19", "19" next to "Tram" … normalised to "u3", "s8", "19".
    static func lines(in text: String) -> [String] {
        let t = text.lowercased()
        let pattern = #"\b([us])\s?(\d{1,2})\b|\btram\s?(\d{1,2})\b|\bbus\s?(\d{2,3})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { m in
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: t).map { String(t[$0]) } }
            if let k = g(1), let n = g(2) { return k + n }
            return g(3) ?? g(4)
        }
    }

    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ß", with: "ss").folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    static func phrase(_ v: Verdict, line: String, direction: String) -> String {
        switch v {
        case .yours: tr("This is your train: \(line) to \(direction). You can get on.",
                        "Das ist Ihr Zug: \(line) nach \(direction). Sie können einsteigen.")
        case .otherLine(let other): tr("Not your train: this is the \(other). Wait for the \(line).",
                                       "Nicht Ihr Zug: das ist die \(other). Warten Sie auf die \(line).")
        }
    }
}

/// A medicine with its times of day.
struct Medicine: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var times: [DateComponents]          // hour and minute
    var note: String = ""                 // "with food"
}

/// When the next dose is, whether one is due, and whether it was taken. Pure, testable.
enum MedicineSchedule {
    /// Doses of all medicines on the day of `now`, in order.
    static func doses(_ meds: [Medicine], on now: Date, calendar: Calendar = .current) -> [(Medicine, Date)] {
        meds.flatMap { m in
            m.times.compactMap { t in calendar.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: now).map { (m, $0) } }
        }
        .sorted { $0.1 < $1.1 }
    }

    /// The dose to show: a missed one from the last 3 hours that is not taken yet, else the next one today.
    static func current(_ meds: [Medicine], taken: Set<String>, now: Date, calendar: Calendar = .current) -> (Medicine, Date, due: Bool)? {
        let today = doses(meds, on: now, calendar: calendar)
        if let missed = today.last(where: { $0.1 <= now && now.timeIntervalSince($0.1) < 3 * 3600 && !taken.contains(key($0.0, $0.1)) }) {
            return (missed.0, missed.1, true)
        }
        return today.first(where: { $0.1 > now }).map { ($0.0, $0.1, false) }
    }

    static func key(_ m: Medicine, _ d: Date) -> String { "\(m.id.uuidString)@\(Int(d.timeIntervalSince1970 / 60))" }
}

/// The daily "How are you?": asked once a day in the morning (from 7:00) until answered. Pure, testable.
enum CheckIn {
    static func shouldAsk(now: Date, lastAnswered: Date?, startHour: Int = 7, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.hour, from: now) >= startHour else { return false }
        guard let last = lastAnswered else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }
}

/// "Today is Monday, 10 November. It is afternoon." for people with memory problems. Pure, testable.
enum DayAnchor {
    static func partOfDay(_ hour: Int) -> String {
        switch hour {
        case 5..<12: tr("morning", "Morgen")
        case 12..<14: tr("midday", "Mittag")
        case 14..<18: tr("afternoon", "Nachmittag")
        case 18..<22: tr("evening", "Abend")
        default: tr("night", "Nacht")
        }
    }

    static func sentence(now: Date, place: String?, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let day = f.string(from: now)
        let part = partOfDay(calendar.component(.hour, from: now))
        var s = tr("Today is \(day). It is \(part).", "Heute ist \(day). Es ist \(part).")
        if let place { s += " " + place }
        return s
    }
}
