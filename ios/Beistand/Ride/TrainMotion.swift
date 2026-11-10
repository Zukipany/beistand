import CoreMotion
import Foundation

/// Feels whether the person is on a moving train, and when it stops, from the phone's own motion.
/// A train hums and sways (small, steady shaking); walking gives big, regular steps; standing still
/// in a stopped train is quiet. iOS's own "in a vehicle" guess and the speed (where GPS works,
/// e.g. the S-Bahn above ground) make it surer. Pure, testable.
struct TrainMotion {
    enum State: Equatable { case unknown, walking, still, riding }

    var rideLow = 0.018          // g, shaking of a moving train (phone in hand or pocket) …
    var walkHigh = 0.11          // … below the steps of walking
    var stillBelow = 0.012       // g, quiet: the train has stopped (or the person stands still)
    var rideAfter: TimeInterval = 6       // that long humming before it counts as riding
    var stopAfter: TimeInterval = 5       // that long quiet before it counts as stopped
    var fastSpeed = 6.0          // m/s: faster than anyone walks

    private(set) var state = State.unknown
    private var samples: [(t: TimeInterval, a: Double)] = []
    private var since: TimeInterval = 0
    private var candidate = State.unknown

    /// RMS shaking (g) over the last 2 seconds.
    var shaking: Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.map { $0.a * $0.a }.reduce(0, +) / Double(samples.count)).squareRoot()
    }

    /// Feed user acceleration (gravity removed) in g, ~50 times a second, plus what iOS thinks and the
    /// speed if known. Returns the new state when it changes.
    mutating func feed(x: Double, y: Double, z: Double, at t: TimeInterval,
                       automotive: Bool = false, speed: Double? = nil) -> State? {
        samples.append((t, (x * x + y * y + z * z).squareRoot()))
        samples.removeAll { t - $0.t > 2 }
        let rms = shaking
        let raw: State
        if let s = speed, s >= fastSpeed { raw = .riding }
        else if rms >= walkHigh, !automotive { raw = .walking }
        else if rms >= rideLow || (automotive && rms >= stillBelow) { raw = .riding }
        else if rms < stillBelow { raw = .still }
        else { raw = state }
        if raw != candidate { candidate = raw; since = t }
        let hold: TimeInterval = raw == .riding ? (automotive || (speed ?? 0) >= fastSpeed ? 2 : rideAfter)
                               : raw == .still ? stopAfter : 2
        guard raw != state, t - since >= hold else { return nil }
        state = raw
        return raw
    }
}

/// Runs TrainMotion on the phone's sensors. `onChange` gets riding / still / walking.
@MainActor
final class TrainMotionWatcher {
    static let shared = TrainMotionWatcher()
    private let motion = CMMotionManager()
    private let activity = CMMotionActivityManager()
    private var detector = TrainMotion()
    private var automotive = false
    private(set) var state = TrainMotion.State.unknown
    var onChange: ((TrainMotion.State) -> Void)?
    /// Riding noticed (at most every 10 minutes), for offering the ride helper.
    var onRidingNoticed: (() -> Void)?
    private var lastNoticed = Date.distantPast
    private var ridingSince: Date?
    private var running = false

    func start() {
        guard !running, motion.isDeviceMotionAvailable else { return }
        running = true
        detector = TrainMotion()
        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: .main) { [weak self] a in self?.automotive = a?.automotive ?? false }
        }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let a = m?.userAcceleration else { return }
            let speed = LocationService.shared.last.flatMap { $0.speed >= 0 && $0.timestamp.timeIntervalSinceNow > -10 ? $0.speed : nil }
            if let s = self.detector.feed(x: a.x, y: a.y, z: a.z, at: ProcessInfo.processInfo.systemUptime,
                                          automotive: self.automotive, speed: speed) {
                self.state = s
                self.onChange?(s)
                self.ridingSince = s == .riding ? Date() : nil
            }
            // Offer the ride helper only when it is clearly a vehicle: iOS says so, the speed is beyond
            // walking, or the hum has gone on for 45 s (a shaky hand alone must not trigger it).
            if self.state == .riding, let since = self.ridingSince, Date().timeIntervalSince(self.lastNoticed) > 600,
               self.automotive || (speed ?? 0) >= 6 || Date().timeIntervalSince(since) >= 45 {
                self.lastNoticed = Date()
                self.onRidingNoticed?()
            }
        }
    }

    func stop() {
        running = false
        motion.stopDeviceMotionUpdates()
        activity.stopActivityUpdates()
    }
}
