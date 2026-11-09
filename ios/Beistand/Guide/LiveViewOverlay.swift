import SwiftUI

/// Street-view-like layer over the camera picture: a compass strip, named places floating in their
/// real direction, the destination pin, and boxes around what the phone recognises right now.
/// For sighted companions and people with low vision; blind people get the same as speech.
struct LiveViewOverlay: View {
    @Environment(GuideController.self) private var guide

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                recognitionBoxes(geo.size)
                if let h = guide.pose.heading, let here = here {
                    placeLabels(geo.size, heading: h, here: here)
                    destination(geo.size, heading: h, here: here)
                }
                VStack(spacing: 8) {
                    CompassStrip(heading: guide.pose.heading, destinationBearing: destinationBearing, exact: guide.pose.fromCamera)
                    if let hint = CameraAim.hint(pitch: guide.pose.pitch) {
                        Label(hint, systemImage: "iphone.gen3.radiowaves.left.and.right")
                            .font(.headline).padding(10)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 104)          // below the guide's status line
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)          // everything here is also spoken
    }

    private var here: Coord? {
        LocationService.shared.last.map { Coord(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
    }

    private var destinationBearing: Double? {
        guard let d = guide.destinationCoord, let here else { return nil }
        return Geo.bearing(here, d)
    }

    // MARK: places

    private func placeLabels(_ size: CGSize, heading: Double, here: Coord) -> some View {
        let fov = Orientation.fieldOfView
        let seen = Orientation.around(guide.landmarks, here: here, heading: heading)
            .filter { abs($0.relative) <= fov / 2 && !$0.landmark.isStreet }
            .prefix(8)
        let placed = LabelLayout.rows(Array(seen).map { size.width * (0.5 + $0.relative / fov) }, width: size.width)
        let street = Orientation.around(guide.landmarks, here: here, heading: heading, within: 30).first { $0.landmark.isStreet }
        return ZStack {
            ForEach(Array(seen.enumerated()), id: \.element.landmark.id) { i, s in
                if let row = placed[i] {
                    // Nearest first gets the lowest free row, like in a street-level picture.
                    PlaceTag(name: s.landmark.name, kind: s.landmark.kind, metres: Int(s.distance.rounded()))
                        .position(x: min(max(size.width * (0.5 + s.relative / fov), 90), size.width - 90),
                                  y: size.height * 0.58 - CGFloat(row) * 62)
                }
            }
            if let street {
                Label(street.landmark.name, systemImage: "signpost.right.fill")
                    .font(.headline).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color(red: 0.05, green: 0.35, blue: 0.75), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2))
                    .position(x: size.width / 2, y: size.height * 0.62)
            }
        }
    }

    @ViewBuilder
    private func destination(_ size: CGSize, heading: Double, here: Coord) -> some View {
        if let d = guide.destinationCoord {
            let rel = Orientation.relative(Geo.bearing(here, d), heading: heading)
            let metres = Int(Geo.distance(here, d).rounded())
            let name = guide.destination ?? tr("Destination", "Ziel")
            if abs(rel) <= Orientation.fieldOfView / 2 {
                VStack(spacing: 2) {
                    Text("\(name) · \(metres) m").font(.headline).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.red, in: Capsule())
                    Image(systemName: "mappin").font(.system(size: 54, weight: .bold)).foregroundStyle(.red)
                        .shadow(radius: 4)
                }
                .position(x: size.width * (0.5 + rel / Orientation.fieldOfView), y: size.height * 0.36)
            } else {
                // Off screen: an arrow at the edge telling which way to turn.
                Label("\(name) · \(metres) m", systemImage: rel < 0 ? "arrow.left.circle.fill" : "arrow.right.circle.fill")
                    .font(.title3.bold()).padding(10)
                    .background(.red, in: Capsule())
                    .position(x: rel < 0 ? 110 : size.width - 110, y: size.height * 0.36)
            }
        }
    }

    // MARK: live recognition

    private func recognitionBoxes(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(guide.liveObjects.enumerated()), id: \.offset) { _, o in
                if let b = o.box {
                    box(b, size, color: o.label == "person" ? .yellow : .cyan,
                        label: "\(ObjectAlerts.names[o.label].map { Lang.german ? $0.de : $0.en } ?? o.label) \(String(format: "%.1f", o.distance)) m")
                }
            }
            ForEach(guide.signs) { t in
                box(t.box, size, color: .green, label: t.text)
            }
        }
    }

    /// Vision box (normalised, origin bottom-left) → screen. The preview fills the screen, so this is close enough.
    private func box(_ b: CGRect, _ size: CGSize, color: Color, label: String) -> some View {
        let r = CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height, width: b.width * size.width, height: b.height * size.height)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 3)
                .frame(width: r.width, height: r.height)
            Text(label).font(.caption.bold()).foregroundStyle(.black).lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(color, in: RoundedRectangle(cornerRadius: 4))
                .offset(y: -20)
        }
        .frame(width: r.width, height: r.height, alignment: .topLeading)
        .position(x: r.midX, y: r.midY)
    }
}

