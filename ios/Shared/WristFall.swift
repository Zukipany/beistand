import Foundation

/// Fall seen from the wrist: a hard hit, then the arm lies still.
/// A watch rarely sees free fall (the arm flails), so unlike the phone this
/// pattern starts at the impact. Pure logic, fed with samples, so it is testable.
struct WristFallPattern {
    var impactAbove = 3.0          // g, magnitude incl. gravity
    var settleWithin: TimeInterval = 4
    var stillFor: TimeInterval = 10
    var stillTolerance = 0.15      // deviation from 1 g
    var impactCooldown: TimeInterval = 2

    enum Event: Equatable { case impact, fall }
    enum Phase: Equatable { case idle, impact(at: TimeInterval), still(since: TimeInterval) }
    private(set) var phase: Phase = .idle
    private var lastImpact: TimeInterval = -.infinity

    mutating func feed(g: Double, t: TimeInterval) -> Event? {
        var event: Event?
        if g > impactAbove {
            if t - lastImpact >= impactCooldown { event = .impact }
            lastImpact = t
            phase = .impact(at: t)
            return event
        }
        switch phase {
        case .idle:
            break
        case .impact(let at):
            if abs(g - 1) < stillTolerance { phase = .still(since: t) }
            else if t - at > settleWithin { phase = .idle }    // kept moving: clapping, sports
        case .still(let since):
            if abs(g - 1) >= stillTolerance * 2 { phase = .idle }  // arm moved: the person is moving
            else if t - since >= stillFor { phase = .idle; event = .fall }
        }
        return event
    }
}
