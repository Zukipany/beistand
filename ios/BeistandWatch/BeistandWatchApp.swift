import SwiftUI
import WatchKit

/// Starts the phone link at launch and completes the background wake-ups watchOS sends
/// when phone data arrives; without this, data that arrives while the app sleeps is dropped.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() { WatchModel.shared.start() }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let wc = task as? WKWatchConnectivityRefreshBackgroundTask {
                WatchModel.shared.start()
                WatchModel.shared.complete(wc)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

@main
struct BeistandWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @State private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchRoot().environment(model)
                .onAppear { model.start() }
        }
    }
}

struct WatchRoot: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        if let k = model.recentSound, model.state.incident == "none" || model.state.incident == "resolved" {
            SoundCard(kind: k)
        } else {
            main
        }
    }

    @ViewBuilder private var main: some View {
        switch model.state.incident {
        case "asking": AskingView()
        case "contacting", "contact_responding", "emergency_confirmed": HelpComingView()
        default:
            if model.offlineFall != nil { OfflineFallView() } else { HelpButtonView() }
        }
    }
}

/// Hold for one second: shaking hands or a brush against a sleeve must not call for help.
struct HelpButtonView: View {
    @Environment(WatchModel.self) private var model
    @State private var pressing = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(.red)
                Circle().trim(from: 0, to: pressing ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: pressing ? 1 : 0.1), value: pressing)
                    .padding(4)
                VStack {
                    Text(tr("Help", "Hilfe")).font(.title2.bold())
                    Text(model.sentHelp == nil ? tr("hold", "halten") : tr("sent", "gesendet")).font(.caption2)
                }
            }
            .onLongPressGesture(minimumDuration: 1, pressing: { pressing = $0 }) { model.help() }
            .accessibilityLabel(tr("Help", "Hilfe"))
            .accessibilityHint(tr("Hold for one second. Calls your emergency contact.", "Eine Sekunde halten. Ruft Ihren Notfallkontakt."))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.help() }

            Label(model.phoneReachable ? tr("Fall detection on", "Sturzerkennung an") : tr("Phone not reachable", "Telefon nicht erreichbar"),
                  systemImage: model.phoneReachable ? "checkmark.shield" : "iphone.slash")
                .font(.caption2)
                .foregroundStyle(model.phoneReachable ? .green : .orange)
            #if DEBUG
            Button(tr("Test fall", "Sturz testen")) { model.simulateFall() }.font(.caption2).buttonStyle(.borderless)
            #endif
        }
    }
}

struct AskingView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ZStack {
            Color.yellow.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 8) {
                Text(tr("Are you OK?", "Ist alles in Ordnung?")).font(.headline).multilineTextAlignment(.center)
                Button { model.imOK() } label: {
                    Text(tr("I'm OK", "Mir geht es gut")).font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 60)
                }
                .tint(.green)
                Text(tr("Otherwise I'll call for help.", "Sonst rufe ich Hilfe.")).font(.caption2)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
        }
    }
}

struct HelpComingView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let s = model.state
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: s.incident == "contact_responding" ? "person.fill.checkmark" : "phone.arrow.up.right")
                    .font(.title)
                Text(title(s)).font(.headline).multilineTextAlignment(.center)
                if s.incident == "emergency_confirmed" {
                    Button(tr("Call 112", "112 anrufen")) { model.call("112") }.tint(.red)
                }
                Button(tr("I'm OK", "Mir geht es gut")) { model.imOK() }.tint(.green)
            }
        }
    }

    private func title(_ s: WatchState) -> String {
        switch s.incident {
        case "contact_responding": tr("\(s.ackedBy ?? "Your contact") is taking care of you.", "\(s.ackedBy ?? "Ihr Kontakt") kümmert sich um Sie.")
        case "emergency_confirmed": tr("Emergency call needed.", "Notruf nötig.")
        default: tr("Help is coming. Calling \(s.contactName ?? "your contact").", "Hilfe kommt. \(s.contactName ?? "Ihr Kontakt") wird angerufen.")
        }
    }
}

/// Wrist fall while the phone is out of reach: the watch cannot run the help ladder
/// on its own, so it offers the calls directly.
struct OfflineFallView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(tr("Did you fall?", "Sind Sie gestürzt?")).font(.headline)
                Button(tr("I'm OK", "Mir geht es gut")) { model.imOK() }.tint(.green)
                if let n = model.state.contactPhone {
                    Button(tr("Call \(model.state.contactName ?? "contact")", "\(model.state.contactName ?? "Kontakt") anrufen")) { model.call(n) }.tint(.orange)
                }
                Button(tr("Call 112", "112 anrufen")) { model.call("112") }.tint(.red)
            }
        }
    }
}

/// A sound the phone heard, big enough to read at a glance. Tap to dismiss.
struct SoundCard: View {
    @Environment(WatchModel.self) private var model
    let kind: SoundKind
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: kind.icon).font(.system(size: 44))
            Text(kind.name).font(.title3.bold()).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((kind.urgent ? Color.red : Color.indigo).opacity(0.6).ignoresSafeArea())
        .onTapGesture { model.recentSound = nil }
        .accessibilityElement(children: .combine)
    }
}
