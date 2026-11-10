import MapKit
import SwiftUI

/// Dev: where the live feeds say parked e-scooters and bikes are, to compare with what is really on
/// the pavement. Not part of the app people use: they only feel the vibration.
struct DevScooterMapView: View {
    @State private var scooters: [Scooter] = []
    @State private var here: Coord?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $camera) {
                UserAnnotation()
                ForEach(scooters) { s in
                    Annotation(s.kind == "bike" ? "bike" : "scooter", coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)) {
                        Image(systemName: s.kind == "bike" ? "bicycle" : "scooter").font(.caption.bold())
                            .padding(5).background(.orange, in: Circle()).foregroundStyle(.black)
                    }
                }
                if let here {
                    MapCircle(center: CLLocationCoordinate2D(latitude: here.lat, longitude: here.lon), radius: 10)
                        .foregroundStyle(.orange.opacity(0.15)).stroke(.orange, lineWidth: 1)
                }
            }
            .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
            List {
                Section {
                    if let problem { Text(problem).foregroundStyle(.red) }
                    ForEach(scooters.prefix(8)) { s in
                        HStack {
                            Image(systemName: s.kind == "bike" ? "bicycle" : "scooter")
                            Text(s.id.split(separator: ":").first.map(String.init) ?? "")
                            Spacer()
                            if let here { Text("\(Int(Geo.distance(here, s.coord).rounded())) m").monospacedDigit() }
                        }
                    }
                } header: {
                    Text(tr("\(scooters.count) parked within 300 m (live feeds)", "\(scooters.count) geparkt im Umkreis von 300 m (Live-Daten)"))
                } footer: {
                    Text(tr("The circle is 10 m: the phone vibrates when you walk towards one inside it, or are within 2 m. GPS is only accurate to a few metres.",
                            "Der Kreis ist 10 m: Das Telefon vibriert, wenn Sie innerhalb darauf zugehen oder näher als 2 m sind. GPS ist nur auf einige Meter genau."))
                }
            }
            .frame(height: 280)
        }
        .navigationTitle(tr("Dev: Scooter map", "Dev: Roller-Karte"))
        .toolbar { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading) }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let l = await LocationService.shared.current() else { problem = tr("No location.", "Kein Standort."); return }
        let p = Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        here = p
        struct R: Decodable { let data: [Scooter] }
        do {
            let r: R = try await GuideAPI.get("scooters", ["lat": "\(p.lat)", "lon": "\(p.lon)", "radius_m": "300"])
            scooters = r.data
            problem = nil
        } catch {
            problem = tr("Scooter data not reachable.", "Roller-Daten nicht erreichbar.")
        }
    }
}
