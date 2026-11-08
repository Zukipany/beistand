import SwiftUI

@main
struct BeistandApp: App {
    @State private var store = AppStore.shared
    @State private var safety = SafetyService.shared
    @State private var guide = GuideController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(safety)
                .environment(guide)
                .dynamicTypeSize(.large ... .accessibility5)
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(SafetyService.self) private var safety
    @Environment(GuideController.self) private var guide

    var body: some View {
        @Bindable var guide = guide
        ZStack {
            if store.profile == nil {
                OnboardingView()
            } else {
                HomeView()
            }
            if safety.dropFinderActive {
                DroppedPhoneView()
            } else if let inc = safety.incident {
                IncidentView(incident: inc)
            }
        }
        .fullScreenCover(isPresented: $guide.requestedOpen) { ImLostView() }
        // A setting switched on in iOS (e.g. VoiceOver) while the app was away adds its mode.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            SystemAccessibility.applyNewSettings(to: store)
        }
        .onAppear {
            VolumeMonitor.shared.start()
            if store.profile != nil { safety.startMonitoring() }
            #if DEBUG
            // Test hook: launch with `-openGuide YES -guideDestination Odeonsplatz`.
            let d = UserDefaults.standard
            if d.bool(forKey: "openGuide") {
                guide.requestedOpen = true
                if let dest = d.string(forKey: "guideDestination") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { GuideController.shared.go(to: dest) }
                }
            }
            #endif
        }
    }
}
