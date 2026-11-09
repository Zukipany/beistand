import MapKit
import SwiftUI

/// Choose a destination on a map: search, or press and hold to drop a pin. Before leaving, the person
/// (or a family member planning for them) sees what the map knows about access there: step-free,
/// lifts, entrances, accessible toilets, steps. "Take me there" hands it to the guide.
struct DestinationMapView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GuideController.self) private var guide
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755), latitudinalMeters: 900, longitudinalMeters: 900)))
    @State private var pin: CLLocationCoordinate2D?
    @State private var pinName = ""
    @State private var access: GuideAPI.Access.Data?
    @State private var loading = false
    @State private var query = ""
    @State private var results: [GuideAPI.Place] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $camera) {
                        UserAnnotation()
                        if let pin {
                            Marker(pinName.isEmpty ? tr("Destination", "Ziel") : pinName, systemImage: "flag.checkered", coordinate: pin)
                                .tint(.red)
                        }
                    }
                    .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
                    .gesture(LongPressGesture(minimumDuration: 0.4)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { value in
                            if case .second(true, let drag?) = value, let c = proxy.convert(drag.location, from: .local) {
                                drop(c, name: "")
                            }
                        })
                    .accessibilityLabel(tr("Map. Press and hold to drop a destination pin.", "Karte. Gedrückt halten, um ein Ziel zu setzen."))
                }
                card
            }
            .navigationTitle(tr("Choose destination", "Ziel wählen"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: tr("Search a place", "Ort suchen"))
            .searchSuggestions {
                ForEach(results, id: \.name) { r in
                    Button { drop(CLLocationCoordinate2D(latitude: r.lat, longitude: r.lon), name: r.name); query = "" } label: {
                        VStack(alignment: .leading) { Text(r.name).font(.headline); Text(r.address ?? "").font(.caption).lineLimit(1) }
                    }
                }
            }
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { _, q in if q.count >= 3 { Task { await search() } } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(tr("Close", "Schließen")) { dismiss() } }
            }
            .onAppear {
                #if DEBUG
                // Test hook: `-dropPin 48.1394,11.5649` drops a pin there.
                if let s = UserDefaults.standard.string(forKey: "dropPin") {
                    let n = s.split(separator: ",").compactMap { Double($0) }
                    if n.count == 2 { drop(CLLocationCoordinate2D(latitude: n[0], longitude: n[1]), name: "") }
                }
                #endif
            }
        }
    }

    // MARK: card

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pin == nil {
                Label(tr("Search above, or press and hold on the map to drop a pin.",
                         "Oben suchen, oder auf der Karte gedrückt halten, um eine Nadel zu setzen."), systemImage: "hand.tap.fill")
                    .font(.title3)
            } else {
                Text(pinName.isEmpty ? tr("Dropped pin", "Gesetzte Nadel") : pinName).font(.title2.bold())
                if loading {
                    ProgressView(tr("Checking accessibility …", "Prüfe Barrierefreiheit …"))
                } else if let a = access {
                    HStack(spacing: 8) {
                        chip(stepFree(a.place?.wheelchair), icon: "figure.roll", color: stepColor(a.place?.wheelchair))
                        chip(a.elevators.isEmpty ? tr("No lift on the map", "Kein Aufzug eingetragen")
                                                 : tr("\(a.elevators.count) lift(s), \(a.elevators[0].distance_m) m", "\(a.elevators.count) Aufzug/Aufzüge, \(a.elevators[0].distance_m) m"),
                             icon: "arrow.up.arrow.down.square.fill", color: a.elevators.isEmpty ? .gray : .blue)
                    }
                    Text(a.spoken).font(.body).fixedSize(horizontal: false, vertical: true)
                    Text(tr("From OpenStreetMap. Missing means unknown, not inaccessible.",
                            "Aus OpenStreetMap. Fehlende Angaben heißen unbekannt, nicht unzugänglich."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(tr("No accessibility data could be loaded.", "Keine Daten zur Barrierefreiheit geladen.")).foregroundStyle(.secondary)
                }
                HStack {
                    Button { Speaker.shared.say([pinName, access?.spoken ?? ""].joined(separator: ". ")) } label: {
                        Label(tr("Read aloud", "Vorlesen"), systemImage: "speaker.wave.2.fill").frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    Button { takeMeThere() } label: {
                        Label(tr("Take me there", "Dorthin führen"), systemImage: "figure.walk").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func chip(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.subheadline.bold()).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color, in: Capsule())
    }

    private func stepFree(_ w: String?) -> String {
        switch w {
        case "yes": tr("Step-free", "Stufenlos")
        case "limited": tr("Partly step-free", "Teilweise stufenlos")
        case "no": tr("Not step-free", "Nicht stufenlos")
        default: tr("Step-free: unknown", "Stufenlos: unbekannt")
        }
    }

    private func stepColor(_ w: String?) -> Color {
        switch w { case "yes": .green; case "limited": .orange; case "no": .red; default: .gray }
    }

    // MARK: actions

    private func drop(_ c: CLLocationCoordinate2D, name: String) {
        pin = c
        pinName = name
        access = nil
        loading = true
        withAnimation { camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 500, longitudinalMeters: 500)) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            var q = ["lat": "\(c.latitude)", "lon": "\(c.longitude)", "lang": Lang.code]
            if !name.isEmpty { q["name"] = name }
            if let a: GuideAPI.Access = try? await GuideAPI.get("access", q) {
                access = a.data
                if pinName.isEmpty, let n = a.data.place?.name { pinName = n }
            }
            if pinName.isEmpty {
                // Name the pin after the street address, so the guide can say where it goes.
                let geo = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude))
                pinName = geo?.first.map { [$0.thoroughfare, $0.subThoroughfare].compactMap { $0 }.joined(separator: " ") } ?? ""
            }
            loading = false
            UIAccessibility.post(notification: .announcement, argument: [pinName, access?.spoken ?? ""].joined(separator: ". "))
        }
    }

    private func search() async {
        let here = LocationService.shared.last?.coordinate ?? CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755)
        if let r: GuideAPI.Places = try? await GuideAPI.get("geocode", ["q": query, "lat": "\(here.latitude)", "lon": "\(here.longitude)", "lang": Lang.code]) {
            results = r.data
        }
    }

    private func takeMeThere() {
        guard let pin else { return }
        let name = pinName.isEmpty ? tr("the pin", "die Nadel") : pinName
        guide.destinationAccess = access?.spoken
        guide.go(to: Coord(lat: pin.latitude, lon: pin.longitude), name: name)
        guide.requestedOpen = true
        dismiss()
    }
}