/// Puts labels in rows so they don't cover each other. Pure, testable.
enum LabelLayout {
    /// For each label's x (in order of priority), the row it goes in, or nil if there is no room.
    static func rows(_ xs: [CGFloat], width: CGFloat, labelWidth: CGFloat = 170, maxRows: Int = 3) -> [Int?] {
        var used: [[CGFloat]] = Array(repeating: [], count: maxRows)
        return xs.map { raw in
            let x = min(max(raw, labelWidth / 2), width - labelWidth / 2)
            for r in 0..<maxRows where used[r].allSatisfy({ abs($0 - x) >= labelWidth }) {
                used[r].append(x)
                return r
            }
            return nil
        }
    }
}

/// A floating place name, like a label in a street-level map.
private struct PlaceTag: View {
    let name: String
    let kind: String
    let metres: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: Self.icon(kind)).font(.headline)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.subheadline.bold()).lineLimit(1)
                    Text(kind == name ? "\(metres) m" : "\(kind) · \(metres) m").font(.caption).opacity(0.85)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.8), lineWidth: 1))
            Rectangle().fill(.white.opacity(0.8)).frame(width: 2, height: 14)
        }
        .foregroundStyle(.white)
        .fixedSize()
    }

    static func icon(_ kind: String) -> String {
        let k = kind.lowercased()
        if k.contains("u-bahn") || k.contains("station") || k.contains("bahnhof") { return "tram.fill.tunnel" }
        if k.contains("stop") || k.contains("halte") { return "bus.fill" }
        if k.contains("pharm") || k.contains("apothe") { return "cross.case.fill" }
        if k.contains("café") || k.contains("cafe") { return "cup.and.saucer.fill" }
        if k.contains("restaurant") || k.contains("imbiss") || k.contains("food") { return "fork.knife" }
        if k.contains("bak") || k.contains("bäck") { return "birthday.cake.fill" }
        if k.contains("church") || k.contains("kirche") { return "building.columns.fill" }
        if k.contains("toilet") { return "toilet.fill" }
        if k.contains("bank") { return "banknote.fill" }
        if k.contains("sight") || k.contains("sehens") || k.contains("landmark") || k.contains("denkmal") { return "star.fill" }
        return "storefront.fill"
    }
}

/// Compass ribbon across the top: N, NE, E … slide past as the person turns; red tick = destination.
struct CompassStrip: View {
    let heading: Double?
    let destinationBearing: Double?
    var exact = false
    private let span = 120.0          // degrees shown across the strip

    var body: some View {
        GeometryReader { g in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.55))
                if let heading {
                    ForEach(0..<24, id: \.self) { i in
                        let deg = Double(i) * 15
                        let rel = Orientation.relative(deg, heading: heading)
                        if abs(rel) <= span / 2 {
                            VStack(spacing: 1) {
                                Rectangle().fill(.white).frame(width: i % 3 == 0 ? 2 : 1, height: i % 3 == 0 ? 12 : 7)
                                if i % 3 == 0 { Text(Self.label(deg)).font(.caption.bold()) }
                            }
                            .position(x: g.size.width * (0.5 + rel / span), y: 18)
                        }
                    }
                    if let b = destinationBearing {
                        let rel = Orientation.relative(b, heading: heading)
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.red).font(.title3)
                            .position(x: g.size.width * (0.5 + max(-span / 2, min(span / 2, rel)) / span), y: 36)
                    }
                    Triangle().fill(.yellow).frame(width: 12, height: 8).position(x: g.size.width / 2, y: 4)
                    Text("\(Int(heading.rounded()))°\(exact ? "" : " ~")").font(.caption2.monospacedDigit())
                        .position(x: g.size.width - 24, y: 38)
                } else {
                    Text(tr("Turning on the compass …", "Kompass startet …")).font(.caption)
                }
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
    }

    static func label(_ deg: Double) -> String {
        let en = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"], de = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        return (Lang.german ? de : en)[Int(deg / 45) % 8]
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.closeSubpath() }
    }
}
