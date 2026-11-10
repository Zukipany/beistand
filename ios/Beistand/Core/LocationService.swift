import CoreLocation

/// One-shot and continuous location. High accuracy only while an alert or guide runs.
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    private(set) var last: CLLocation?
    private(set) var heading: Double?          // degrees, true north if available
    private(set) var lastDescription: String?  // last spoken "Sie sind hier: …"
    var onUpdate: ((CLLocation) -> Void)?
    /// The ride helper listens too (the guide may be closed during a ride).
    var onRide: ((CLLocation) -> Void)?
    /// Test drive: positions come from the virtual walker, the real GPS and compass are ignored.
    private(set) var simulated = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async -> CLLocation? {
        if simulated { return last }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        if let last, last.timestamp.timeIntervalSinceNow > -30 { return last }
        return await withCheckedContinuation { c in
            waiters.append(c)
            manager.requestLocation()
        }
    }

    func setTracking(_ on: Bool) {
        manager.desiredAccuracy = on ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = on ? 3 : kCLDistanceFilterNone
        if on {
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
        }
    }

    /// "Sie sind in der Leopoldstraße 12, in Schwabing."
    func describe(_ loc: CLLocation) async -> String {
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Lang.locale).first else {
            return tr("I know your position, but not the address.", "Ich kenne Ihre Position, aber keine Adresse dazu.")
        }
        // "in der …" is wrong for Platz/Weg/Ring, so name the place without a preposition.
        var parts: [String] = []
        if let street = p.thoroughfare {
            parts.append([street, p.subThoroughfare].compactMap { $0 }.joined(separator: " "))
        } else if let name = p.name {
            parts.append(name)
        }
        if let area = p.subLocality ?? p.locality { parts.append(area) }
        let text = tr("You are here: ", "Sie sind hier: ") + parts.joined(separator: ", ") + "."
        lastDescription = text
        return text
    }

    /// Test drive: feed a position (and the way the walker faces) as if it came from GPS and the compass.
    func inject(_ l: CLLocation, heading: Double?) {
        simulated = true
        self.heading = heading
        last = l
        waiters.forEach { $0.resume(returning: l) }
        waiters.removeAll()
        onUpdate?(l)
    }

    func endSimulation() { simulated = false; last = nil }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard !simulated, let l = locs.last else { return }
        last = l
        waiters.forEach { $0.resume(returning: l) }
        waiters.removeAll()
        onUpdate?(l)
        onRide?(l)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        waiters.forEach { $0.resume(returning: last) }
        waiters.removeAll()
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        guard !simulated else { return }
        heading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if !waiters.isEmpty { m.requestLocation() }
    }
}
