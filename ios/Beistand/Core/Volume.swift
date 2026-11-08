import AVFoundation
import Observation
import SwiftUI
import UIKit

/// iOS does not let an app raise the volume, so the app watches it and asks for more.
/// The silent switch does not matter: speech uses the play-and-record session, which ignores it.
@Observable
final class VolumeMonitor {
    static let shared = VolumeMonitor()
    /// Half volume: loud enough to hear speech outdoors with an average phone speaker.
    static let minimum: Float = 0.5

    private(set) var level: Float = 1
    var tooQuiet: Bool { level < Self.minimum }
    private var observation: NSKeyValueObservation?

    func start() {
        guard observation == nil else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(true)   // outputVolume only updates on an active session
        #if DEBUG
        // Simulator test hook: `-fakeVolume 0.2`. Raising the volume hardware button still updates it.
        // Launch arguments arrive as strings, so read through double(forKey:).
        if UserDefaults.standard.object(forKey: "fakeVolume") != nil {
            level = Float(UserDefaults.standard.double(forKey: "fakeVolume"))
        } else { level = s.outputVolume }
        #else
        level = s.outputVolume
        #endif
        observation = s.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let v = change.newValue else { return }
            DispatchQueue.main.async { self?.level = v }
        }
    }

    #if DEBUG
    func simulate(_ v: Float) { level = v }
    #endif
}

/// Shown while the phone is too quiet. Not shown to people who chose hearing mode.
struct VolumeBanner: View {
    @Environment(AppStore.self) private var store
    private var volume = VolumeMonitor.shared

    var body: some View {
        if volume.tooQuiet && !store.has(.hearing) && !store.has(.deafblind) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "speaker.wave.1.fill").font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Your phone is quiet", "Ihr Telefon ist leise")).font(.title3.bold())
                    Text(tr("Press the volume-up button on the left side until this goes away.",
                            "Drücken Sie die Lauter-Taste links am Telefon, bis dieser Hinweis verschwindet."))
                        .font(.body)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding()
            .foregroundStyle(.black)
            .background(Color.yellow, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
            .onAppear {
                UIAccessibility.post(notification: .announcement,
                                     argument: tr("Your phone is quiet. Press the volume-up button.",
                                                  "Ihr Telefon ist leise. Drücken Sie die Lauter-Taste."))
            }
        }
    }
}
