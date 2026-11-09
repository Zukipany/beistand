import Foundation
import WatchConnectivity
import os

private let log = Logger(subsystem: "app.beistand.ios", category: "watch")

/// Phone side of the watch link. The watch reports wrist hits, falls and the help button;
/// the phone sends the incident state (application context) and guide cues (messages).
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    var lastWristImpact: Date?
    var recentWristImpact: Bool { (lastWristImpact?.timeIntervalSinceNow ?? -100) > -15 }
    private var lastState: WatchState?

    func activate() {
        guard WCSession.isSupported(), WCSession.default.activationState == .notActivated else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: phone → watch

    func push(_ incident: API.Incident?) {
        let p = AppStore.shared.profile
        let st = WatchState(incident: incident?.state ?? "none", ackedBy: incident?.acked_by,
                            contactName: p?.contacts.first?.name, contactPhone: p?.contacts.first?.phone,
                            personName: p?.name)
        guard st != lastState else { return }
        lastState = st
        let s = WCSession.default
        log.info("watch push \(st.incident) paired=\(s.isPaired) installed=\(s.isWatchAppInstalled)")
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        try? s.updateApplicationContext(st.dict)
    }

    /// Sounds go as a message when the watch app is open, else queued, so the wrist still learns about them.
    func sound(_ k: SoundKind) {
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        if s.isReachable { s.sendMessage(WatchMessage.sound(k).dict, replyHandler: nil, errorHandler: nil) }
        else { s.transferUserInfo(WatchMessage.sound(k).dict) }
    }

    func cue(_ c: GuideCue) {
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else { return }
        s.sendMessage(WatchMessage.cue(c).dict, replyHandler: nil, errorHandler: nil)
    }

    // MARK: watch → phone

    func handle(_ m: WatchMessage) {
        let safety = SafetyService.shared
        switch m {
        case .help: safety.requestHelp()
        case .imOK: safety.imOK()
        case .wristImpact(let at):
            lastWristImpact = at
            safety.wristImpact()
        case .wristFall(let at):
            // A queued fall that arrives much later is no longer actionable here; the watch offered calls itself.
            guard Date().timeIntervalSince(at) < 120 else { return }
            lastWristImpact = at
            safety.wristFall()
        case .cue, .sound: break
        }
    }

    private func received(_ d: [String: Any]) {
        log.info("watch says \(d["k"] as? String ?? "?")")
        guard let m = WatchMessage(d) else { return }
        DispatchQueue.main.async { self.handle(m) }
    }

    // MARK: WCSessionDelegate

    func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.lastState = nil; self.push(SafetyService.shared.incident) }
    }
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { s.activate() }  // switched to another watch
    func sessionWatchStateDidChange(_ s: WCSession) {
        DispatchQueue.main.async { self.lastState = nil; self.push(SafetyService.shared.incident) }
    }
    func session(_ s: WCSession, didReceiveMessage msg: [String: Any]) { received(msg) }
    func session(_ s: WCSession, didReceiveUserInfo info: [String: Any] = [:]) { received(info) }
}
