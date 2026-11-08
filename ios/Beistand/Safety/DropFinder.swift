import AVFoundation
import UIKit

/// A dropped phone calls out with sound and light: loud rising tone, "Ich bin hier",
/// white screen and a slow torch pulse (≤ 1 per second; steady in seizure mode).
final class DropFinder {
    private var timer: Timer?
    private var tick = 0
    var seizureSafe = false

    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        UIScreen.main.brightness = 1.0
        tick = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.step() }
        step()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        Tone.stop()
        Speaker.shared.stop()
        torch(false)
    }

    private func step() {
        tick += 1
        // Torch: on/off once per second (0.5 Hz on-cycle), never faster. Seizure mode: steady on.
        torch(seizureSafe ? true : tick % 2 == 0)
        if tick % 5 == 1 {
            Speaker.shared.say(tr("I'm here.", "Ich bin hier."), interrupt: false)
        } else {
            Tone.play(hz: 880, seconds: 0.8, rising: true, volume: 1.0)
        }
    }

    private func torch(_ on: Bool) {
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { return }
        try? d.lockForConfiguration()
        d.torchMode = on ? .on : .off
        d.unlockForConfiguration()
    }
}
