import XCTest
@testable import Beistand

final class RideTests: XCTestCase {
    // U6 Marienplatz 0 s → Odeonsplatz 60 → Universität 180 → Giselastraße 240 → Münchner Freiheit 300,
    // then U3 from Münchner Freiheit 420 → Bonner Platz 540.
    let trip = RideTrip(legs: [
        .init(line: "U6", type: "UBAHN", direction: "Fröttmaning",
              from: .init(name: "Marienplatz", time: 0, platform: 1),
              stops: [.init(name: "Odeonsplatz", time: 60), .init(name: "Universität", time: 180), .init(name: "Giselastraße", time: 240)],
              to: .init(name: "Münchner Freiheit", time: 300)),
        .init(line: "U3", type: "UBAHN", direction: "Moosach",
              from: .init(name: "Münchner Freiheit", time: 420, platform: 2),
              stops: [], to: .init(name: "Bonner Platz", time: 540, exit: "B", lift_out_of_order: true)),
    ])
    override func setUp() { Lang.override = "en" }
    override func tearDown() { Lang.override = nil }

    func testFeltStopsCountOnlyWhenAStopIsDue() {
        var r = RideTracker(trip: trip)
        XCTAssertNil(r.feltStop(now: -50))                                   // stopped in the tunnel before leaving
        XCTAssertEqual(r.feltStop(now: 62), .next(at: "Odeonsplatz", next: "Universität"))
        XCTAssertNil(r.feltStop(now: 70))                                    // signal stop between stations: too early
        XCTAssertEqual(r.feltStop(now: 182), .next(at: "Universität", next: "Giselastraße"))
        XCTAssertEqual(r.feltStop(now: 241), .getReady("Münchner Freiheit"))  // one stop before: get ready
        if case .getOff(let name, let change)? = r.feltStop(now: 301) {
            XCTAssertEqual(name, "Münchner Freiheit"); XCTAssertEqual(change?.line, "U3"); XCTAssertEqual(change?.from.platform, 2)
        } else { XCTFail("expected get off and change") }
        XCTAssertEqual(r.stopsLeft, 1)
        XCTAssertEqual(r.feltStop(now: 541), .arrived("Bonner Platz"))
        XCTAssertTrue(r.finished)
    }

    func testTimetableMovesOnWhenNoStopIsFelt() {
        var r = RideTracker(trip: trip)
        XCTAssertNil(r.tick(now: 90))                                        // Odeonsplatz due at 60, slack 40
        XCTAssertEqual(r.tick(now: 101), .next(at: "Odeonsplatz", next: "Universität"))
        XCTAssertNil(r.tick(now: 150))
        XCTAssertEqual(r.tick(now: 221), .next(at: "Universität", next: "Giselastraße"))
    }

    func testEarlyWarningByTimeEvenIfCountingMissed() {
        var r = RideTracker(trip: trip)
        _ = r.feltStop(now: 61); _ = r.feltStop(now: 181)                    // at Universität; Giselastraße missed
        XCTAssertNil(r.tick(now: 200))
        XCTAssertEqual(r.tick(now: 282), .getReady("Münchner Freiheit"))     // the timetable catches up and still warns
        // warned once by time when at the second-to-last stop
        var s = RideTracker(trip: trip)
        _ = s.feltStop(now: 61); _ = s.feltStop(now: 181); _ = s.feltStop(now: 241)
        XCTAssertNil(s.tick(now: 250))                                       // already warned on arrival at Giselastraße
    }

    func testStationSignJumpsAhead() {
        var r = RideTracker(trip: trip)
        XCTAssertEqual(r.saw("U GISELASTRASSE"), .getReady("Münchner Freiheit"))
        XCTAssertNil(r.saw("Odeonsplatz"))                                   // behind us: ignored
        XCTAssertEqual(r.nextStop?.name, "Münchner Freiheit")
    }

    func testTransitSceneFromLabels() {
        XCTAssertEqual(TransitScene.from([("train", 0.6)]), .train)
        XCTAssertEqual(TransitScene.from([("train_station", 0.5), ("train", 0.4)]), .station)
        XCTAssertEqual(TransitScene.from([("seat", 0.4), ("train_real", 0.2)]), .train)
        XCTAssertNil(TransitScene.from([("seat", 0.5), ("interior_room", 0.6)]))
    }
}

final class TrainMotionTests: XCTestCase {
    /// 50 samples per second of a sine-ish signal with this amplitude (g).
    func run(_ m: inout TrainMotion, amp: Double, seconds: Double, from t0: Double, automotive: Bool = false, speed: Double? = nil) -> [TrainMotion.State] {
        var out: [TrainMotion.State] = []
        var t = t0
        while t < t0 + seconds {
            let a = amp * sin(t * 2 * .pi * 7) * 1.414          // RMS = amp
            if let s = m.feed(x: a, y: 0, z: 0, at: t, automotive: automotive, speed: speed) { out.append(s) }
            t += 0.02
        }
        return out
    }

