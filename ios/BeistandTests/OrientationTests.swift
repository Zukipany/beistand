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

final class CalmTests: XCTestCase {
    let here = Coord(lat: 48.1374, lon: 11.5755)
    override func setUp() { Lang.override = "en" }
    override func tearDown() { Lang.override = nil }

    func testCalmWarningsOnlyForThingsInTheWay() {
        var a = ObjectAlerts.calm
        XCTAssertNil(a.feed([SeenObject(label: "bench", distance: 1.5, side: .right)], at: 0))      // at the side
        XCTAssertNil(a.feed([SeenObject(label: "person", distance: 1.8, side: .ahead)], at: 5))    // walking past
        XCTAssertNil(a.feed([SeenObject(label: "bicycle", distance: 3, side: .ahead)], at: 10))    // not close yet
        XCTAssertEqual(a.feed([SeenObject(label: "bicycle", distance: 1.6, side: .ahead)], at: 15), "Bike, 2 metres, ahead.")
    }

    func testShortSentenceNamesOneThingTransportFirst() {
        let marks = [
            Landmark(name: "Rossmann", kind: "drugstore", lat: 48.13760, lon: 11.5755),
            Landmark(name: "U-Bahn entrance", kind: "U-Bahn entrance", lat: 48.13790, lon: 11.57555),
            Landmark(name: "Kaufingerstraße", kind: "street", lat: 48.13745, lon: 11.5755, street_bearing: 0),
        ]
        let s = Orientation.shortSentence(heading: 0, here: here, landmarks: marks)
        XCTAssertEqual(s, "Facing north, on Kaufingerstraße. Ahead: U-Bahn entrance, 56 metres.")
        XCTAssertEqual(Orientation.nearestEntrance(marks, here: here)?.name, "U-Bahn entrance")
    }

    func testHomingOnlySpeaksWhenSomethingChanged() {
        var h = HomingPolicy()
        let goal = Coord(lat: 48.1378, lon: 11.5755)                                         // ~44 m north
        XCTAssertEqual(h.feed(here: here, heading: 0, goal: goal, name: "Entrance", at: 0), "Entrance, 44 metres, ahead.")
        XCTAssertNil(h.feed(here: here, heading: 5, goal: goal, name: "Entrance", at: 10))      // nothing new
        XCTAssertEqual(h.feed(here: here, heading: 60, goal: goal, name: "Entrance", at: 20), "Entrance, 44 metres, left.")
        XCTAssertNil(h.feed(here: here, heading: 0, goal: goal, name: "Entrance", at: 22))      // too soon
        let closer = Coord(lat: 48.1376, lon: 11.5755)
        XCTAssertEqual(h.feed(here: closer, heading: 60, goal: goal, name: "Entrance", at: 30), "Entrance, 22 metres, left.")
        XCTAssertNil(h.feed(here: Coord(lat: 48.1300, lon: 11.5755), heading: 0, goal: goal, name: "Entrance", at: 60))   // far away
    }
}

final class ScooterAlertTests: XCTestCase {
    let here = Coord(lat: 48.1374, lon: 11.5755)

    func testCameraVibratesForScooterAheadOrVeryClose() {
        var a = ScooterAlert()
        XCTAssertFalse(a.feed([SeenObject(label: "scooter", distance: 2.5, side: .left)], at: 0))   // at the side, not close
        XCTAssertTrue(a.feed([SeenObject(label: "scooter", distance: 2.5, side: .ahead)], at: 1))   // in the way
        XCTAssertFalse(a.feed([SeenObject(label: "scooter", distance: 2.0, side: .ahead)], at: 2))  // not again so soon
        XCTAssertTrue(a.feed([SeenObject(label: "bicycle", distance: 1.0, side: .right)], at: 5))   // within 1 m, any side
        XCTAssertFalse(a.feed([SeenObject(label: "bench", distance: 0.8, side: .ahead)], at: 10))   // not a scooter
    }

    func testMapVibratesWhenWalkingTowardsAParkedScooter() {
        var a = ScooterAlert()
        let north8m = Scooter(id: "a", lat: 48.13747, lon: 11.5755, kind: "scooter")
        XCTAssertNil(a.feed(here: here, heading: 180, scooters: [north8m], at: 0))                  // behind
        XCTAssertNil(a.feed(here: here, heading: 60, scooters: [north8m], at: 4))                   // off to the side
        XCTAssertEqual(a.feed(here: here, heading: 10, scooters: [north8m], at: 8)?.id, "a")         // walking towards it
        XCTAssertNil(a.feed(here: here, heading: 0, scooters: [north8m], at: 12))                   // same scooter: not again for 30 s
        let atFeet = Scooter(id: "b", lat: 48.13741, lon: 11.5755, kind: "bike")                    // ~1 m, any direction
        XCTAssertEqual(a.feed(here: here, heading: 180, scooters: [atFeet], at: 16)?.id, "b")
    }
}

final class PlaceSearchTests: XCTestCase {
    let here = Coord(lat: 48.1374, lon: 11.5755)
    let marks = [
        Landmark(name: "Ballabeni", kind: "ice cream", lat: 48.1380, lon: 11.5755),
        Landmark(name: "Café Glockenspiel", kind: "café", lat: 48.1376, lon: 11.5755),
        Landmark(name: "toilets", kind: "toilets", lat: 48.1378, lon: 11.5755),
        Landmark(name: "U-Bahn entrance", kind: "U-Bahn entrance", lat: 48.1377, lon: 11.5757),
        Landmark(name: "Rossmann", kind: "drugstore", lat: 48.1375, lon: 11.5755),
    ]

    func testFindByWhatPeopleSay() {
        XCTAssertEqual(PlaceSearch.find("I want ice cream", in: marks, here: here)?.name, "Ballabeni")
        XCTAssertEqual(PlaceSearch.find("Eis", in: marks, here: here)?.name, "Ballabeni")
        XCTAssertEqual(PlaceSearch.find("where is a toilet", in: marks, here: here)?.name, "toilets")
        XCTAssertEqual(PlaceSearch.find("coffee", in: marks, here: here)?.name, "Café Glockenspiel")
        XCTAssertEqual(PlaceSearch.find("U-Bahn", in: marks, here: here)?.name, "U-Bahn entrance")
        XCTAssertEqual(PlaceSearch.find("rossmann", in: marks, here: here)?.name, "Rossmann")
        XCTAssertNil(PlaceSearch.find("zoo", in: marks, here: here))
    }
}
