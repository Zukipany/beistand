import ARKit
import CoreImage
import SwiftUI
import UIKit
import Vision

/// The guide's camera. On phones with LiDAR it runs ARKit, so one camera feed gives:
/// pictures for the live guide (1 per second), obstacle lanes from depth (~10 per second) and
/// named objects with distances (~2 per second). Other phones use the plain camera, without depth.
final class GuideCamera: NSObject, ARSessionDelegate {
    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    // Outputs (called on the main queue).
    var onFrame: ((Data) -> Void)?
    var onZones: ((ObstacleZones) -> Void)?
    var onObjects: (([SeenObject]) -> Void)?
    private(set) var latestJPEG: Data?

    let fallback = CameraFeed()
    private(set) var arSession: ARSession?
    private let queue = DispatchQueue(label: "beistand.guidecamera", qos: .userInitiated)
    private let ci = CIContext()
    private var lastJPEG = Date.distantPast
    private var lastDepth = Date.distantPast
    private var lastObjects = Date.distantPast
    private var visionBusy = false
    private var floorY: Float?

    var usesLiDAR: Bool { arSession != nil }

    override init() {
        super.init()
        // Created up front, so the preview knows from the first draw which camera is used.
        if Self.hasLiDAR { arSession = ARSession() }
    }

    func start() {
        guard Self.hasLiDAR else {
            fallback.onFrame = { [weak self] jpeg in
                self?.latestJPEG = jpeg
                self?.onFrame?(jpeg)
            }
            fallback.start()
            return
        }
        let session = arSession ?? ARSession()
        session.delegate = self
        session.delegateQueue = queue
        arSession = session
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        config.planeDetection = [.horizontal]
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        arSession?.pause()
        fallback.stop()
        floorY = nil
    }

    // MARK: ARSessionDelegate (on `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = Date()
        if now.timeIntervalSince(lastDepth) >= 0.1 {
            lastDepth = now
            let zones = obstacleZones(frame)
            DispatchQueue.main.async { self.onZones?(zones) }
        }
        if now.timeIntervalSince(lastJPEG) >= 1 {
            lastJPEG = now
            if let jpeg = jpeg(frame.capturedImage) {
                DispatchQueue.main.async {
                    self.latestJPEG = jpeg
                    self.onFrame?(jpeg)
                }
            }
        }
        if now.timeIntervalSince(lastObjects) >= 0.5, !visionBusy {
            lastObjects = now
            visionBusy = true
            let objects = detectObjects(frame)
            visionBusy = false
            DispatchQueue.main.async { self.onObjects?(objects) }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updateFloor(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updateFloor(anchors) }

    /// The lowest horizontal plane is the ground (ARKit finds it within a few seconds of walking).
    private func updateFloor(_ anchors: [ARAnchor]) {
        for case let p as ARPlaneAnchor in anchors where p.alignment == .horizontal {
            let y = p.transform.columns.3.y
            if floorY == nil || y < floorY! { floorY = y }
        }
    }

    // MARK: depth → obstacle lanes

    private func obstacleZones(_ frame: ARFrame) -> ObstacleZones {
        guard let depth = frame.sceneDepth?.depthMap else { return ObstacleZones() }
        let confidence = frame.sceneDepth?.confidenceMap
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return ObstacleZones() }
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        let confBase = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRow = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        // Camera intrinsics are for the colour image; scale them to the depth image.
        let res = frame.camera.imageResolution
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        let k = frame.camera.intrinsics
        let fx = k[0][0] * sx, fy = k[1][1] * sy, cx = k[2][0] * sx, cy = k[2][1] * sy
        let t = frame.camera.transform
        let cam = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let floor = floorY ?? (cam.y - 1.3)            // until ARKit finds the ground: phone held at chest height

        var points: [SIMD3<Float>] = []
        points.reserveCapacity((w / 4) * (h / 4))
        for v in stride(from: 0, to: h, by: 4) {
            let row = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float32.self)
            let conf = confBase?.advanced(by: v * confRow).assumingMemoryBound(to: UInt8.self)
            for u in stride(from: 0, to: w, by: 4) {
                if let conf, conf[u] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let d = row[u]
                guard d.isFinite, d > 0.15, d < 5.5 else { continue }
                points.append(ObstacleGeometry.worldPoint(u: Float(u), v: Float(v), depth: d,
                                                          fx: fx, fy: fy, cx: cx, cy: cy, cameraTransform: t))
            }
        }
        return ObstacleGeometry.zones(points: points, camera: cam, forward: forward, floorY: floor)
    }

    /// Depth (metres) at a normalised point of the depth image.
    private func depthAt(_ frame: ARFrame, u: CGFloat, v: CGFloat) -> Float? {
        guard let depth = frame.sceneDepth?.depthMap else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let x = min(w - 1, max(0, Int(u * CGFloat(w)))), y = min(h - 1, max(0, Int(v * CGFloat(h))))
        let d = base.advanced(by: y * CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float32.self)[x]
        return d.isFinite && d > 0 ? d : nil
    }

    // MARK: objects (Apple Vision, on the phone)

    /// People and the most prominent objects, named by Apple's image classifier, with LiDAR distance.
    private func detectObjects(_ frame: ARFrame) -> [SeenObject] {
        let image = frame.capturedImage
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .right)   // phone held upright
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let salient = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? handler.perform([humans, salient])

        var out: [SeenObject] = []
        func add(_ label: String, _ box: CGRect) {
            // Vision boxes: portrait image, origin bottom-left. Depth image: sensor landscape, origin top-left.
            let u = 1 - box.midY, v = 1 - box.midX
            guard let d = depthAt(frame, u: u, v: v) else { return }
            let side: SeenObject.Side = box.midX < 0.35 ? .left : box.midX > 0.65 ? .right : .ahead
            out.append(SeenObject(label: label, distance: d, side: side))
        }
        for h in humans.results ?? [] where h.confidence > 0.5 { add("person", h.boundingBox) }

        let boxes = (salient.results?.first?.salientObjects ?? []).prefix(3)
        for obj in boxes where obj.boundingBox.width * obj.boundingBox.height > 0.02 {
            let classify = VNClassifyImageRequest()
            classify.regionOfInterest = obj.boundingBox
            try? handler.perform([classify])
            let label = (classify.results ?? [])
                .prefix(5)
                .filter { $0.confidence > 0.2 }
                .compactMap { ObjectAlerts.normalise($0.identifier) }
                .first { $0 != "person" }                      // people come from the human detector
            add(label ?? "obstacle", obj.boundingBox)
        }
        return out
    }

    // MARK: pictures for the guide

    private func jpeg(_ pixels: CVPixelBuffer) -> Data? {
        var img = CIImage(cvPixelBuffer: pixels).oriented(.right)
        let scale = 768 / max(img.extent.width, img.extent.height)
        if scale < 1 { img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cg = ci.createCGImage(img, from: img.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)
    }
}

/// Live camera picture behind the guide's controls, for sighted helpers.
struct GuideCameraPreview: View {
    let camera: GuideCamera
    var body: some View {
        if let session = camera.arSession {
            ARPreview(session: session)
        } else {
            CameraPreview(session: camera.fallback.session)
        }
    }
}

struct ARPreview: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = false
        return v
    }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}