    func testHumThenQuietThenWalking() {
        var m = TrainMotion()
        XCTAssertEqual(run(&m, amp: 0.04, seconds: 10, from: 0), [.riding])          // train hum for 10 s
        XCTAssertEqual(run(&m, amp: 0.004, seconds: 8, from: 10), [.still])          // stopped at a station
        XCTAssertEqual(run(&m, amp: 0.25, seconds: 4, from: 18), [.walking])         // getting off, walking
    }

    func testShortHumIsNotARide() {
        var m = TrainMotion()
        XCTAssertEqual(run(&m, amp: 0.04, seconds: 3, from: 0), [])                  // 3 s: not yet
    }

    func testSpeedOrIOSMakeItQuicker() {
        var a = TrainMotion()
        XCTAssertEqual(run(&a, amp: 0.02, seconds: 3, from: 0, automotive: true), [.riding])
        var b = TrainMotion()
        XCTAssertEqual(run(&b, amp: 0.005, seconds: 3, from: 0, speed: 12), [.riding])   // S-Bahn above ground, smooth
    }
}

final class DoorFinderTests: XCTestCase {
    func testFindsTheGapInTheTrainWall() {
        // Train side 1.5 m away, an open door (3.5 m deep into the carriage) a bit right of centre.
        var cols: [Float?] = Array(repeating: 1.5, count: 13)
        cols[7] = 3.5; cols[8] = 3.6
        let d = DoorFinder.find(cols)
        XCTAssertNotNil(d)
        XCTAssertEqual(d!.angle, 8.1, accuracy: 0.2)          // 1.5 columns of 70°/13 right of centre
        XCTAssertEqual(d!.distance, 1.5, accuracy: 0.01)
        XCTAssertTrue(DoorFinder.phrase(d!).hasPrefix(Lang.german ? "Offene Tür" : "Open door"))
    }

    func testNoDoorInAClosedTrainOrEmptyPlatform() {
        XCTAssertNil(DoorFinder.find(Array(repeating: 1.5, count: 13)))                    // closed doors: all wall
        XCTAssertNil(DoorFinder.find(Array(repeating: nil, count: 13)))                    // nothing there
        var single: [Float?] = Array(repeating: 1.5, count: 13); single[4] = 4               // one column: a pole gap, not a door
        XCTAssertNil(DoorFinder.find(single))
    }

    func testStepInWhenCloseAndStraightAhead() {
        Lang.override = "en"; defer { Lang.override = nil }
        XCTAssertEqual(DoorFinder.phrase(.init(angle: 2, distance: 0.7)), "Step in now. Mind the gap.")
        XCTAssertEqual(DoorFinder.phrase(.init(angle: -25, distance: 2.2)), "Open door, slightly left, 2 metres.")
    }

    func testDepthsFromPoints() {
        // A wall 2 m ahead at chest height, the floor at y = 0, camera at 1.4 m looking north (-z).
        var pts: [SIMD3<Float>] = []
        for x in stride(from: Float(-1.2), through: 1.2, by: 0.05) { pts.append(SIMD3(x, 1.2, -2)) }
        pts.append(SIMD3(0, 0.1, -1))                    // something on the floor: ignored
        let cols = DoorFinder.depths(points: pts, camera: SIMD3(0, 1.4, 0), forward: SIMD3(0, 0, -1), floorY: 0)
        XCTAssertEqual(cols[6]!, 2, accuracy: 0.05)      // straight ahead
        XCTAssertNotNil(cols[2]); XCTAssertNotNil(cols[10])
    }
}

final class RideLocationTests: XCTestCase {
    func testLocationAtAStationMovesTheRide() {
        Lang.override = "en"; defer { Lang.override = nil }
        let trip = RideTrip(legs: [.init(line: "S1", type: "SBAHN", direction: "Freising",
            from: .init(name: "Hauptbahnhof", time: 0, lat: 48.1402, lon: 11.5600),
            stops: [.init(name: "Hackerbrücke", time: 120, lat: 48.1418, lon: 11.5491),
                    .init(name: "Donnersbergerbrücke", time: 240, lat: 48.1422, lon: 11.5363)],
            to: .init(name: "Laim", time: 360, lat: 48.1447, lon: 11.5040))])
        var r = RideTracker(trip: trip)
        XCTAssertNil(r.reached(Coord(lat: 48.1410, lon: 11.5550), accuracy: 20))              // between stations
        XCTAssertEqual(r.reached(Coord(lat: 48.1419, lon: 11.5490), accuracy: 20),
                       .next(at: "Hackerbrücke", next: "Donnersbergerbrücke"))
        XCTAssertEqual(r.reached(Coord(lat: 48.1422, lon: 11.5365), accuracy: 30), .getReady("Laim"))
        XCTAssertNil(r.reached(Coord(lat: 48.1447, lon: 11.5040), accuracy: 400))              // too vague to trust
        XCTAssertEqual(r.reached(Coord(lat: 48.1447, lon: 11.5041), accuracy: 15), .arrived("Laim"))
    }
}

