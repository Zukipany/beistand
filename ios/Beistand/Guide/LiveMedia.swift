import AVFoundation
import CoreImage
import UIKit

/// Microphone in (16 kHz PCM chunks) and guide voice out (24 kHz PCM), on one engine
/// with voice processing so the guide does not hear itself through the speaker.
final class LiveAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let inFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    var onChunk: ((Data) -> Void)?
    private(set) var running = false

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try s.setActive(true)

        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)   // echo cancellation; not available in every simulator
        let hw = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: hw, to: inFormat)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: hw) { [weak self] buf, _ in self?.convert(buf) }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        running = false
    }

    /// Guide audio: 16-bit little-endian PCM at 24 kHz.
    func play(_ pcm: Data) {
        let frames = pcm.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let dst = buf.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        player.scheduleBuffer(buf, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// The person started talking over the guide: drop what is queued.
    func flush() {
        player.stop()
        player.play()
    }

    private func convert(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = inFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        onChunk?(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
    }
}

/// Back camera at one JPEG per second (the most Gemini Live accepts), plus a preview layer.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "beistand.camera")
    private let ci = CIContext()
    private var lastSent = Date.distantPast
    var interval: TimeInterval = 1.0
    var onFrame: ((Data) -> Void)?
    private(set) var latestJPEG: Data?
    private(set) var available = false

    func start() {
        queue.async { [self] in
            if session.inputs.isEmpty {
                guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else { return }
                session.beginConfiguration()
                session.sessionPreset = .vga640x480
                session.addInput(input)
                let out = AVCaptureVideoDataOutput()
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(out) { session.addOutput(out) }
                out.connection(with: .video)?.videoRotationAngle = 90  // portrait
                session.commitConfiguration()
            }
            available = true
            session.startRunning()
        }
    }

    func stop() { queue.async { [self] in session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastSent) >= interval, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        lastSent = Date()
        let img = CIImage(cvPixelBuffer: px)
        guard let cg = ci.createCGImage(img, from: img.extent),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6) else { return }
        latestJPEG = jpeg
        onFrame?(jpeg)
    }
}

/// WebSocket to Gemini Live. Delivers parsed events on the main queue.
final class LiveClient {
    private var task: URLSessionWebSocketTask?
    var onEvent: ((LiveProtocol.Event) -> Void)?
    var onClose: ((String?) -> Void)?
    private var closed = false

    func connect(token: String, setup: Data) {
        closed = false
        let t = URLSession.shared.webSocketTask(with: LiveProtocol.url(token: token))
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        send(setup)
        receive(on: t)
    }

    func send(_ data: Data) {
        guard let task, !closed else { return }
        // The API takes JSON as text frames.
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self, weak task] err in
            if let err, let task { self?.finish(err.localizedDescription, from: task) }
        }
    }

    func close() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    /// Only the current connection may report events or a close: after a reconnect, the old
    /// connection's late failure must not trigger another reconnect.
    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure(let err):
                self.finish(err.localizedDescription, from: t)
            case .success(let msg):
                let data: Data
                switch msg {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                let events = LiveProtocol.parse(data)
                DispatchQueue.main.async { events.forEach { self.onEvent?($0) } }
                self.receive(on: t)
            }
        }
    }

    private func finish(_ reason: String?, from t: URLSessionWebSocketTask) {
        guard !closed, t === task else { return }
        closed = true
        let code = task?.closeCode
        let why = task?.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        DispatchQueue.main.async { self.onClose?(why ?? reason ?? "closed (\(code?.rawValue ?? 0))") }
    }
}
