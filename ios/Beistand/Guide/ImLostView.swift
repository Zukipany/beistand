import AVFoundation
import SwiftUI

/// Full-screen camera guide. Usable without looking: everything is spoken,
/// the buttons are huge, and captions show what the guide says (also for deaf companions).
struct ImLostView: View {
    @Environment(GuideController.self) private var guide
    @Environment(SafetyService.self) private var safety
    @Environment(AppStore.self) private var store
    @State private var typing = false
    @State private var typed = ""
    @State private var showMap = false

    var body: some View {
        ZStack {
            if SimDrive.shared.active, SimDrive.shared.source == .viewer {
                MapillaryDriveView().ignoresSafeArea()
            } else if SimDrive.shared.active {
                SimStreetPicture().ignoresSafeArea()
            } else {
                GuideCameraPreview(camera: guide.camera).ignoresSafeArea()
                #if targetEnvironment(simulator)
                SimulatedStreet().ignoresSafeArea()
                #endif
            }
            // Lighter in the live view, so the street stays visible behind the labels.
            LinearGradient(colors: [.black.opacity(compact ? 0.5 : 0.85), .black.opacity(compact ? 0 : 0.2), .black.opacity(compact ? 0.6 : 0.9)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                .allowsHitTesting(false)          // touches reach the street viewer underneath
            if guide.lookAround || guide.destinationCoord != nil {
                LiveViewOverlay().ignoresSafeArea()
            }

            VStack(spacing: 14) {
                header
                VolumeBanner()
                if compact {
                    // Street-view layout: one caption line under the compass, a slim bar of controls.
                    liveCaption.padding(.top, 52)
                    Spacer(minLength: 0)
                    if SimDrive.shared.active { SimDriveControls() }
                    liveControls
                } else {
                    captions
                    Spacer(minLength: 0)
                    controls
                }
            }
            .padding(16)
        }
        .foregroundStyle(.white)
        .onAppear {
            #if DEBUG
            // `-simDrive YES -simStart 48.1374,11.5755 -simHeading 90` starts a test drive there.
            if UserDefaults.standard.bool(forKey: "simDrive"), !SimDrive.shared.active {
                let n = (UserDefaults.standard.string(forKey: "simStart") ?? "").split(separator: ",").compactMap { Double($0) }
                SimDrive.shared.start(at: n.count == 2 ? Coord(lat: n[0], lon: n[1]) : nil,
                                      heading: Double(UserDefaults.standard.string(forKey: "simHeading") ?? ""))
            }
            #endif
            // Settings → "The guide uses: Test drive": walk street photos instead of the camera.
            if store.testDrive, !SimDrive.shared.active {
                let here = LocationService.shared.last.map { Coord(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
                SimDrive.shared.start(at: here ?? Coord(lat: 48.1388, lon: 11.5672), heading: 90)
            }
            guide.start()                     // a test drive is already running: the camera stays off
            #if DEBUG
            // Test hooks: `-lookAround YES` turns the live view on; `-fakeSweep YES` turns on the spot (simulator).
            if UserDefaults.standard.bool(forKey: "lookAround") { guide.lookAround = true }
            if UserDefaults.standard.bool(forKey: "fakeSweep") { guide.startDemoSweep() }
            #endif
            // Give the guide the walker's position now that it listens.
            if SimDrive.shared.active { SimDrive.shared.announce() }
        }
        .sheet(isPresented: $showMap) { DestinationMapView() }
        .onDisappear {
            guide.stop()
            if SimDrive.shared.active { SimDrive.shared.stop() }
        }
        .alert(tr("Enter destination", "Ziel eingeben"), isPresented: $typing) {
            TextField(tr("e.g. Marienplatz", "z. B. Marienplatz"), text: $typed)
            Button(tr("Go", "Los")) { guide.go(to: typed); typed = "" }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Label(SimDrive.shared.active ? tr("Test drive", "Testfahrt") : statusText,
                  systemImage: SimDrive.shared.active ? "gamecontroller.fill" : statusIcon)
                .font(.headline)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(0.15), in: Capsule())
            Spacer()
            if guide.camera.usesLiDAR, store.obstacleWarnings { obstacleIndicator }
            if let d = guide.destination {
                Label(d, systemImage: "flag.checkered").font(.headline).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Street-view layout while looking around or on a test drive.
    private var compact: Bool { guide.lookAround || SimDrive.shared.active }

    private var liveCaption: some View {
        Text(guide.lines.last?.text ?? tr("Turn slowly …", "Drehen Sie sich langsam …"))
            .font(.headline).lineLimit(3)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }

    /// Compact controls, so the street stays visible. Same actions, each still a large target (72 pt).
    private var liveControls: some View {
        HStack(spacing: 8) {
            LiveButton(title: tr("Describe", "Beschreiben"), icon: "eye.fill", color: .blue) { guide.describeAhead() }
            LiveButton(title: tr("Map", "Karte"), icon: "map.fill", color: .brown) { showMap = true }
            LiveButton(title: guide.lookAround ? tr("Quiet", "Leise") : tr("Look", "Schauen"),
                       icon: "binoculars.fill", color: .teal) {
                guide.lookAround.toggle()
                Speaker.shared.say(guide.lookAround ? tr("Turn slowly. I'll tell you what is in each direction.", "Drehen Sie sich langsam. Ich sage, was in jeder Richtung ist.")
                                                    : tr("Looking around is off.", "Umschauen ist aus."))
            }
            LiveButton(title: tr("Help", "Hilfe"), icon: "sos", color: .red) { safety.requestHelp() }
            LiveButton(title: tr("End", "Ende"), icon: "xmark", color: .gray) { guide.requestedOpen = false }
        }
    }

    /// Newest line on top, so nothing needs scrolling; older lines fade out.
    private var captions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(guide.lines.suffix(4).reversed().enumerated()), id: \.element.id) { index, line in
                Text(line.text)
                    .font(index == 0 ? .title2.bold() : .title3)
                    .foregroundStyle(line.fromGuide ? Color.white : Color.yellow)
                    .opacity(index == 0 ? 1 : 0.6)
                    .frame(maxWidth: .infinity, alignment: line.fromGuide ? .leading : .trailing)
                    .lineLimit(index == 0 ? nil : 2)
                    .fixedSize(horizontal: false, vertical: index == 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .top)
        .clipped()
        // VoiceOver users hear the guide directly; captions would only repeat it.
        .accessibilityHidden(true)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            BigButton(title: tr("What's in front of me?", "Was ist vor mir?"), systemImage: "eye.fill", color: .blue,
                      explanation: tr("Describes what the camera sees right now.", "Beschreibt, was die Kamera gerade sieht.")) { guide.describeAhead() }
            if guide.mode != .live {
                BigButton(title: guide.listening ? tr("Listening …", "Ich höre zu …") : tr("Say destination", "Ziel sagen"), systemImage: "mic.fill", color: .indigo,
                          explanation: tr("Say where you want to go. Hold to type it.", "Sagen Sie, wohin Sie möchten. Halten zum Eintippen.")) { guide.askDestination() }
                    .simultaneousGesture(LongPressGesture(minimumDuration: 1.5).onEnded { _ in typing = true })
            }
            HStack(spacing: 12) {
                BigButton(title: guide.lookAround ? tr("Stop looking", "Umschauen aus") : tr("Look around", "Umschauen"),
                          color: .teal,
                          explanation: tr("Turn slowly on the spot. I say what is in each direction and read signs.",
                                          "Drehen Sie sich langsam. Ich sage, was in jeder Richtung ist, und lese Schilder.")) {
                    guide.lookAround.toggle()
                    Speaker.shared.say(guide.lookAround
                        ? tr("Hold the phone upright and turn slowly. I'll tell you what is in each direction.",
                             "Halten Sie das Telefon aufrecht und drehen Sie sich langsam. Ich sage, was in jeder Richtung ist.")
                        : tr("Looking around is off.", "Umschauen ist aus."))
                }
                BigButton(title: tr("Map", "Karte"), color: .brown,
                          explanation: tr("Choose the destination on a map and see lifts and step-free access there.",
                                          "Ziel auf der Karte wählen und Aufzüge und stufenlosen Zugang sehen.")) { showMap = true }
            }
            if guide.mode != .live {
                BigButton(title: tr("Next departures", "Nächste Abfahrten"), systemImage: "tram.fill", color: .green,
                          explanation: tr("Reads the next trains, trams and buses at the nearest stop.",
                                          "Liest die nächsten Züge, Trams und Busse an der nächsten Haltestelle vor.")) { guide.sayDepartures() }
            }
            HStack(spacing: 12) {
                BigButton(title: tr("Help", "Hilfe"), color: .red,
                          explanation: tr("Calls your emergency contact.", "Ruft Ihren Notfallkontakt.")) { safety.requestHelp() }
                BigButton(title: tr("End", "Ende"), color: .gray,
                          explanation: tr("Ends the guide.", "Beendet die Begleitung.")) { guide.requestedOpen = false }
            }
        }
    }

    /// Three bars (left, ahead, right) that turn orange and red as something gets close.
    private var obstacleIndicator: some View {
        HStack(spacing: 3) {
            bar(guide.zones.left); bar(guide.zones.centre, wide: true); bar(guide.zones.right)
        }
        .accessibilityElement()
        .accessibilityLabel(guide.zones.centre.map { tr("Obstacle ahead, \(Int($0.rounded())) metres", "Hindernis vorne, \(Int($0.rounded())) Meter") }
                            ?? tr("Nothing close ahead", "Nichts nah vorne"))
    }

    private func bar(_ d: Float?, wide: Bool = false) -> some View {
        let color: Color = d.map { $0 < 0.8 ? .red : $0 < 2 ? .orange : .green } ?? .green
        return RoundedRectangle(cornerRadius: 3).fill(color).frame(width: wide ? 22 : 12, height: 22)
    }

    private var statusText: String {
        switch guide.mode {
        case .off, .connecting: tr("Connecting …", "Verbinde …")
        case .live: tr("Live guide", "Live-Begleitung")
        case .simple: tr("Simple mode", "Einfacher Modus")
        }
    }

    private var statusIcon: String {
        switch guide.mode {
        case .live: "dot.radiowaves.left.and.right"
        case .simple: "camera.viewfinder"
        default: "hourglass"
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.layer.session = session
        v.layer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }
    }
}


#if targetEnvironment(simulator)
/// The simulator has no camera: a plain sky-and-pavement picture, so the live view's labels have a background.
private struct SimulatedStreet: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color(red: 0.45, green: 0.65, blue: 0.9), Color(red: 0.8, green: 0.88, blue: 0.95)],
                           startPoint: .top, endPoint: .bottom)
            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { i in
                    Rectangle().fill(Color(white: 0.55 + Double(i % 3) * 0.08)).frame(height: 160)
                }
            }
            LinearGradient(colors: [Color(white: 0.55), Color(white: 0.35)], startPoint: .top, endPoint: .bottom)
        }
    }
}
#endif


/// One of the live view's compact buttons.
private struct LiveButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title2.bold())
                Text(title).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(color.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
