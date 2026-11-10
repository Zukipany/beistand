import Foundation
import simd

/// Finds an open train door with LiDAR: standing on the platform, the train's side is a wall about a
/// metre or two away; an open door is a gap in that wall where the depth jumps into the carriage.
/// Pure, testable.
enum DoorFinder {
    static let columns = 13
    static let span: Float = 70           // degrees across the view that are scanned

    /// Nearest surface (metres) in each of `columns` directions across the view, at chest height.
    /// nil = nothing within 6 m in that direction.
    static func depths(points: [SIMD3<Float>], camera: SIMD3<Float>, forward: SIMD3<Float>, floorY: Float) -> [Float?] {
        var f = SIMD3<Float>(forward.x, 0, forward.z)
        guard simd_length(f) > 1e-3 else { return Array(repeating: nil, count: columns) }
        f = simd_normalize(f)
        let right = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
        var out = [Float?](repeating: nil, count: columns)
        for p in points {
            let h = p.y - floorY
            guard h > 0.7, h < 1.8 else { continue }            // above the gap and the floor, below the roof
            let rel = p - camera
            let ahead = simd_dot(rel, f)
            guard ahead > 0.2 else { continue }
            let side = simd_dot(rel, right)
            let angle = atan2(side, ahead) * 180 / .pi
            guard abs(angle) <= span / 2 else { continue }
            let i = min(columns - 1, max(0, Int((angle / span + 0.5) * Float(columns))))
            let d = (ahead * ahead + side * side).squareRoot()
            guard d < 6 else { continue }
            out[i] = min(out[i] ?? .infinity, d)
        }
        return out
    }

    struct Door: Equatable {
        let angle: Float        // degrees, negative = left
        let distance: Float     // metres to the doorway
    }

    /// The opening: two or more neighbouring columns at least `deeper` metres deeper than the wall
    /// around them (or open to 6 m), with wall on at least one side.
    static func find(_ depths: [Float?], deeper: Float = 0.9) -> Door? {
        let wall = depths.compactMap { $0 }.sorted()
        guard wall.count >= 4 else { return nil }
        let near = wall[wall.count / 3]                      // the train's side: the nearer third
        guard near < 4 else { return nil }
        let open = depths.map { ($0 ?? 6) >= near + deeper }
        var best: (start: Int, len: Int)?
        var i = 0
        while i < open.count {
            if open[i] {
                var j = i
                while j + 1 < open.count, open[j + 1] { j += 1 }
                let len = j - i + 1
                let walled = (i > 0 && !open[i - 1]) || (j < open.count - 1 && !open[j + 1])
                if len >= 2, len <= 6, walled, len > (best?.len ?? 0) { best = (i, len) }
                i = j + 1
            } else { i += 1 }
        }
        guard let b = best else { return nil }
        let centre = Float(b.start) + Float(b.len - 1) / 2
        let angle = (centre + 0.5) / Float(depths.count) * span - span / 2
        // The doorway is in line with the wall next to it.
        let edges = [b.start - 1, b.start + b.len].compactMap { $0 >= 0 && $0 < depths.count ? depths[$0] : nil }
        return Door(angle: angle, distance: edges.min() ?? near)
    }

    /// One short sentence to steer by.
    static func phrase(_ d: Door) -> String {
        let m = max(1, Int(d.distance.rounded()))
        if abs(d.angle) < 8, d.distance < 1.0 {
            return tr("Step in now. Mind the gap.", "Jetzt einsteigen. Vorsicht, Lücke.")
        }
        let dir = Orientation.words(Double(d.angle))
        return tr("Open door, \(dir), \(m) \(m == 1 ? "metre" : "metres").", "Offene Tür, \(dir), \(m) Meter.")
    }
}
