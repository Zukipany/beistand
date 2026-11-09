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

    var body: some View {
        ZStack {
            GuideCameraPreview(camera: guide.camera).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.2), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 14) {
                header
                VolumeBanner()
                captions
                Spacer(minLength: 0)
                controls
            }
            .padding(16)
        }
        .foregroundStyle(.white)
        .onAppear { guide.start() }
        .onDisappear { guide.stop() }
        .alert(tr("Enter destination", "Ziel eingeben"), isPresented: $typing) {
            TextField(tr("e.g. Marienplatz", "z. B. Marienplatz"), text: $typed)
            Button(tr("Go", "Los")) { guide.go(to: typed); typed = "" }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Label(statusText, systemImage: statusIcon)
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
