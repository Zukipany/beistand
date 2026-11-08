import Foundation
import Observation
import UIKit

/// Runs on top of every mode. Notices trouble and drives the backend help ladder.
@Observable
final class SafetyService {
    static let shared = SafetyService()

    enum Trigger: String { case fall, help_button, spoken_help, lost, no_sign_of_life, long_shaking }

    var incident: API.Incident? { didSet { WatchLink.shared.push(incident) } }
    var dropFinderActive = false
    var lastError: String?

    private let motion = MotionMonitor()
    private let finder = DropFinder()
    private var poll: Task<Void, Never>?
    private var dropTimer: Task<Void, Never>?
    private var monitoring = false
    /// When the phone last saw free fall + impact + stillness without a wrist hit to confirm it.
    private var unconfirmedPhoneImpact: Date?

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        motion.onFallPattern = { [weak self] in self?.impactWithStillness() }
        motion.onPickup = { [weak self] in self?.pickedUp() }
        motion.start()
        WatchLink.shared.activate()
        resumeOpenIncident()
    }

    /// The backend keeps the ladder running if the app dies; pick it up again on launch.
    private func resumeOpenIncident() {
        guard incident == nil, let id = UserDefaults.standard.string(forKey: "activeIncident") else { return }
        Task {
            guard let inc = try? await API.shared.incident(id), inc.state != "resolved" else {
                UserDefaults.standard.removeObject(forKey: "activeIncident"); return
            }
            incident = inc
            LocationService.shared.setTracking(true)
            announce()
            startPolling()
        }
    }

    // MARK: triggers

    func requestHelp() { trigger(.help_button) }

    /// Phone felt free fall + impact + stillness. Without a watch confirming the impact
    /// on the wrist this is most likely a dropped phone (plan: watch decides).
    private func impactWithStillness() {
        if AppStore.shared.demoPhoneImpactIsFall || WatchLink.shared.recentWristImpact {
            trigger(.fall)
        } else {
            unconfirmedPhoneImpact = Date()
            // Wait ~10 more seconds (≈20 s after the drop) for a pickup, then call out.
            dropTimer?.cancel()
            dropTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { self?.startDropFinder() }
            }
        }
    }

    /// The watch felt a hard hit. If the phone just saw a fall pattern on its own, this confirms it.
    func wristImpact() {
        guard incident == nil, let t = unconfirmedPhoneImpact, Date().timeIntervalSince(t) < 25 else { return }
        unconfirmedPhoneImpact = nil
        dropTimer?.cancel()
        if dropFinderActive { stopDropFinder() }
        trigger(.fall)
    }

    /// The watch saw a hit followed by a still arm. That alone is enough to ask.
    func wristFall() {
        guard incident == nil else { return }
        unconfirmedPhoneImpact = nil
        dropTimer?.cancel()
        trigger(.fall)
    }

    private func pickedUp() {
        unconfirmedPhoneImpact = nil
        dropTimer?.cancel()
        if dropFinderActive { stopDropFinder() }
    }

    func startDropFinder() {
        finder.seizureSafe = AppStore.shared.has(.seizure)
        dropFinderActive = true
        finder.start()
    }

    func stopDropFinder() {
        finder.stop()
        dropFinderActive = false
    }

    func trigger(_ t: Trigger) {
        guard let p = AppStore.shared.profile else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        Task {
            let loc = await LocationService.shared.current()
            do {
                incident = try await API.shared.startIncident(userId: p.userId, trigger: t.rawValue,
                                                             lat: loc?.coordinate.latitude, lon: loc?.coordinate.longitude)
                UserDefaults.standard.set(incident?.id, forKey: "activeIncident")
                LocationService.shared.setTracking(true)
                announce()
                startPolling()
            } catch {
                // Backend unreachable: fall back to the phone's own dialer to the contact.
                lastError = tr("Server not reachable", "Server nicht erreichbar")
                if let c = p.contacts.first, let url = URL(string: "tel://\(c.phone)") {
                    Speaker.shared.say(tr("I can't reach the server. I'm calling \(c.name) directly.", "Ich erreiche den Server nicht. Ich rufe \(c.name) direkt an."))
                    await UIApplication.shared.open(url)
                }
            }
        }
    }

    // MARK: answers

    func imOK() {
        guard let id = incident?.id else { return }
        Speaker.shared.say(tr("Good. I've cancelled it.", "Gut. Ich habe abgebrochen."))
        Task { incident = try? await API.shared.personOK(id); finish() }
    }

    func confirmEmergency() {
        guard let id = incident?.id else { return }
        Task { incident = try? await API.shared.confirmEmergency(id, by: AppStore.shared.profile?.name ?? "Person") }
    }

    /// iOS always asks the person to confirm before the call goes out.
    func call112() {
        if AppStore.shared.has(.hearing) || AppStore.shared.has(.deafblind) {
            // nora has no public API; open the App Store page / app.
            if let url = URL(string: "https://apps.apple.com/de/app/nora-notruf-app/id1557262669") {
                UIApplication.shared.open(url)
            }
        } else if let url = URL(string: "tel://112") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: internals

    private func announce() {
        guard let inc = incident else { return }
        if inc.state == "asking" {
            if AppStore.shared.has(.hearing) { return } // light + vibration only, shown by IncidentView
            Speaker.shared.say(tr("Are you OK? Tap: I'm OK. Otherwise I'll call for help in 30 seconds.",
                                  "Ist alles in Ordnung? Tippen Sie auf: Mir geht es gut. Sonst rufe ich in 30 Sekunden Hilfe."))
        } else if inc.state == "contacting" {
            Speaker.shared.say(tr("I'm calling your emergency contact. Help is on the way.", "Ich rufe Ihren Notfallkontakt an. Hilfe ist unterwegs."))
        }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            var lastState = self?.incident?.state
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let id = self.incident?.id,
                      let inc = try? await API.shared.incident(id) else { continue }
                self.incident = inc
                if let l = LocationService.shared.last {
                    _ = try? await API.shared.updateLocation(id, lat: l.coordinate.latitude, lon: l.coordinate.longitude)
                }
                if inc.state != lastState {
                    lastState = inc.state
                    if inc.state == "contact_responding", let who = inc.acked_by {
                        Speaker.shared.say(tr("\(who) is taking care of you.", "\(who) kümmert sich um Sie."))
                    } else { self.announce() }
                }
                if inc.state == "resolved" { self.finish(); return }
            }
        }
    }

    private func finish() {
        poll?.cancel()
        UserDefaults.standard.removeObject(forKey: "activeIncident")
        LocationService.shared.setTracking(false)
        Task { try? await Task.sleep(for: .seconds(2)); incident = nil }
    }
}

