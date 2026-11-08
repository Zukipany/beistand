import SwiftUI
import Vision
import UIKit

/// Large text read aloud with the current word highlighted, so people who read slowly
/// (or see little) can follow along. Tap to stop or start again.
struct ReadAloudText: View {
    let text: String
    var autoplay = true
    @State private var current: NSRange?
    @State private var speaking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(highlighted)
                .font(.title2)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
            BigButton(title: speaking ? tr("Stop", "Stopp") : tr("Read it again", "Nochmal vorlesen"),
                      systemImage: speaking ? "stop.fill" : "speaker.wave.2.fill") {
                speaking ? stop() : play()
            }
        }
        .onAppear { if autoplay { play() } }
        .onDisappear { stop() }
        .onChange(of: text) { _, _ in if autoplay { play() } }
    }

    private var highlighted: AttributedString {
        guard let r = current, let range = Range(r, in: text) else { return AttributedString(text) }
        var word = AttributedString(text[range])
        word.backgroundColor = .yellow
        word.foregroundColor = .black
        return AttributedString(text[..<range.lowerBound]) + word + AttributedString(text[range.upperBound...])
    }

    private func play() {
        speaking = true
        Speaker.shared.say(text, word: { current = $0 }) {
            speaking = false
            current = nil
        }
    }

    private func stop() {
        Speaker.shared.stop()
        speaking = false
        current = nil
    }
}

/// On-device text recognition (Apple Vision). Works offline and needs no key, so "Read this"
/// still helps when the server's language model is not available. It reads the text as it is;
/// only the server can rewrite it in simple words.
enum OnDeviceReader {
    struct Result: Equatable {
        var text: String
        var amount: String?
        var deadline: String?
    }

    static func read(_ image: UIImage) async -> Result? {
        guard let cg = image.cgImage else { return nil }
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: text.isEmpty ? nil : extract(text))
            }
            req.recognitionLevel = .accurate
            req.recognitionLanguages = Lang.german ? ["de-DE", "en-US"] : ["en-US", "de-DE"]
            req.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg, orientation: image.cgOrientation).perform([req]) }
                catch { cont.resume(returning: nil) }
            }
        }
    }

    /// Pure, so it is testable: the first money amount and the first date in the text.
    static func extract(_ text: String) -> Result {
        func first(_ pattern: String) -> String? {
            guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
        let amount = first(#"(€|EUR|£|\$)\s?\d{1,3}([.,\s]\d{3})*([.,]\d{2})?|\d{1,3}([.\s]\d{3})*(,\d{2})?\s?(€|EUR|Euro)|\d{1,3}(,\d{3})*(\.\d{2})?\s?(€|EUR|GBP|USD)"#)
        let months = "January|February|March|April|May|June|July|August|September|October|November|December|Januar|Februar|März|Mai|Juni|Juli|Oktober|Dezember"
        let deadline = first(#"\b\d{1,2}\.\s?\d{1,2}\.\s?\d{2,4}\b"#)
            ?? first(#"\b\d{1,2}\.?\s(\#(months))\s\d{4}\b"#)
            ?? first(#"\b(\#(months))\s\d{1,2},?\s\d{4}\b"#)
            ?? first(#"\b\d{4}-\d{2}-\d{2}\b"#)
            ?? first(#"\b(0[1-9]|1[0-2])[./]\d{4}\b"#)       // "best before 03.2028"
        return Result(text: text, amount: amount, deadline: deadline)
    }

    /// What is spoken when only the phone read the text.
    static func spoken(_ r: Result, maxChars: Int = 900) -> String {
        var parts: [String] = []
        if let d = r.deadline { parts.append(tr("I found a date: \(d).", "Ich habe ein Datum gefunden: \(d).")) }
        if let a = r.amount { parts.append(tr("I found an amount: \(a).", "Ich habe einen Betrag gefunden: \(a).")) }
        parts.append(tr("Here is the text:", "Hier ist der Text:"))
        let body = r.text.replacingOccurrences(of: "\n", with: " ")
        parts.append(body.count > maxChars ? String(body.prefix(maxChars)) + " …" : body)
        return parts.joined(separator: " ")
    }
}

extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
