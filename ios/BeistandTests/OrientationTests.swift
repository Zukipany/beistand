import ImageIO
import XCTest
@testable import Beistand

final class OrientationTests: XCTestCase {
    let here = Coord(lat: 48.1374, lon: 11.5755)
    // ~50 m north, ~30 m east, ~40 m south-west, and a street 20 m north running east-west
    lazy var marks: [Landmark] = [
        Landmark(name: "Rossmann", kind: "drugstore", lat: 48.13785, lon: 11.5755),
        Landmark(name: "U-Bahn entrance", kind: "U-Bahn entrance", lat: 48.1374, lon: 11.5759),
        Landmark(name: "Café Glockenspiel", kind: "café", lat: 48.13715, lon: 11.57515),
        Landmark(name: "Kaufingerstraße", kind: "street", lat: 48.13758, lon: 11.5755, street_bearing: 90),
    ]

    override func setUp() { Lang.override = "en" }
    override func tearDown() { Lang.override = nil }

    func testRelativeAndWords() {
        XCTAssertEqual(Orientation.relative(10, heading: 350), 20, accuracy: 0.001)
        XCTAssertEqual(Orientation.relative(350, heading: 10), -20, accuracy: 0.001)
        XCTAssertEqual(Orientation.words(0), "ahead")
        XCTAssertEqual(Orientation.words(25), "slightly right")
        XCTAssertEqual(Orientation.words(-90), "left")
        XCTAssertEqual(Orientation.words(170), "behind you")
        XCTAssertEqual(Orientation.clock(90), 3)
        XCTAssertEqual(Orientation.clock(-90), 9)
        XCTAssertEqual(Orientation.clock(0), 12)
    }

    func testInViewDependsOnHeading() {
        XCTAssertEqual(Orientation.inView(marks, here: here, heading: 0).map(\.landmark.name), ["Rossmann"])
        XCTAssertEqual(Orientation.inView(marks, here: here, heading: 90).map(\.landmark.name), ["U-Bahn entrance"])
        XCTAssertEqual(Orientation.inView(marks, here: here, heading: 225).map(\.landmark.name), ["Café Glockenspiel"])
    }

    func testSentenceNamesStreetAndPlaces() {
        let north = Orientation.sentence(heading: 0, here: here, landmarks: marks)
        XCTAssertTrue(north.hasPrefix("Facing north."), north)
        XCTAssertTrue(north.contains("Kaufingerstraße runs across in front of you"), north)
        XCTAssertTrue(north.contains("Ahead: Rossmann, drugstore, 50 metres"), north)
        let east = Orientation.sentence(heading: 90, here: here, landmarks: marks)
        XCTAssertTrue(east.contains("facing along Kaufingerstraße"), east)
        XCTAssertTrue(Orientation.sentence(heading: 135, here: here, landmarks: marks).contains("Nothing named"))
    }

    func testSignsMatchNearbyPlaces() {
        let m = Orientation.matchSigns(["ROSSMANN", "Ausgang", "GLOCKENSPIEL"], landmarks: marks)
        XCTAssertEqual(m.map(\.1.name), ["Rossmann", "Café Glockenspiel"])
        let s = Orientation.sentence(heading: 0, here: here, landmarks: marks, signs: ["ROSSMANN"])
        XCTAssertTrue(s.contains("I can read \"ROSSMANN\": that is Rossmann"), s)
        XCTAssertFalse(s.contains("Ahead: Rossmann"), "a place read from a sign is not said twice")
    }

    func testGroundingForTheAI() {
        let g = Orientation.grounding(marks, here: here, heading: 0)
        XCTAssertEqual(g.first, "Kaufingerstraße (street), 20 m ahead")
        XCTAssertTrue(g.contains("Rossmann (drugstore), 50 m ahead"))
    }

    func testSweepSpeaksAfterTurningAndHoldingStill() {
        var p = SweepPolicy()
        XCTAssertNil(p.feed(heading: 0, at: 0))
        XCTAssertEqual(p.feed(heading: 2, at: 0.7), 0)            // held still → speak
        XCTAssertNil(p.feed(heading: 3, at: 2))                    // same direction: quiet
        XCTAssertNil(p.feed(heading: 10, at: 3))                   // small turn
        XCTAssertNil(p.feed(heading: 10, at: 4))
        XCTAssertNil(p.feed(heading: 60, at: 5))                   // turning …
        XCTAssertNil(p.feed(heading: 90, at: 5.2))
        XCTAssertEqual(p.feed(heading: 92, at: 5.9), 90)           // … and stopped
    }

    func testPhoneHoldAndImageOrientation() {
        XCTAssertEqual(PhoneHold.from(gx: 0, gy: -1), .portrait)
        XCTAssertEqual(PhoneHold.from(gx: 0, gy: 1), .upsideDown)
        XCTAssertEqual(PhoneHold.from(gx: -0.9, gy: -0.2), .topLeft)
        XCTAssertEqual(PhoneHold.from(gx: 0.9, gy: 0.1), .topRight)
        XCTAssertEqual(PhoneHold.portrait.rawOrientation, .right)
        XCTAssertEqual(PhoneHold.topLeft.rawOrientation, .up)
        XCTAssertEqual(PhoneHold.portrait.portraitBufferOrientation, .up)
        // Portrait mapping is the one the obstacle code used before.
        let (u, v) = PhoneHold.rawPoint(.right, x: 0.2, y: 0.7)
        XCTAssertEqual(u, 0.3, accuracy: 1e-9); XCTAssertEqual(v, 0.8, accuracy: 1e-9)
        // Every mapping keeps the centre in the centre and stays inside the picture.
        for o: CGImagePropertyOrientation in [.up, .down, .left, .right] {
            let c = PhoneHold.rawPoint(o, x: 0.5, y: 0.5)
            XCTAssertEqual(c.u, 0.5, accuracy: 1e-9); XCTAssertEqual(c.v, 0.5, accuracy: 1e-9)
        }
    }

    func testAimHints() {
        XCTAssertEqual(CameraAim.pitch(gz: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(CameraAim.pitch(gz: -1), -90, accuracy: 1e-9)   // screen up → camera at the ground
        XCTAssertNotNil(CameraAim.hint(pitch: -70))
        XCTAssertNotNil(CameraAim.hint(pitch: 60))
        XCTAssertNil(CameraAim.hint(pitch: -10))
    }

    func testLabelsDoNotOverlap() {
        let rows = LabelLayout.rows([200, 250, 220, 600, 205], width: 800)
        XCTAssertEqual(rows, [0, 1, 2, 0, nil])          // three near the same spot stack, a fourth has no room
        XCTAssertEqual(Orientation.sentence(heading: 90, here: here, landmarks: marks).components(separatedBy: "U-Bahn entrance").count - 1, 1)
    }
}
