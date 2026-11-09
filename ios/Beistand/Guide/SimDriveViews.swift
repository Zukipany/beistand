import MapKit
import SwiftUI
import WebKit

/// The street picture of the test drive, filling the screen like the camera would.
struct SimStreetPicture: View {
    @Environment(GuideController.self) private var guide
    let drive = SimDrive.shared

    var body: some View {
        ZStack {
            Color(white: 0.35)
            if let img = drive.picture {
                Image(uiImage: img).resizable().scaledToFill()
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Sticks, mini-map and keyboard for the test drive. Sits above the live view's button bar.
struct SimDriveControls: View {
    @Environment(GuideController.self) private var guide
    @Bindable var drive = SimDrive.shared
    @FocusState private var keyboard: Bool

    var body: some View {
        VStack(spacing: 6) {
            status
            HStack(alignment: .bottom, spacing: 10) {
                Joystick(value: $drive.moveStick, label: tr("Walk", "Gehen"), icon: "figure.walk")
                SimMiniMap().frame(maxWidth: .infinity).frame(height: 130)
                Joystick(value: $drive.lookStick, label: tr("Turn", "Drehen"), icon: "arrow.triangle.2.circlepath")
            }
        }
        // Hardware keyboard (Mac keyboard in the simulator, or a keyboard on the phone).
        .focusable()
        .focused($keyboard)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .up]) { press in
            guard let k = Self.name(press) else { return .ignored }
            if press.modifiers.contains(.shift) { drive.keys.insert("shift") } else { drive.keys.remove("shift") }
            if press.phase == .up { drive.keys.remove(k) } else { drive.keys.insert(k) }
            return .handled
        }
        .onAppear { keyboard = true }
        .onTapGesture { keyboard = true }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller.fill")
            if let p = drive.problem {
                Text(p).lineLimit(2)
            } else {
                Text(source).lineLimit(1)
                if drive.loading { ProgressView().controlSize(.mini).tint(.white) }
            }
            Spacer(minLength: 0)
            Text(tr("W A S D · Q E turn · ⇧ fast", "W A S D · Q E drehen · ⇧ schnell")).opacity(0.8)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.6), in: Capsule())
    }

    /// Attribution, as Google and Mapillary require.
    private var source: String {
        switch drive.provider {
        case "google": "Google Street View" + (drive.captured.map { " · \($0)" } ?? "")
        case "mapillary": "© Mapillary contributors, CC BY-SA" + (drive.captured.map { " · \($0)" } ?? "")
        default: tr("Test drive", "Testfahrt")
        }
    }

    static func name(_ p: KeyPress) -> String? {
        switch p.key {
        case .upArrow: return "up"
        case .downArrow: return "down"
        case .leftArrow: return "left"
        case .rightArrow: return "right"
        default:
            let c = p.characters.lowercased()
            return ["w", "a", "s", "d", "q", "e", "r", "f"].contains(c) ? c : nil
        }
    }
}

/// A thumb stick: drag the knob; the value is -1 … 1 in each direction (up = +1).
struct Joystick: View {
    @Binding var value: CGVector
    let label: String
    let icon: String
    private let size: CGFloat = 112
    /// Resets by itself when the touch ends *or* is cancelled, so the walker never keeps walking alone.
    @GestureState private var drag: CGSize?

    private var vector: CGVector {
        guard let d = drag else { return .zero }
        let r = size / 2
        var v = CGVector(dx: d.width / r, dy: d.height / r)
        let len = hypot(v.dx, v.dy)
        if len > 1 { v = CGVector(dx: v.dx / len, dy: v.dy / len) }
        return v
    }

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.45)).overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 2))
            VStack(spacing: 2) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption2.bold())
            }
            .opacity(0.7)
            Circle().fill(.white.opacity(0.85)).frame(width: 46, height: 46)
                .offset(x: vector.dx * size * 0.3, y: vector.dy * size * 0.3)
                .animation(.spring(duration: 0.2), value: drag == nil)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).updating($drag) { g, state, _ in state = g.translation })
        .onChange(of: drag) { _, _ in
            let v = vector
            value = CGVector(dx: abs(v.dx) < 0.12 ? 0 : v.dx, dy: abs(v.dy) < 0.12 ? 0 : -v.dy)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

/// Small map: where the walker is, which way they look, the route and the destination. Tap to jump there.
struct SimMiniMap: View {
    @Environment(GuideController.self) private var guide
    let drive = SimDrive.shared

    var body: some View {
        let p = drive.state.position
        let here = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
        MapReader { proxy in
            Map(position: .constant(.camera(MapCamera(centerCoordinate: here, distance: 450, heading: drive.state.heading))),
                interactionModes: []) {
                if guide.routeLine.count > 1 {
                    MapPolyline(coordinates: guide.routeLine.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(.blue, lineWidth: 4)
                }
                if let d = guide.destinationCoord {
                    Marker("", systemImage: "flag.checkered", coordinate: CLLocationCoordinate2D(latitude: d.lat, longitude: d.lon)).tint(.red)
                }
                Annotation("", coordinate: here) {
                    Image(systemName: "location.north.fill").font(.title2).foregroundStyle(.orange)
                        .rotationEffect(.degrees(0))          // the map turns with the walker, so the arrow points up
                        .shadow(radius: 2)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .onTapGesture { pt in
                if let c = proxy.convert(pt, from: .local) { drive.teleport(to: Coord(lat: c.latitude, lon: c.longitude)) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.7), lineWidth: 2))
        .accessibilityLabel(tr("Mini map. Tap to jump there.", "Kleine Karte. Tippen, um dorthin zu springen."))
    }
}

/// Mapillary's walking viewer (MapillaryJS) in a web view: real street photos with animated steps
/// between them. Touch works too (drag to look around, tap the arrows to walk); every move is reported
/// back to SimDrive, which feeds the guide's GPS, compass and camera.
struct MapillaryDriveView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "drive")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.load(URLRequest(url: SimDrive.shared.viewerURL))
        SimDrive.shared.web = web
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "drive")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let m = message.body as? [String: Any] else { return }
            MainActor.assumeIsolated { SimDrive.shared.viewerEvent(m) }
        }
    }
}
