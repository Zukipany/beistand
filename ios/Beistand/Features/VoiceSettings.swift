import AVFoundation
import SwiftUI

/// Settings → Voice: choose a calm, natural voice for English and German, hear it first, set the pace.
struct VoiceSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var english: [AVSpeechSynthesisVoice] = []
    @State private var german: [AVSpeechSynthesisVoice] = []
    @State private var personalAllowed = false

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Picker(tr("Pace", "Tempo"), selection: $store.speechPace) {
                    ForEach(SpeechPace.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(tr("Calm speaks a little slower and lower, with a short pause between sentences.",
                        "Ruhig spricht etwas langsamer und tiefer, mit einer kurzen Pause zwischen den Sätzen."))
            }
            voiceSection(tr("English", "Englisch"), voices: english, chosen: store.voiceEN) { store.voiceEN = $0 }
            voiceSection("Deutsch", voices: german, chosen: store.voiceDE) { store.voiceDE = $0 }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Natural voices are free, but iPhone downloads them once:", "Natürliche Stimmen sind kostenlos, das iPhone lädt sie einmal:"))
                        .font(.headline)
                    Text(tr("Settings → Accessibility → Spoken Content → Voices → English or German → choose a voice marked Premium or Enhanced (for example Ava, Zoe, Evan, Anna, Petra) → download. Then come back here.",
                            "Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen → Deutsch oder Englisch → eine Stimme mit „Premium“ oder „Erweitert“ wählen (z. B. Anna, Petra, Ava, Zoe) → laden. Dann hierher zurückkommen."))
                        .font(.subheadline)
                }
                Button(tr("Open Settings", "Einstellungen öffnen")) {
                    if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                }
                if #available(iOS 17, *), !personalAllowed {
                    Button(tr("Use my own voice (Personal Voice)", "Meine eigene Stimme verwenden (Eigene Stimme)")) {
                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                            DispatchQueue.main.async { personalAllowed = status == .authorized; reload() }
                        }
                    }
                }
            } header: {
                Text(tr("Better voices", "Bessere Stimmen"))
            } footer: {
                Text(tr("Personal Voice is a voice you recorded yourself on the iPhone (Settings → Accessibility → Personal Voice). The app can then speak for you, for example in counter mode.",
                        "Eigene Stimme ist eine Stimme, die Sie selbst am iPhone aufgenommen haben (Einstellungen → Bedienungshilfen → Eigene Stimme). Die App kann dann für Sie sprechen, zum Beispiel im Schalter-Modus."))
            }
        }
        .navigationTitle(tr("Voice", "Stimme"))
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func voiceSection(_ title: String, voices: [AVSpeechSynthesisVoice], chosen: String?,
                              choose: @escaping (String?) -> Void) -> some View {
        Section(title) {
            Button { choose(nil) } label: {
                row(tr("Automatic: the best installed voice", "Automatisch: die beste installierte Stimme"), detail: nil, selected: chosen == nil)
            }
            ForEach(voices, id: \.identifier) { v in
                Button {
                    choose(v.identifier)
                    Speaker.shared.preview(v)
                } label: {
                    row("\(v.name)", detail: "\(Voices.qualityName(v)) · \(Locale.current.localizedString(forIdentifier: v.language) ?? v.language)",
                        selected: chosen == v.identifier, quality: v)
                }
                .swipeActions { Button(tr("Listen", "Anhören")) { Speaker.shared.preview(v) }.tint(.blue) }
            }
            if voices.allSatisfy({ Voices.rank($0.quality) == 1 }) {
                Text(tr("Only standard voices are installed. They sound robotic: download a Premium or Enhanced voice below.",
                        "Nur Standard-Stimmen sind installiert. Sie klingen roboterhaft: Laden Sie unten eine Premium- oder erweiterte Stimme."))
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func row(_ title: String, detail: String?, selected: Bool, quality: AVSpeechSynthesisVoice? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(selected ? .bold : .regular)).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let q = quality, Voices.rank(q.quality) >= 2 || Voices.personal(q) {
                Image(systemName: "sparkles").foregroundStyle(.purple).accessibilityLabel(Voices.qualityName(q))
            }
            if selected { Image(systemName: "checkmark").foregroundStyle(.blue).accessibilityLabel(tr("chosen", "gewählt")) }
        }
        .contentShape(Rectangle())
    }

    private func reload() {
        english = Voices.list(for: "en")
        german = Voices.list(for: "de")
        if #available(iOS 17, *) { personalAllowed = AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized }
        Speaker.shared.voicesChanged()
    }
}
