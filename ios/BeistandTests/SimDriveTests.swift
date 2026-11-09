import XCTest
@testable import Beistand

final class SimDriveTests: XCTestCase {
    let start = WalkerState(position: Coord(lat: 48.1374, lon: 11.5755), heading: 0)

    func testWalkingNorthForTenSecondsCoversFourteenMetres() {
        var s = start
        for _ in 0..<100 { s = WalkerPhysics.step(s, forward: 1, strafe: 0, turn: 0, dt: 0.1) }
        XCTAssertEqual(Geo.distance(start.position, s.position), 14, accuracy: 0.2)
        XCTAssertEqual(Geo.bearing(start.position, s.position), 0, accuracy: 1)
    }

    func testStrafeRightWhileFacingNorthGoesEast() {
        let s = WalkerPhysics.step(start, forward: 0, strafe: 1, turn: 0, dt: 1)
        XCTAssertEqual(Geo.bearing(start.position, s.position), 90, accuracy: 1)
        XCTAssertEqual(s.heading, 0)
    }

    func testTurningAndFastWalking() {
        let turned = WalkerPhysics.step(start, forward: 0, strafe: 0, turn: -1, dt: 1)
        XCTAssertEqual(turned.heading, 270, accuracy: 0.001)               // left turn wraps past north
        let fast = WalkerPhysics.step(turned, forward: 1, strafe: 0, turn: 0, fast: true, dt: 1)
        XCTAssertEqual(Geo.distance(turned.position, fast.position), 5.6, accuracy: 0.1)
        XCTAssertEqual(Geo.bearing(turned.position, fast.position), 270, accuracy: 1)
        let up = WalkerPhysics.step(start, forward: 0, strafe: 0, turn: 0, look: 1, dt: 5)
        XCTAssertEqual(up.pitch, 30)                                       // clamped
    }

    func testPictureOnlyAfterMovingOrTurning() {
        XCTAssertTrue(SimEstimate.needsPicture(last: nil, now: start))
        var s = start
        s.position.lat += 2 / 111_320
        XCTAssertFalse(SimEstimate.needsPicture(last: start, now: s))       // 2 m
        s.position.lat += 4 / 111_320
        XCTAssertTrue(SimEstimate.needsPicture(last: start, now: s))        // 6 m
        var t = start; t.heading = 350
        XCTAssertFalse(SimEstimate.needsPicture(last: start, now: t))       // 10°
        t.heading = 340
        XCTAssertTrue(SimEstimate.needsPicture(last: start, now: t))
    }

    func testDistanceFromBoxHeight() {
        // A person filling half the picture height with a 96° vertical view is about 1.5 m away.
        XCTAssertEqual(SimEstimate.distance(boxHeight: 0.5, realHeight: 1.7, verticalFOV: 96), 1.53, accuracy: 0.05)
        XCTAssertEqual(SimEstimate.distance(boxHeight: 0.1, realHeight: 1.7, verticalFOV: 96), 7.65, accuracy: 0.1)
    }
}

final class ViewerInputTests: XCTestCase {
    func testStepChoice() {
        XCTAssertEqual(ViewerInput.step(forward: 1, strafe: 0), "StepForward")
        XCTAssertEqual(ViewerInput.step(forward: -0.8, strafe: 0.2), "StepBackward")
        XCTAssertEqual(ViewerInput.step(forward: 0.2, strafe: -0.9), "StepLeft")
        XCTAssertEqual(ViewerInput.step(forward: 0.5, strafe: 0.6), "StepRight")
        XCTAssertNil(ViewerInput.step(forward: 0.1, strafe: 0.2))
        XCTAssertEqual(ViewerInput.turn(1, dt: 0.5), 45, accuracy: 1e-9)
        XCTAssertEqual(ViewerInput.turn(-3, dt: 1), -90, accuracy: 1e-9)
    }

    @MainActor func testViewerEventsMoveTheWalker() {
        let d = SimDrive.shared
        d.viewerEvent(["type": "image", "id": "42", "lat": 48.1376, "lon": 11.5757, "pano": true, "captured": 1.7e12])
        XCTAssertEqual(d.state.position, Coord(lat: 48.1376, lon: 11.5757))
        XCTAssertEqual(d.provider, "mapillary")
        d.viewerEvent(["type": "bearing", "bearing": -30.0])
        XCTAssertEqual(d.state.heading, 330, accuracy: 1e-9)
        d.viewerEvent(["type": "blocked", "dir": "StepForward"])
        XCTAssertNotNil(d.problem)
        LocationService.shared.endSimulation()
    }
}

final class NextStepTests: XCTestCase {
    func testNextStepFollowsTheRoute() {
        let a = Coord(lat: 48.1374, lon: 11.5755), b = Coord(lat: 48.1378, lon: 11.5755), c = Coord(lat: 48.1378, lon: 11.5765)
        var f = RouteFollower(destinationName: "X", steps: [
            RouteStep(instruction: "Walk north", distance_m: 44, lat: a.lat, lon: a.lon),
            RouteStep(instruction: "Turn right", distance_m: 74, lat: b.lat, lon: b.lon),
            RouteStep(instruction: "Arrive", distance_m: 0, lat: c.lat, lon: c.lon)], line: [a, b, c])
        XCTAssertEqual(f.nextStep?.instruction, "Turn right")
        _ = f.update(Coord(lat: 48.13775, lon: 11.5755))          // close to the corner: announced, next is the end
        XCTAssertEqual(f.nextStep?.instruction, "Arrive")
        _ = f.update(c)
        XCTAssertNil(f.nextStep)                                   // arrived
    }
}
