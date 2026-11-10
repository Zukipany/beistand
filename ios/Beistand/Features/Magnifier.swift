import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import SwiftUI
import UIKit

/// Live camera frames for the magnifier, with real camera zoom (sharper than scaling a picture),
/// torch and colour modes for low vision.
@Observable
final class MagnifierCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Colors: Int, CaseIterable { case normal, highContrast, inverted }

    private(set) var frame: CGImage?
    private(set) var available = true
    private(set) var zoom: CGFloat = 2
    private(set) var maxZoom: CGFloat = 10
    private(set) var torchOn = false
    var frozen = false
    var colors: Colors = .normal

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "beistand.magnifier")
    @ObservationIgnored private let ci = CIContext()
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var lastFrame = Date.distantPast
    @ObservationIgnored private var colorsOnQueue: Colors = .normal

    func start() {
        queue.async { [self] in
            if session.inputs.isEmpty {
                guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else {
                    DispatchQueue.main.async { self.available = false; self.useTestPicture() }
                    return
                }
                device = cam
                session.beginConfiguration()
                session.sessionPreset = .hd1280x720
                session.addInput(input)
                let out = AVCaptureVideoDataOutput()
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(out) { session.addOutput(out) }
                out.connection(with: .video)?.videoRotationAngle = 90
                session.commitConfiguration()
                let maxZ = min(cam.activeFormat.videoMaxZoomFactor, 10)
                DispatchQueue.main.async { self.maxZoom = maxZ }
                setZoomOnQueue(zoom)
                try? cam.lockForConfiguration()
                if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
                if cam.isAutoFocusRangeRestrictionSupported { cam.autoFocusRangeRestriction = .near }
                cam.unlockForConfiguration()
            }
            session.startRunning()
        }
    }

    func stop() {
        setTorch(false)
        queue.async { [self] in session.stopRunning() }
    }

    func setZoom(_ z: CGFloat) {
        let z = max(1, min(z, maxZoom))
        zoom = z
        queue.async { [self] in setZoomOnQueue(z) }
    }

    private func setZoomOnQueue(_ z: CGFloat) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(z, d.activeFormat.videoMaxZoomFactor))
        d.unlockForConfiguration()
    }

    func setTorch(_ on: Bool) {
        torchOn = on
        queue.async { [self] in
            guard let d = device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
            d.torchMode = on ? .on : .off
            d.unlockForConfiguration()
        }
    }

    func cycleColors() {
        colors = Colors(rawValue: (colors.rawValue + 1) % Colors.allCases.count) ?? .normal
        let c = colors
        queue.async { [self] in colorsOnQueue = c }
        if !available { useTestPicture() }
    }

    /// The current picture as JPEG, unfiltered, for "Explain".
    /// The colour in the middle of the picture, named ("dark blue"), for clothes, pills, a bus.
    func centreColour() -> String? {
        guard let f = rawFrame else { return nil }
        let img = CIImage(cgImage: f)
        let e = img.extent
        let box = CGRect(x: e.midX - e.width * 0.1, y: e.midY - e.height * 0.1, width: e.width * 0.2, height: e.height * 0.2)
        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: img, kCIInputExtentKey: CIVector(cgRect: box)])?.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ci.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return ColorName.name(r: Double(px[0]) / 255, g: Double(px[1]) / 255, b: Double(px[2]) / 255)
    }

    func jpeg() -> Data? {
        guard let f = rawFrame else { return nil }
        return UIImage(cgImage: f).jpegData(compressionQuality: 0.7)
    }
    @ObservationIgnored private var rawFrame: CGImage?

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastFrame) >= 1.0 / 15, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        lastFrame = Date()
        let img = CIImage(cvPixelBuffer: px)
        guard let raw = ci.createCGImage(img, from: img.extent),
              let shown = ci.createCGImage(Self.filtered(img, colorsOnQueue), from: img.extent) else { return }
        DispatchQueue.main.async {
            guard !self.frozen else { return }
            self.rawFrame = raw
            self.frame = shown
        }
    }

    static func filtered(_ img: CIImage, _ c: Colors) -> CIImage {
        guard c != .normal else { return img }
        let grey = CIFilter.colorControls()
        grey.inputImage = img
        grey.saturation = 0
        grey.contrast = 2.2
        grey.brightness = 0.05
        guard var out = grey.outputImage else { return img }
        if c == .inverted {
            let inv = CIFilter.colorInvert()
            inv.inputImage = out
            out = inv.outputImage ?? out
        }
        return out
    }

    /// Simulator (no camera): a printed-label picture, so zoom, colours and "Explain" can be tried.
    private func useTestPicture() {
        let ui = TestPicture.medicineLabel()
        guard let cg = ui.cgImage else { return }
        rawFrame = cg
        let ciImg = CIImage(cgImage: cg)
        frame = ci.createCGImage(Self.filtered(ciImg, colors), from: ciImg.extent)
    }
}

