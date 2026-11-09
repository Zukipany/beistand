import SwiftUI
import Translation

/// Counter mode for deaf and hard-of-hearing people: at a pharmacy or office counter the phone lies
/// flat between two people. The top half is upside down for the staff member and shows what the
/// person typed (translated, if the staff member speaks another language). The bottom half shows
/// live captions of what the staff member says.
struct CounterModeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var captioner = LiveCaptioner()
    @State private var message = ""
    @State private var shown = ""                    // what the staff side shows now
    @State private var shownTranslated: String?
    @State private var toStaff: ((String) async -> String?)?
    @FocusState private var typing: Bool

    static var phrases: [String] {[
        tr("I am deaf. Please speak clearly towards the phone.", "Ich bin gehörlos. Bitte sprechen Sie deutlich zum Telefon."),
        tr("Please write it down.", "Bitte schreiben Sie es auf."),
        tr("Can you repeat that, please?", "Können Sie das bitte wiederholen?"),
        tr("Thank you!", "Vielen Dank!"),
    ]}

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                staffSide
                    .frame(height: geo.size.height * 0.42)
                    .rotationEffect(.degrees(180))
                Divider().overlay(Color.primary)
                personSide
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { captioner.start() }
        .onDisappear { captioner.stop() }
    }

    // MARK: staff (upside down)

    private var staffSide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(staffHint).font(.headline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(shownTranslated ?? (shown.isEmpty ? "…" : shown))
                    .scaledFont(34, weight: .bold, relativeTo: .title, maxFactor: 1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if shownTranslated != nil {
                    Text(shown).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(Color.yellow.opacity(0.18))
        .accessibilityElement(children: .combine)
    }

    /// In the staff member's language when one is chosen, else the app's.
    private var staffHint: String {
        captioner.speaker.isMine
            ? tr("Please speak normally. Your words appear as text on the other side.",
                 "Bitte sprechen Sie normal. Ihre Worte erscheinen als Text auf der anderen Seite.")
            : "🗣 → 📱"
    }

    // MARK: person

    private var personSide: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    ForEach(SpeakerLanguage.all) { l in Button(l.name) { chooseStaffLanguage(l) } }
                } label: {
                    Label(tr("Staff speak: \(captioner.speaker.name)", "Personal spricht: \(captioner.speaker.name)"),
                          systemImage: "globe").font(.headline)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.secondary)
                }
                .accessibilityLabel(tr("Close", "Schließen"))
            }
            // What the staff member said: newest at the bottom, translated if a language was chosen.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(captioner.lines.suffix(6)) { line in
                            Text(line.translation ?? line.text)
                                .font(.system(size: Loudness.fontSize(line.db, min: 20, max: 44), weight: Loudness.weight(line.db)))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !captioner.current.isEmpty {
                            Text(captioner.current.map(\.text).joined(separator: " ")).font(.title2).foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: captioner.lines.count) { _, _ in proxy.scrollTo("end") }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Self.phrases, id: \.self) { p in
                        Button(p) { send(p) }.buttonStyle(.bordered).font(.callout)
                    }
                }
            }
            HStack {
                TextField(tr("Type what you want to say", "Tippen Sie, was Sie sagen möchten"), text: $message, axis: .vertical)
                    .font(.title3).lineLimit(1...3).textFieldStyle(.roundedBorder).focused($typing)
                    .onSubmit { send(message) }
                Button { send(message) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 40))
                }
                .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel(tr("Show and say it", "Zeigen und vorlesen"))
            }
        }
        .padding()
    }

    // MARK: actions

    /// Shows the text on the staff side and says it aloud, in the staff member's language when translated.
    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        shown = t
        shownTranslated = nil
        message = ""
        typing = false
        let staff = captioner.speaker
        Task {
            if let toStaff, let out = await toStaff(t) {
                shownTranslated = out
                Speaker.shared.say(out, language: staff.id)
            } else {
                Speaker.shared.say(t)
            }
        }
    }

    private func chooseStaffLanguage(_ l: SpeakerLanguage) {
        captioner.stop()
        captioner.speaker = l
        captioner.translate = nil
        toStaff = nil
        Task {
            if !l.isMine, #available(iOS 26, *) {
                let avail = LanguageAvailability()
                // Their speech → my language (captions), my text → their language (staff side).
                if await avail.status(from: l.language, to: Lang.locale.language) == .installed {
                    let incoming = TranslationSession(installedSource: l.language, target: Lang.locale.language)
                    captioner.translate = { try? await incoming.translate($0).targetText }
                }
                if await avail.status(from: Lang.locale.language, to: l.language) == .installed {
                    let outgoing = TranslationSession(installedSource: Lang.locale.language, target: l.language)
                    toStaff = { try? await outgoing.translate($0).targetText }
                }
            }
            captioner.start()
        }
    }
}
