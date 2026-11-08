import SwiftUI

/// "Are you OK?" countdown, then the bystander card while help is on the way.
struct IncidentView: View {
    let incident: API.Incident
    @Environment(SafetyService.self) private var safety
    @Environment(AppStore.self) private var store
    @State private var now = Date()
    @State private var pulse = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        FitScroll {
        VStack(spacing: 20) {
            VolumeBanner()
            switch incident.state {
            case "asking":
                Text(tr("Are you OK?", "Ist alles in Ordnung?")).scaledFont(44, weight: .heavy, maxFactor: 1.6).multilineTextAlignment(.center)
                if let d = incident.deadline {
                    Text("\(max(0, Int(d.timeIntervalSince(now)))) s").scaledFont(80, weight: .bold, maxFactor: 1.3).monospacedDigit()
                }
                BigButton(title: tr("I'm OK", "Mir geht es gut"), systemImage: "hand.thumbsup.fill", color: .green) { safety.imOK() }
                BigButton(title: tr("I need help", "Ich brauche Hilfe"), systemImage: "sos", color: .red) { safety.requestHelp() }
            case "emergency_confirmed":
                Text(tr("Emergency", "Notruf")).scaledFont(44, weight: .heavy, maxFactor: 1.6)
                BigButton(title: store.has(.hearing) ? tr("Text 112 with nora", "112 per nora schreiben") : tr("Call 112", "112 anrufen"),
                          systemImage: "phone.arrow.up.right.fill", color: .red) { safety.call112() }
                bystanderCard
                // A false alarm must always be cancellable.
                BigButton(title: tr("I'm OK", "Mir geht es gut"), systemImage: "hand.thumbsup.fill", color: .green) { safety.imOK() }
            case "resolved":
                Text(tr("All good.", "Alles gut.")).scaledFont(44, weight: .heavy, maxFactor: 1.6)
            default:
                Text(incident.acked_by.map { tr("\($0) is on it", "\($0) kümmert sich") } ?? tr("Calling for help", "Hilfe wird gerufen"))
                    .scaledFont(40, weight: .heavy, maxFactor: 1.6).multilineTextAlignment(.center)
                bystanderCard
                BigButton(title: tr("Need 112", "Notruf 112 nötig"), systemImage: "cross.case.fill", color: .red) { safety.confirmEmergency() }
                BigButton(title: tr("I'm OK", "Mir geht es gut"), systemImage: "hand.thumbsup.fill", color: .green) { safety.imOK() }
            }
        }
        .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZStack { Color(.systemBackground); background }.ignoresSafeArea())
        .onReceive(clock) { now = $0; pulse.toggle() }
    }

    /// Deaf users get a light signal. Seizure mode never flashes: steady colour only.
    private var background: Color {
        if incident.state == "asking", store.has(.hearing), !store.has(.seizure) {
            return pulse ? Color.yellow : Color(.systemBackground)  // 0.5 Hz, far under 3 flashes/s
        }
        return incident.state == "asking" ? Color.yellow.opacity(0.35) : Color.red.opacity(0.18)
    }

    private var bystanderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("For helpers", "Für Helfende")).font(.headline)
            Text(tr("\(store.profile?.name ?? "This person") may need help.", "\(store.profile?.name ?? "Diese Person") braucht vielleicht Hilfe.")).font(.title2.bold())
            if let c = store.profile?.contacts.first {
                Text(tr("Please call \(c.name): \(c.phone)", "Bitte rufen Sie \(c.name) an: \(c.phone)")).font(.title3)
            }
            if store.has(.seizure) {
                Text(tr("Seizure: time it, protect the head, don't hold them down. Longer than 5 minutes: call 112.",
                        "Krampfanfall: Zeit messen, Kopf schützen, nicht festhalten. Länger als 5 Minuten: 112.")).font(.title3)
            }
            if store.has(.dementia) {
                Text(tr("I have memory problems.", "Ich habe Gedächtnisprobleme.")).font(.title3)
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

/// Full white screen while the dropped phone calls out.
struct DroppedPhoneView: View {
    @Environment(SafetyService.self) private var safety
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "iphone.radiowaves.left.and.right").scaledFont(120, weight: .regular, maxFactor: 1)
            Text(tr("I'm here", "Ich bin hier")).scaledFont(54, weight: .heavy, maxFactor: 1.3)
            Spacer()
            BigButton(title: tr("Found it", "Gefunden"), systemImage: "checkmark", color: .green) { safety.stopDropFinder() }
        }
        .padding(20)
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
    }
}
