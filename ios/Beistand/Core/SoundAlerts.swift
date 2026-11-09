import AVFoundation
import Observation
import SoundAnalysis
import UIKit

/// Runs Apple's sound classifier on audio buffers. Whoever owns the microphone feeds it
/// (the sound alerts screen, or live captions), so there is only ever one microphone tap.
final class SoundClassifier: NSObject, SNResultsObserving {
    private let analyzer: SNAudioStreamAnalyzer
    private let queue = DispatchQueue(label: "beistand.sound", qos: .userInitiated)
    private var policy = SoundAlertPolicy()
    private var frames: AVAudioFramePosition = 0
    var onAlert: ((SoundKind) -> Void)?

    init?(format: AVAudioFormat) {
        analyzer = SNAudioStreamAnalyzer(format: format)
        super.init()
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        request.overlapFactor = 0.5
        do { try analyzer.add(request, withObserver: self) } catch { return nil }
    }

    /// Call from the microphone tap.
    func analyze(_ buffer: AVAudioPCMBuffer) {
        let position = frames
        frames += AVAudioFramePosition(buffer.frameLength)
        queue.async { [analyzer] in analyzer.analyze(buffer, atAudioFramePosition: position) }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let labels = r.classifications.prefix(5).map { ($0.identifier, $0.confidence) }
        guard let kind = policy.feed(Array(labels), at: ProcessInfo.processInfo.systemUptime) else { return }
        DispatchQueue.main.async { self.onAlert?(kind) }
    }
}

/// Phone vibration per sound, so the type can be felt without looking. The watch uses the same
/// kinds (see WatchMessage.sound).
enum SoundHaptics {
    static func play(_ kind: SoundKind) {
        let n = UINotificationFeedbackGenerator()
        switch kind {
        case .siren, .alarm:
            for i in 0..<3 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { n.notificationOccurred(.error) } }
        case .horn:
            for i in 0..<2 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) { n.notificationOccurred(.warning) } }
        default:
            n.notificationOccurred(.success)
        }
    }
}

/// Listens for important sounds while its screen is open (and keeps listening in the background
/// while the app is in use). Alerts go to the screen, the phone's vibration and the watch.
@Observable
final class SoundWatcher {
    struct Alert: Identifiable, Equatable {
        let id = UUID()
        let kind: SoundKind
        let at: Date
    }

    private(set) var alerts: [Alert] = []
    private(set) var listening = false
    private(set) var problem: String?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var classifier: SoundClassifier?

    func start() {
        guard !listening else { return }
        Task { @MainActor in
            guard await AVAudioApplication.requestRecordPermission() else {
                problem = tr("Please allow the microphone in Settings.", "Bitte erlauben Sie das Mikrofon in den Einstellungen.")
                return
            }
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
            try? s.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, let c = SoundClassifier(format: format) else {
                problem = tr("Sound recognition is not available on this device.", "Geräuscherkennung ist auf diesem Gerät nicht verfügbar.")
                return
            }
            c.onAlert = { [weak self] kind in self?.raise(kind) }
            classifier = c
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 8192, format: format) { buf, _ in c.analyze(buf) }
            do { try engine.start() } catch {
                problem = tr("The microphone is busy.", "Das Mikrofon ist belegt.")
                return
            }
            listening = true
            problem = nil
        }
    }

    func stop() {
        guard listening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        classifier = nil
        listening = false
    }

    func raise(_ kind: SoundKind) {
        alerts.insert(Alert(kind: kind, at: Date()), at: 0)
        if alerts.count > 20 { alerts.removeLast() }
        SoundHaptics.play(kind)
        WatchLink.shared.sound(kind)
        UIAccessibility.post(notification: .announcement, argument: kind.name)
    }

    #if DEBUG
    /// Simulator test: there is no real microphone input worth classifying.
    func simulate(_ kind: SoundKind) { raise(kind) }
    #endif
}
