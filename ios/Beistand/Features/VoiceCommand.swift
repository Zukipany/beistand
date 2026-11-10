import SwiftUI

/// "Speak" button: the whole app by voice. Asks "Yes?", listens until the person stops, says what it
/// understood and opens it. If it did not understand, it says what one can say.
@MainActor
@Observable
final class VoiceCommand {
    static let shared = VoiceCommand()
    private(set) var listening = false
    private(set) var heard = ""
    @ObservationIgnored private let listener = Listener()

    func listen() {
        guard !listening else { return }
        Task {
            guard await Listener.requestPermission() else {
                Speaker.shared.say(tr("Please allow the microphone and speech recognition in Settings.",
                                      "Bitte erlauben Sie Mikrofon und Spracherkennung in den Einstellungen."))
                return
            }
            Speaker.shared.say(tr("Yes?", "Ja?")) { [weak self] in
                Task { @MainActor in await self?.hear() }
            }
        }
    }

    private func hear() async {
        listening = true
        heard = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        listener.start()
        var last = "", stable = 0
        for _ in 0..<40 {                                  // up to 10 s; stop after ~1.5 s of no change
            try? await Task.sleep(for: .milliseconds(250))
            let t = listener.transcript
            heard = t
            if !t.isEmpty, t == last { stable += 1 } else { stable = 0; last = t }
            if stable >= 6 { break }
        }
        listener.stop()
        listening = false
        let said = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { Speaker.shared.say(tr("I didn't hear anything.", "Ich habe nichts gehört.")); return }
        run(said)
    }

    /// Also used by tests and the step-by-step story's "say it" button.
    func run(_ said: String) {
        heard = said
        guard let d = CommandParser.parse(said) else {
            Speaker.shared.say(tr("Sorry, I didn't understand. ", "Entschuldigung, das habe ich nicht verstanden. ") + CommandParser.examples)
            return
        }
        Speaker.shared.say(CommandParser.confirmation(d))
        AppRouter.shared.open(d)
    }
}

/// The round microphone button.
struct SpeakButton: View {
    let voice = VoiceCommand.shared
    var body: some View {
        Button { voice.listen() } label: {
            Image(systemName: voice.listening ? "waveform" : "mic.fill")
                .font(.title.bold())
                .symbolEffect(.variableColor.iterative, isActive: voice.listening)
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .surface(.indigo, cornerRadius: 32, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Speak", "Sprechen"))
        .accessibilityHint(CommandParser.examples)
    }
}
