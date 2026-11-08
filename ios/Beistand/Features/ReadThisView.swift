import SwiftUI
import UIKit

/// Photograph a letter; hear it in simple words, action and deadline first.
struct ReadThisView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showCamera = true
    @State private var pickFromLibrary = false
    @State private var reading: API.Reading?            // from the server: simple words
    @State private var local: OnDeviceReader.Result?    // from the phone: the text as it is
    @State private var busy = false
    @State private var error: String?

    /// What is read aloud: the server's simple version if there is one, else the phone's text.
    private var spoken: String? { reading?.spoken ?? local.map { OnDeviceReader.spoken($0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if busy { ProgressView(tr("Reading …", "Ich lese …")).font(.title2).frame(maxWidth: .infinity) }
                    if let error { Text(error).font(.title2).foregroundStyle(.red) }
                    if let spoken {
                        if let d = reading?.deadline ?? local?.deadline { fact(tr("Deadline", "Frist"), d, "calendar") }
                        if let a = reading?.amount ?? local?.amount { fact(tr("Amount", "Betrag"), a, "eurosign.circle") }
                        if let s = reading?.sender { fact(tr("From", "Von"), s, "envelope") }
                        Label(reading != nil ? tr("In simple words", "In einfachen Worten")
                                             : tr("Read on this phone, word for word", "Auf dem Telefon gelesen, Wort für Wort"),
                              systemImage: reading != nil ? "sparkles" : "iphone")
                            .font(.headline).foregroundStyle(.secondary)
                        ReadAloudText(text: spoken)
                        if let c = store.profile?.contacts.first {
                            BigButton(title: tr("Send to \(c.name)", "An \(c.name) schicken"), systemImage: "paperplane.fill", color: .green) { share(spoken, to: c) }
                        }
                    }
                    BigButton(title: tr("New photo", "Neues Foto"), systemImage: "camera.fill", color: .indigo) {
                        pickFromLibrary = false; showCamera = true
                    }
                    BigButton(title: tr("Choose a picture", "Bild auswählen"), systemImage: "photo.on.rectangle", color: .gray,
                              explanation: tr("For example a screenshot of a message.", "Zum Beispiel ein Bildschirmfoto einer Nachricht.")) {
                        pickFromLibrary = true; showCamera = true
                    }
                }
                .padding(16)
            }
            .navigationTitle(tr("Read this", "Vorlesen"))
            .toolbar { Button(tr("Close", "Schließen")) { Speaker.shared.stop(); dismiss() } }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(library: pickFromLibrary) { img in
                    showCamera = false
                    if let img { Task { await read(img) } }
                }.ignoresSafeArea()
            }
        }
    }

    private func fact(_ label: String, _ value: String, _ icon: String) -> some View {
        Label { Text("\(label): \(value)").font(.title2.bold()) } icon: { Image(systemName: icon) }
    }

    private func read(_ img: UIImage) async {
        busy = true; error = nil; reading = nil; local = nil
        defer { busy = false }
        Speaker.shared.say(tr("One moment, I'm reading.", "Einen Moment, ich lese."))
        let small = img.resizedForUpload()
        // The phone reads the text itself in parallel; it is the fallback without a server or key.
        async let onDevice = OnDeviceReader.read(small)
        var serverHint: String?
        if let jpeg = small.jpegData(compressionQuality: 0.7),
           let r = try? await API.shared.read(jpeg: jpeg, lang: Lang.code) {
            if r.readable { reading = r; return }
            serverHint = r.retake_hint
        }
        if let l = await onDevice, l.text.count >= 20 {
            local = l
            return
        }
        let hint = serverHint ?? tr("I can't read any text. Please take the photo again, a bit closer and stiller.",
                                    "Ich kann keinen Text lesen. Bitte noch einmal fotografieren, etwas näher und ruhiger.")
        error = hint
        Speaker.shared.say(hint)
    }

    private func share(_ text: String, to c: EmergencyContact) {
        let body = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "sms:\(c.phone)&body=\(body)") { openURL(url) }
    }
}

extension UIImage {
    func resizedForUpload(maxSide: CGFloat = 1600) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return self }
        let s = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: s).image { _ in draw(in: CGRect(origin: .zero, size: s)) }
    }
}

/// Camera on a device, photo library in the simulator.
struct CameraPicker: UIViewControllerRepresentable {
    var library = false
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = !library && UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(_ d: @escaping (UIImage?) -> Void) { done = d }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}
