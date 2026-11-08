import Foundation

/// Everything phone and watch say to each other, as plist dictionaries for WatchConnectivity.
/// Compiled into both apps so both sides always agree on the format.
enum WatchMessage: Equatable {
    // watch → phone
    case help                       // person held the help button on the wrist
    case imOK                       // "Mir geht es gut" on the wrist
    case wristImpact(at: Date)      // hard hit on the wrist; the phone decides with its own data
    case wristFall(at: Date)        // hard hit + arm lying still for 10 s

    // phone → watch (transient; the current state travels as WatchState)
    case cue(GuideCue)

    var dict: [String: Any] {
        switch self {
        case .help: ["k": "help"]
        case .imOK: ["k": "ok"]
        case .wristImpact(let at): ["k": "impact", "t": at.timeIntervalSince1970]
        case .wristFall(let at): ["k": "fall", "t": at.timeIntervalSince1970]
        case .cue(let c): ["k": "cue", "c": c.rawValue]
        }
    }

    init?(_ d: [String: Any]) {
        let t = (d["t"] as? Double).map(Date.init(timeIntervalSince1970:))
        switch d["k"] as? String {
        case "help": self = .help
        case "ok": self = .imOK
        case "impact": guard let t else { return nil }; self = .wristImpact(at: t)
        case "fall": guard let t else { return nil }; self = .wristFall(at: t)
        case "cue": guard let c = (d["c"] as? String).flatMap(GuideCue.init) else { return nil }; self = .cue(c)
        default: return nil
        }
    }
}

/// The haptic vocabulary on the wrist. Same pattern as on the phone.
enum GuideCue: String, CaseIterable {
    case left       // 2 taps
    case right      // 3 taps
    case arrived    // one long "success"
    case offRoute   // "retry" buzz
    case askingOK   // repeated until answered
    case helpComing // "success"

    static func from(direction text: String) -> GuideCue? {
        let t = text.lowercased()
        if t.contains("links") || t.contains("left") { return .left }
        if t.contains("rechts") || t.contains("right") { return .right }
        return nil
    }
}

/// Latest state the watch should show. Sent as application context, so the watch
/// gets it even if it was asleep when it changed.
struct WatchState: Equatable {
    var incident: String = "none"   // none | asking | contacting | contact_responding | emergency_confirmed | resolved
    var ackedBy: String?
    var contactName: String?
    var contactPhone: String?
    var personName: String?

    var dict: [String: Any] {
        var d: [String: Any] = ["incident": incident]
        if let ackedBy { d["ackedBy"] = ackedBy }
        if let contactName { d["contactName"] = contactName }
        if let contactPhone { d["contactPhone"] = contactPhone }
        if let personName { d["personName"] = personName }
        return d
    }

    init(incident: String = "none", ackedBy: String? = nil, contactName: String? = nil,
         contactPhone: String? = nil, personName: String? = nil) {
        self.incident = incident; self.ackedBy = ackedBy; self.contactName = contactName
        self.contactPhone = contactPhone; self.personName = personName
    }

    init(_ d: [String: Any]) {
        incident = d["incident"] as? String ?? "none"
        ackedBy = d["ackedBy"] as? String
        contactName = d["contactName"] as? String
        contactPhone = d["contactPhone"] as? String
        personName = d["personName"] as? String
    }
}
