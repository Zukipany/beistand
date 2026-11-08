import SwiftUI

/// Paste a strange message or describe a call; hear a plain warning. Never says "safe".
struct ScamCheckView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var verdict: API.ScamVerdict?
    @State private var busy = false
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 16) {
                Text(tr("Paste the message or describe the call.", "Fügen Sie die Nachricht ein oder beschreiben Sie den Anruf.")).font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextEditor(text: $text).font(.title3).frame(minHeight: 160).focused($editing)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary))
                HStack {
                    Button { text = UIPasteboard.general.string ?? text } label: {
                        Label(tr("Paste", "Einfügen"), systemImage: "doc.on.clipboard").font(.title3)
                    }
                    Spacer()
                }
                BigButton(title: busy ? tr("Checking …", "Prüfe …") : tr("Check", "Prüfen"), systemImage: "checkmark.shield", color: .orange) { check() }
                    .disabled(text.isEmpty || busy)
                if let v = verdict {
                    Text(v.spoken).font(.title2.bold())
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(color(v.level).opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(tr("Is this a scam?", "Ist das Betrug?"))
            .toolbar { Button(tr("Close", "Schließen")) { dismiss() } }
        }
    }

    private func color(_ level: String) -> Color { level == "likely_scam" ? .red : level == "suspicious" ? .orange : .gray }

    private func check() {
        editing = false
        busy = true
        Task {
            defer { busy = false }
            do {
                let v = try await API.shared.scamCheck(text, lang: Lang.code)
                verdict = v
                Speaker.shared.say(v.spoken)
            } catch {
                Speaker.shared.say(tr("I couldn't check that right now. Don't pay anything before you've asked someone.",
                                      "Ich konnte das gerade nicht prüfen. Zahlen Sie nichts, bevor Sie jemanden gefragt haben."))
            }
        }
    }
}
