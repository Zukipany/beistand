import CoreMotion
import Foundation
import Observation
import WatchConnectivity
import WatchKit
import os

private let log = Logger(subsystem: "app.beistand.watch", category: "link")

/// Watch side: reads the wrist accelerometer, talks to the phone, plays the haptic vocabulary.
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    static let shared = WatchModel()

    var state = WatchState()
    var phoneReachable = false
    /// Wrist fall seen while the phone was out of reach: the watch shows its own fallback.
    var offlineFall: Date?
    var sentHelp: Date?

    private let motion = CMMotionManager()
    private var pattern = WristFallPattern()
    private var askingBuzz: Timer?
    private var started = false
    private var pendingTasks: [WKWatchConnectivityRefreshBackgroundTask] = []

    func start() {
        guard !started else { return }
        started = true
        log.info("watch link: supported=\(WCSession.isSupported())")
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        startMotion()
    }

    /// Hold the background task until the session has delivered everything it had queued.
    func complete(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        pendingTasks.append(task)
        finishTasksIfDone()
    }

    private func finishTasksIfDone() {
        let s = WCSession.default
        guard s.activationState == .activated, !s.hasContentPending else { return }
        pendingTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
        pendingTasks.removeAll()
    }

    // MARK: motion

    private func startMotion() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 1.0 / 50
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let d = data else { return }
            let a = d.acceleration
            self.feed(g: sqrt(a.x * a.x + a.y * a.y + a.z * a.z), t: d.timestamp)
        }
    }

    func feed(g: Double, t: TimeInterval) {
        switch pattern.feed(g: g, t: t) {
        case .impact?: send(.wristImpact(at: Date()))
        case .fall?: wristFall()
        case nil: break
        }
    }

    private func wristFall() {
        guard state.incident == "none" || state.incident == "resolved" else { return }
        if phoneReachable { send(.wristFall(at: Date())) }
        else {
            // Queue it for the phone anyway, and offer a direct call from the wrist.
            send(.wristFall(at: Date()))
            offlineFall = Date()
            play(.askingOK)
        }
    }

    #if DEBUG
    /// The simulator has no accelerometer: feed a recorded-looking fall.
    func simulateFall() {
        let t0 = ProcessInfo.processInfo.systemUptime
        feed(g: 1.0, t: t0)
        feed(g: 4.2, t: t0 + 0.02)
        for i in 1...600 { feed(g: 1.0 + (i % 2 == 0 ? 0.02 : -0.02), t: t0 + 0.02 + Double(i) * 0.02) }
    }
    #endif

    // MARK: actions

    func help() {
        sentHelp = Date()
        WKInterfaceDevice.current().play(.start)
        send(.help)
    }

    func imOK() {
        offlineFall = nil
        stopAskingBuzz()
        WKInterfaceDevice.current().play(.success)
        send(.imOK)
    }

    func call(_ number: String) {
        if let url = URL(string: "tel:\(number)") { WKApplication.shared().openSystemURL(url) }
    }

    private func send(_ m: WatchMessage) {
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        if s.isReachable {
            s.sendMessage(m.dict, replyHandler: nil) { _ in s.transferUserInfo(m.dict) }
        } else {
            s.transferUserInfo(m.dict)  // delivered when the phone wakes up
        }
    }

    // MARK: haptics

    func play(_ cue: GuideCue) {
        let dev = WKInterfaceDevice.current()
        switch cue {
        case .left: taps(2)
        case .right: taps(3)
        case .arrived, .helpComing: dev.play(.success)
        case .offRoute: dev.play(.retry)
        case .askingOK: startAskingBuzz()
        }
    }

    private func taps(_ n: Int) {
        for i in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.35) { WKInterfaceDevice.current().play(.click) }
        }
    }

    private func startAskingBuzz() {
        stopAskingBuzz()
        WKInterfaceDevice.current().play(.notification)
        askingBuzz = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func stopAskingBuzz() { askingBuzz?.invalidate(); askingBuzz = nil }

    private func apply(_ new: WatchState) {
        let old = state
        state = new
        guard new.incident != old.incident else { return }
        switch new.incident {
        case "asking": offlineFall = nil; play(.askingOK)
        case "contact_responding": stopAskingBuzz(); play(.helpComing)
        case "contacting", "emergency_confirmed": stopAskingBuzz(); WKInterfaceDevice.current().play(.directionUp)
        default: stopAskingBuzz(); sentHelp = nil
        }
    }

    // MARK: WCSessionDelegate

    func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) {
        let ctx = s.receivedApplicationContext
        log.info("watch link: activated state=\(st.rawValue) reachable=\(s.isReachable) context=\(ctx.count) error=\(String(describing: error))")
        DispatchQueue.main.async {
            self.phoneReachable = s.isReachable
            if !ctx.isEmpty { self.apply(WatchState(ctx)) }
            self.finishTasksIfDone()
            #if DEBUG
            // Test hook: `-watchAction ok|help|fall` presses that button 3 s after the link is up.
            if let a = UserDefaults.standard.string(forKey: "watchAction") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    log.info("watch test action \(a)")
                    switch a {
                    case "ok": self.imOK()
                    case "help": self.help()
                    case "fall": self.simulateFall()
                    default: break
                    }
                }
            }
            #endif
        }
    }

    func sessionReachabilityDidChange(_ s: WCSession) {
        DispatchQueue.main.async { self.phoneReachable = s.isReachable }
    }

    func session(_ s: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        log.info("watch link: context \(ctx["incident"] as? String ?? "?")")
        DispatchQueue.main.async { self.apply(WatchState(ctx)); self.finishTasksIfDone() }
    }

    func session(_ s: WCSession, didReceiveMessage msg: [String: Any]) { receive(msg) }
    func session(_ s: WCSession, didReceiveUserInfo info: [String: Any] = [:]) { receive(info) }

    private func receive(_ msg: [String: Any]) {
        switch WatchMessage(msg) {
        case .cue(let c)?: DispatchQueue.main.async { self.play(c) }
        case .sound(let k)?: DispatchQueue.main.async { self.heard(k) }
        default: break
        }
    }

    // MARK: sounds (hearing mode)

    /// Shown full screen for a few seconds; urgent sounds tap three times.
    var recentSound: SoundKind?

    func heard(_ k: SoundKind) {
        recentSound = k
        let dev = WKInterfaceDevice.current()
        if k.urgent {
            for i in 0..<3 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) { dev.play(.notification) } }
        } else {
            dev.play(.directionUp)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.recentSound == k { self?.recentSound = nil }
        }
    }
}