/// Low-vision magnifier: hold the phone over small print. Pinch or +/− to zoom, light,
/// high-contrast colours, freeze, and "Explain" (a vision model says what it is and reads it).
struct MagnifierView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cam = MagnifierCamera()
    @State private var pinchStart: CGFloat?
    @State private var explanation: String?
    @State private var explaining = false

    var body: some View {
        ZStack {
            // The picture fills the screen behind the controls; as an overlay it cannot widen the layout.
            Color.black
                .overlay {
                    if let f = cam.frame {
                        Image(decorative: f, scale: 1)
                            .resizable()
                            .scaledToFill()
                            // Without a camera (simulator) the test picture is scaled in software.
                            .scaleEffect(cam.available ? 1 : cam.zoom / 2)
                    }
                }
                .clipped()
                .ignoresSafeArea()
                .accessibilityIgnoresInvertColors()
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                topBar
                Spacer()
                if let explanation {
                    ScrollView {
                        ReadAloudText(text: explanation)
                            .padding()
                            .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .frame(maxHeight: 380)
                }
                controls
            }
            .padding(16)
        }
        .gesture(MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil { pinchStart = cam.zoom }
                cam.setZoom((pinchStart ?? cam.zoom) * v.magnification)
            }
            .onEnded { _ in pinchStart = nil })
        .onAppear {
            cam.start()
            Speaker.shared.say(tr("Magnifier. Hold the phone over the text. Tap Explain and I'll read it to you.",
                                  "Lupe. Halten Sie das Telefon über den Text. Tippen Sie auf Erklären, dann lese ich vor."))
        }
        .onDisappear { cam.stop(); Speaker.shared.stop() }
    }

    private var topBar: some View {
        HStack {
            Text("\(String(format: "%.1f", cam.zoom))×")
                .font(.title2.bold().monospacedDigit())
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.white)
                .accessibilityLabel(tr("Zoom \(Int(cam.zoom.rounded())) times", "Vergrößerung \(Int(cam.zoom.rounded()))-fach"))
            if !cam.available {
                Text(tr("Test picture (no camera)", "Testbild (keine Kamera)"))
                    .font(.headline).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.7), in: Capsule())
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title.bold()).foregroundStyle(.white)
                    .frame(width: 60, height: 60).background(.black.opacity(0.7), in: Circle())
            }
            .accessibilityLabel(tr("Close magnifier", "Lupe schließen"))
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                square("minus.magnifyingglass", tr("Smaller", "Kleiner")) { cam.setZoom(cam.zoom / 1.5) }
                square("plus.magnifyingglass", tr("Bigger", "Größer")) { cam.setZoom(cam.zoom * 1.5) }
                square(cam.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                       cam.torchOn ? tr("Light off", "Licht aus") : tr("Light on", "Licht an")) { cam.setTorch(!cam.torchOn) }
                square("circle.lefthalf.filled", colorsName) { cam.cycleColors() }
                square(cam.frozen ? "play.fill" : "pause.fill",
                       cam.frozen ? tr("Live", "Live") : tr("Freeze", "Anhalten")) { cam.frozen.toggle() }
                square("paintpalette.fill", tr("What colour?", "Welche Farbe?")) {
                    let name = cam.centreColour() ?? tr("I can't see a colour yet.", "Ich sehe noch keine Farbe.")
                    explanation = name.prefix(1).uppercased() + name.dropFirst()
                    Speaker.shared.say(explanation ?? name)
                }
            }
            BigButton(title: explaining ? tr("Looking …", "Schaue …") : tr("Explain", "Erklären"),
                      systemImage: "text.viewfinder", color: .blue,
                      explanation: tr("Says what this is and reads the important text.",
                                      "Sagt, was das ist, und liest den wichtigen Text vor.")) {
                Task { await explain() }
            }
            .disabled(explaining)
        }
    }

    private var colorsName: String {
        switch cam.colors {
        case .normal: tr("Colours: normal", "Farben: normal")
        case .highContrast: tr("Colours: high contrast", "Farben: kontrastreich")
        case .inverted: tr("Colours: inverted", "Farben: umgekehrt")
        }
    }

    private func square(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title.bold())
                .frame(maxWidth: .infinity, minHeight: 64)
                .foregroundStyle(.white)
                .background(A11yColor.fill(.gray), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel(label)
    }

    private func explain() async {
        guard let jpeg = cam.jpeg() else {
            Speaker.shared.say(tr("I don't have a picture yet.", "Ich habe noch kein Bild.")); return
        }
        explaining = true
        cam.frozen = true          // keep showing what is being explained
        defer { explaining = false }
        Speaker.shared.say(tr("One moment.", "Einen Moment."))
        if let d: GuideAPI.Described = try? await GuideAPI.post("describe", [
            "image_b64": jpeg.base64EncodedString(), "lang": Lang.code, "purpose": "magnify"]) {
            explanation = d.spoken
            return
        }
        // No server or no key: the phone reads the text itself.
        if let img = UIImage(data: jpeg), let r = await OnDeviceReader.read(img) {
            explanation = OnDeviceReader.spoken(r)
        } else {
            explanation = tr("I can't find any text. Move a little closer, or turn on the light.",
                             "Ich finde keinen Text. Gehen Sie etwas näher heran oder schalten Sie das Licht an.")
        }
    }
}

/// A printed medicine label, for testing text reading and vision models without a camera.
enum TestPicture {
    static func medicineLabel() -> UIImage {
        // Narrow like a phone screen, so "fill" does not crop the text; drawn at 1x so pixels = points.
        let size = CGSize(width: 480, height: 1040)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let lines = ["Ibuprofen 400 mg", "Take 1 tablet up to", "3 times a day.", "Not more than 3 tablets",
                         "in 24 hours.", "Best before: 03.2028", "Price: 4,95 €"]
            for (i, l) in lines.enumerated() {
                (l as NSString).draw(at: CGPoint(x: 40, y: 260 + i * 70),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: i == 0 ? 44 : 30, weight: i == 0 ? .bold : .regular),
                                                      .foregroundColor: UIColor.darkGray])
            }
        }
    }
}
