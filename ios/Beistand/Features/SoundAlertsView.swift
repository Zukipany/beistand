import SwiftUI

/// Hearing mode: important sounds around the person become a big named card, a vibration,
/// a slow colour pulse (steady in seizure mode) and a tap on the watch.
struct SoundAlertsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var watcher = SoundWatcher()
    @State private var pulse = false
    @State private var flashUntil = Date.distantPast
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(tr("Sound alerts", "Geräusch-Alarme"), systemImage: "ear.badge.waveform").font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
                .accessibilityLabel(tr("Close", "Schließen"))
            }
            Text(watcher.problem ?? (watcher.listening
                 ? tr("Listening for sirens, alarms, horns, the doorbell, knocking, a baby, a dog and shouting.",
                      "Achtet auf Sirenen, Alarme, Hupen, Türklingel, Klopfen, Baby, Hund und Rufen.")
                 : tr("Starting …", "Starte …")))
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let latest = watcher.alerts.first {
                VStack(spacing: 10) {
                    Image(systemName: latest.kind.icon).font(.system(size: 72))
                    Text(latest.kind.name).scaledFont(40, weight: .heavy).multilineTextAlignment(.center)
                    Text(latest.at, style: .relative).font(.title3) + Text(tr(" ago", " her")).font(.title3)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .foregroundStyle(.white)
                .background(A11yColor.fill(latest.kind.urgent ? .red : .indigo), in: RoundedRectangle(cornerRadius: 24))
                .accessibilityElement(children: .combine)
            } else {
                ContentUnavailableView(tr("Nothing yet", "Noch nichts"), systemImage: "ear",
                                       description: Text(tr("Important sounds will appear here.", "Wichtige Geräusche erscheinen hier.")))
            }

            List(watcher.alerts.dropFirst()) { a in
                HStack {
                    Image(systemName: a.kind.icon)
                    Text(a.kind.name)
                    Spacer()
                    Text(a.at, style: .time).foregroundStyle(.secondary)
                }
                .font(.title3)
            }
            .listStyle(.plain)

            #if DEBUG
            Menu(tr("Test a sound", "Geräusch testen")) {
                ForEach(SoundKind.allCases, id: \.self) { k in Button(k.name) { watcher.simulate(k) } }
            }
            #endif
        }
        .padding()
        .background(background.ignoresSafeArea())
        .onAppear {
            watcher.start()
            #if DEBUG
            // Test hook: `-testSound siren` raises that alert 2 s after opening.
            if let k = UserDefaults.standard.string(forKey: "testSound").flatMap(SoundKind.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { watcher.simulate(k) }
            }
            #endif
        }
        .onDisappear { watcher.stop() }
        .onChange(of: watcher.alerts.first?.id) { _, _ in flashUntil = Date().addingTimeInterval(4) }
        .onReceive(clock) { _ in pulse.toggle() }
    }

    /// Once per second at most (well under the 3 flashes per second safety limit); seizure mode: steady.
    private var background: Color {
        guard Date() < flashUntil, let k = watcher.alerts.first?.kind else { return Color(.systemBackground) }
        let c: Color = k.urgent ? .red : .yellow
        if store.has(.seizure) { return c.opacity(0.35) }
        return pulse ? c.opacity(0.5) : Color(.systemBackground)
    }
}
