import Foundation

/// Important sounds for deaf and hard-of-hearing people, recognised on the phone by Apple's
/// built-in sound classifier (offline, nothing recorded or sent anywhere).
enum SoundKind: String, CaseIterable, Codable {
    case siren, alarm, horn, doorbell, knock, baby, dog, shout

    /// Lower threshold for sounds where a miss is worse than a false alarm.
    var threshold: Double {
        switch self {
        case .siren, .alarm: 0.5
        case .horn, .baby: 0.6
        default: 0.7
        }
    }

    var urgent: Bool { self == .siren || self == .alarm || self == .horn }

    var name: String {
        switch self {
        case .siren: tr("Siren", "Sirene")
        case .alarm: tr("Fire or smoke alarm", "Feuer- oder Rauchmelder")
        case .horn: tr("Car horn", "Hupe")
        case .doorbell: tr("Doorbell", "Türklingel")
        case .knock: tr("Knocking", "Klopfen")
        case .baby: tr("Baby crying", "Baby weint")
        case .dog: tr("Dog barking", "Hund bellt")
        case .shout: tr("Someone shouting", "Jemand ruft")
        }
    }

    var icon: String {
        switch self {
        case .siren: "light.beacon.max.fill"
        case .alarm: "flame.fill"
        case .horn: "car.fill"
        case .doorbell: "bell.fill"
        case .knock: "door.left.hand.closed"
        case .baby: "figure.and.child.holdinghands"
        case .dog: "dog.fill"
        case .shout: "megaphone.fill"
        }
    }

    /// Maps the classifier's label (e.g. "police_siren", "smoke_detector") to our short list.
    static func from(identifier: String) -> SoundKind? {
        let s = identifier.lowercased()
        let table: [(SoundKind, [String])] = [
            (.alarm, ["smoke", "fire_alarm", "alarm_clock_no", "fire alarm"]),
            (.siren, ["siren", "emergency_vehicle", "civil_defense"]),
            (.horn, ["car_horn", "vehicle_horn", "horn", "train_horn", "air_horn"]),
            (.doorbell, ["doorbell", "door_bell", "ding_dong"]),
            (.knock, ["knock"]),
            (.baby, ["baby_crying", "crying_baby", "infant_cry"]),
            (.dog, ["dog_bark", "bark", "dog_bow_wow", "dog"]),
            (.shout, ["shout", "yell", "scream"]),
        ]
        return table.first { _, keys in keys.contains { s.contains($0) } }?.0
    }
}

/// Decides when a recognised sound becomes an alert: confident enough, and not again within a few
/// seconds (a siren lasts a while; one alert is enough). Pure, testable.
struct SoundAlertPolicy {
    var repeatAfter: TimeInterval = 8
    private var last: [SoundKind: TimeInterval] = [:]

    /// `labels`: classifier identifiers with confidence. Returns the alert to show, if any.
    mutating func feed(_ labels: [(String, Double)], at t: TimeInterval) -> SoundKind? {
        let hits = labels.compactMap { id, conf -> (SoundKind, Double)? in
            guard let k = SoundKind.from(identifier: id), conf >= k.threshold else { return nil }
            return (k, conf)
        }
        // Urgent sounds first, then the most confident.
        guard let best = hits.sorted(by: { ($0.0.urgent ? 1 : 0, $0.1) > ($1.0.urgent ? 1 : 0, $1.1) }).first?.0,
              t - (last[best] ?? -.infinity) >= repeatAfter else { return nil }
        last[best] = t
        return best
    }
}