final class IndoorTests: XCTestCase {
    override func setUp() { Lang.override = "en" }
    override func tearDown() { Lang.override = nil }
    // Bins every 25 cm from 0.4 m; floor heights in metres (camera at 1.4 m, floor at 0).
    func bins(_ hs: [Float?]) -> [Float?] { hs + Array(repeating: nil, count: max(0, 10 - hs.count)) }

    func testFlatFloorSaysNothing() {
        XCTAssertNil(GroundProfile.analyze(Array(repeating: 0, count: 10)))
    }

    func testSingleStepDownAndUp() {
        XCTAssertEqual(GroundProfile.analyze([0, 0, 0, 0, -0.17, -0.17, -0.17, -0.17, -0.17, -0.17]), .stepDown(distance: 1.4, height: 0.17))
        let up = GroundProfile.analyze([0, 0, 0.15, 0.15, 0.15, 0.15, 0.15, 0.15, 0.15, 0.15])
        if case .stepUp(let d, let h)? = up { XCTAssertEqual(d, 0.9, accuracy: 0.01); XCTAssertEqual(h, 0.15, accuracy: 0.01) } else { XCTFail("\(String(describing: up))") }
    }

    func testStairsDown() {
        XCTAssertEqual(GroundProfile.analyze([0, 0, 0, -0.17, -0.34, -0.51, -0.68, -0.85, -1.0, -1.2]), .stairsDown(distance: 1.15))
    }

    func testEdgeWhereTheFloorEnds() {
        // Balcony edge: floor, then nothing in the walking path.
        XCTAssertEqual(GroundProfile.analyze([0, 0, 0, 0, nil, nil, nil, nil, nil, nil]), .drop(distance: 1.4))
        // Looking down a stairwell: the floor continues 3 m lower.
        XCTAssertEqual(GroundProfile.analyze([0, 0, 0, -3, -3, -3, -3, -3, -3, -3]), .drop(distance: 1.15))
        XCTAssertTrue(GroundProfile.urgent(.drop(distance: 1.4)))
        XCTAssertEqual(GroundProfile.phrase(.drop(distance: 1.4)), "Stop! No floor ahead, 1.5 metres.")
    }

    func testFloorSeenOnlyFromFarAway() {
        // Phone held upright: the floor shows from ~2 m; a step at 2.65 m is still found.
        XCTAssertEqual(GroundProfile.analyze([nil, nil, nil, nil, nil, nil, 0, 0, 0, -0.18]), .stepDown(distance: 2.65, height: 0.18))
    }

    func testRepeatOnlyWhenCloserOrLater() {
        let e = GroundProfile.Event.stepDown(distance: 2.0, height: 0.17)
        XCTAssertTrue(GroundProfile.shouldSay(e, last: nil, now: 0))
        XCTAssertFalse(GroundProfile.shouldSay(.stepDown(distance: 1.5, height: 0.17), last: ("stepDown", 2.0, 0), now: 1))
        XCTAssertTrue(GroundProfile.shouldSay(.stepDown(distance: 1.0, height: 0.17), last: ("stepDown", 2.0, 0), now: 2))
        XCTAssertTrue(GroundProfile.shouldSay(.stairsDown(distance: 1.5), last: ("stepDown", 2.0, 0), now: 1))
    }

    func testFloorBinsFromPoints() {
        var pts: [SIMD3<Float>] = []
        for z in stride(from: Float(0.5), through: 2.9, by: 0.05) { pts.append(SIMD3(0, z < 1.5 ? 0 : -0.2, -z)) }   // step down at 1.5 m
        pts.append(SIMD3(0, 1.0, -1.0))                                                                             // a table: ignored height
        let b = GroundProfile.floor(points: pts, camera: SIMD3(0, 1.4, 0), forward: SIMD3(0, 0, -1))
        XCTAssertEqual(b[0]!, 0, accuracy: 0.01)
        if case .stepDown(let d, _)? = GroundProfile.analyze(b) { XCTAssertEqual(d, 1.4, accuracy: 0.13) } else { XCTFail() }
    }

    func testDoorsExitsAndWhatToSayFirst() {
        XCTAssertTrue(Indoor.isExitSign("NOTAUSGANG"))
        XCTAssertTrue(Indoor.isExitSign("Exit →"))
        XCTAssertFalse(Indoor.isExitSign("Eingang"))
        XCTAssertTrue(Indoor.looksIndoors([("kitchen", 0.6)]))
        XCTAssertFalse(Indoor.looksIndoors([("street", 0.8)]))
        let things = [IndoorThing(kind: .window, distance: 2, angle: 5), IndoorThing(kind: .door, distance: 4, angle: -20)]
        XCTAssertEqual(Indoor.mostUseful(things)?.kind, .door)
        XCTAssertEqual(IndoorThing(kind: .door, distance: 3.2, angle: -20).phrase, "Door, 3 metres, slightly left.")
        let r = Indoor.relative(SIMD3(1, 1, -1), camera: SIMD3(0, 1.4, 0), forward: SIMD3(0, 0, -1))!
        XCTAssertEqual(r.angle, 45, accuracy: 0.1)
        XCTAssertEqual(r.distance, 1.414, accuracy: 0.01)
    }
}
