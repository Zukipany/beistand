import CoreMotion
import Foundation

/// Free fall → sharp impact → stillness. Pure logic, fed with samples, so it is testable.
struct FallPattern {
    // Thresholds in g (magnitude of user acceleration incl. gravity).
    var freeFallBelow = 0.35
    var minFreeFall: TimeInterval = 0.08
    var impactAbove = 2.5
    var impactWindow: TimeInterval = 1.0
    var stillFor: TimeInterval = 10
    var stillTolerance = 0.12  // deviation from 1 g

    enum Phase: Equatable { case idle, freeFall(start: TimeInterval), impact(at: TimeInterval), still(since: TimeInterval) }
    private(set) var phase: Phase = .idle

    /// Returns true once, when a complete fall pattern has been seen.
    mutating func feed(g: Double, t: TimeInterval) -> Bool {
        switch phase {
        case .idle:
            if g < freeFallBelow { phase = .freeFall(start: t) }
        case .freeFall(let start):
            if g > impactAbove, t - start >= minFreeFall { phase = .impact(at: t) }
            else if g >= freeFallBelow, g <= impactAbove, t - start > impactWindow { phase = .idle }
            else if g >= freeFallBelow && t - start < minFreeFall { phase = .idle }
        case .impact(let at):
            if abs(g - 1) < stillTolerance { phase = .still(since: t) }
            else if t - at > 3 { phase = .idle }
        case .still(let since):
            if abs(g - 1) >= stillTolerance * 2 { phase = .idle }  // picked up or moving
            else if t - since >= stillFor { phase = .idle; return true }
        }
        return false
    }
}

/// Reads the accelerometer at 50 Hz and reports impacts and pickups.
final class MotionMonitor {
    private let motion = CMMotionManager()
    private var pattern = FallPattern()
    private var lastImpact: TimeInterval?
    var onFallPattern: (() -> Void)?   // free fall + impact + 10 s still
    var onPickup: (() -> Void)?

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 1.0 / 50
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            let g = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            if self.pattern.feed(g: g, t: data!.timestamp) { self.onFallPattern?() }
            if abs(g - 1) > 0.3 { self.onPickup?() }
        }
    }

    func stop() { motion.stopAccelerometerUpdates() }
}
