import Foundation
import Observation

enum Mode: String, Codable, CaseIterable, Identifiable {
    case older, dementia, sight, lowVision = "low_vision", hearing, wheelchair, speech, calm
    case easyReading = "easy_reading", seizure, tremor, lowEnergy = "low_energy", deafblind
    var id: String { rawValue }

    var label: String {
        switch self {
        case .older: tr("Simple home screen", "Einfache Startseite")
        case .dementia: tr("Memory", "Gedächtnis")
        case .sight: tr("Sight", "Sehen")
        case .lowVision: tr("Low vision", "Sehschwäche")
        case .hearing: tr("Hearing", "Hören")
        case .wheelchair: tr("Wheelchair", "Rollstuhl")
        case .speech: tr("Speaking", "Sprechen")
        case .calm: tr("Calm", "Ruhe")
        case .easyReading: tr("Easy reading", "Einfach lesen")
        case .seizure: tr("Seizures", "Anfälle")
        case .tremor: tr("Tremor / one hand", "Zittern / eine Hand")
        case .lowEnergy: tr("Low energy", "Wenig Kraft")
        case .deafblind: tr("Deafblind", "Taubblind")
        }
    }
}

struct EmergencyContact: Codable, Hashable {
    var name: String
    var phone: String  // E.164
}

struct Profile: Codable {
    var userId: String
    var name: String
    var language: String = "en"
    var modes: Set<Mode>
    var contacts: [EmergencyContact]
}

/// Holds the person's profile on the device. Synced to the backend on save.
@Observable
final class AppStore {
    static let shared = AppStore()

    var profile: Profile? { didSet { persist() } }
    var backendURL: URL {
        didSet { UserDefaults.standard.set(backendURL.absoluteString, forKey: "backendURL") }
    }
    /// Without a paired watch the phone alone cannot tell a fall from a drop.
    /// For the demo, this makes a phone-only impact count as a fall.
    var demoPhoneImpactIsFall: Bool {
        didSet { UserDefaults.standard.set(demoPhoneImpactIsFall, forKey: "demoFall") }
    }
    /// Parking-sensor beeps and object warnings while the camera guide runs (LiDAR phones).
    var obstacleWarnings: Bool {
        didSet { UserDefaults.standard.set(obstacleWarnings, forKey: "obstacleWarnings") }
    }

    private init() {
        let d = UserDefaults.standard
        let url = d.string(forKey: "backendURL") ?? "http://localhost:8000"
        // A launch argument (`-backendURL http://…`) is remembered, so a phone keeps finding the Mac.
        d.set(url, forKey: "backendURL")
        backendURL = URL(string: url)!
        demoPhoneImpactIsFall = d.bool(forKey: "demoFall")
        obstacleWarnings = d.object(forKey: "obstacleWarnings") as? Bool ?? true
        if let data = d.data(forKey: "profile") {
            profile = try? JSONDecoder().decode(Profile.self, from: data)
        }
    }

    func has(_ m: Mode) -> Bool { profile?.modes.contains(m) ?? false }

    func setMode(_ m: Mode, _ on: Bool) {
        guard var p = profile else { return }
        if on { p.modes.insert(m) } else { p.modes.remove(m) }
        profile = p
    }

    func setModes(_ modes: Set<Mode>) {
        guard var p = profile else { return }
        p.modes = modes
        profile = p
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(profile), forKey: "profile")
        guard let p = profile else { return }
        Task { try? await API.shared.putProfile(p) }
    }
}

/// One-tap sets of modes for testing and demos ("try the app as a deaf person").
struct TestProfile: Identifiable {
    let id: String
    let name: String
    let icon: String
    let modes: Set<Mode>

    static var all: [TestProfile] {[
        TestProfile(id: "older", name: tr("Older person", "Ältere Person"), icon: "figure.and.child.holdinghands", modes: [.older]),
        TestProfile(id: "blind", name: tr("Blind", "Blind"), icon: "figure.walk.motion", modes: [.sight, .older]),
        TestProfile(id: "lowvision", name: tr("Low vision", "Sehschwäche"), icon: "eyeglasses", modes: [.lowVision, .older]),
        TestProfile(id: "deaf", name: tr("Deaf or hard of hearing", "Gehörlos oder schwerhörig"), icon: "ear.trianglebadge.exclamationmark", modes: [.hearing, .older]),
        TestProfile(id: "dementia", name: tr("Memory problems", "Gedächtnisprobleme"), icon: "brain.head.profile", modes: [.dementia, .older]),
        TestProfile(id: "wheelchair", name: tr("Wheelchair", "Rollstuhl"), icon: "figure.roll", modes: [.wheelchair, .older]),
        TestProfile(id: "seizure", name: tr("Seizures", "Anfälle"), icon: "bolt.heart", modes: [.seizure, .older]),
        TestProfile(id: "deafblind", name: tr("Deafblind", "Taubblind"), icon: "hand.raised", modes: [.deafblind, .sight, .older]),
    ]}
}
