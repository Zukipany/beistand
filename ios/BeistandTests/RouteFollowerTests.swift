import XCTest
@testable import Beistand

final class RouteFollowerTests: XCTestCase {
    override func setUp() { Lang.override = "de" }
    override func tearDown() { Lang.override = nil }

    // An L-shaped route: 100 m north, then 60 m east.
    let start = Coord(lat: 48.1500, lon: 11.5800)
    lazy var corner = Coord(lat: start.lat + 100 / 111_195, lon: start.lon)
    lazy var end = Coord(lat: corner.lat, lon: corner.lon + 60 / (111_195 * cos(corner.lat * .pi / 180)))

    func follower() -> RouteFollower {
        RouteFollower(destinationName: "Bäcker", steps: [
            RouteStep(instruction: "Gehen Sie geradeaus nach Norden", distance_m: 100, lat: start.lat, lon: start.lon),
            RouteStep(instruction: "Biegen Sie rechts ab", distance_m: 60, lat: corner.lat, lon: corner.lon),
            RouteStep(instruction: "Ziel erreicht", distance_m: 0, lat: end.lat, lon: end.lon),
        ], line: [start, corner, end])
    }

    func along(_ a: Coord, _ b: Coord, _ t: Double, east: Double = 0) -> Coord {
        Coord(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t + east / (111_195 * cos(a.lat * .pi / 180)))
    }

    func testGeometry() {
        XCTAssertEqual(Geo.distance(start, corner), 100, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(start, corner), 0, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(corner, end), 90, accuracy: 0.5)
        XCTAssertEqual(Geo.distance(along(start, corner, 0.5, east: 7), toPolyline: [start, corner, end]), 7, accuracy: 0.2)
        XCTAssertEqual(Geo.relative(target: 90, heading: 0), "rechts")
        XCTAssertEqual(Geo.relative(target: 280, heading: 0), "links")
        XCTAssertEqual(Geo.relative(target: 30, heading: 350), "halb rechts")
        XCTAssertEqual(Geo.relative(target: 180, heading: 0), "hinter Ihnen")
    }

    func testWalksRouteAnnouncesTurnOnceThenArrives() {
        var f = follower()
        var events: [RouteFollower.Event] = []
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {      // walk north in 5 m steps
            if let e = f.update(along(start, corner, t)) { events.append(e) }
        }
        for t in stride(from: 0.05, through: 1.0, by: 0.05) {     // then east
            if let e = f.update(along(corner, end, t)) { events.append(e) }
        }
        XCTAssertEqual(events, [.announce("Biegen Sie rechts ab"), .arrived])
        XCTAssertTrue(f.done)
    }

    func testOffRouteNeedsTwoFixes() {
        var f = follower()
        _ = f.update(along(start, corner, 0.2))
        XCTAssertNil(f.update(along(start, corner, 0.3, east: 40)))       // one bad fix: ignore (GPS jump)
        XCTAssertNil(f.update(along(start, corner, 0.35)))                // back on route resets
        XCTAssertNil(f.update(along(start, corner, 0.4, east: 40)))
        guard case .offRoute(let m)? = f.update(along(start, corner, 0.45, east: 45)) else {
            return XCTFail("expected offRoute")
        }
        XCTAssertGreaterThan(m, 40)
    }

    func testPoorAccuracyWidensTolerance() {
        var f = follower()
        _ = f.update(along(start, corner, 0.3, east: 30), accuracy: 40)
        XCTAssertNil(f.update(along(start, corner, 0.35, east: 30), accuracy: 40))
    }

    func testContextLine() {
        let f = follower()
        let c = f.context(at: along(start, corner, 0.5), heading: 0)
        XCTAssertTrue(c.contains("Ziel: Bäcker"))
        XCTAssertTrue(c.contains("geradeaus"))
        XCTAssertTrue(c.contains("Biegen Sie rechts ab"))
    }
}

final class LiveProtocolTests: XCTestCase {
    func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }

    func testSetupMessage() {
        let tools: [[String: Any]] = [["functionDeclarations": [["name": "plan_route"]]]]
        let s = obj(LiveProtocol.setup(model: "gemini-live", systemPrompt: "P", tools: tools, language: "de-DE"))["setup"] as! [String: Any]
        XCTAssertEqual(s["model"] as? String, "models/gemini-live")
        let gen = s["generationConfig"] as! [String: Any]
        XCTAssertEqual(gen["responseModalities"] as? [String], ["AUDIO"])
        XCTAssertNotNil(s["outputAudioTranscription"])
        XCTAssertEqual(((s["systemInstruction"] as! [String: Any])["parts"] as! [[String: String]])[0]["text"], "P")
    }

    func testRealtimeAndTextMessages() {
        let a = obj(LiveProtocol.audio(Data([1, 2])))["realtimeInput"] as! [String: Any]
        XCTAssertEqual((a["audio"] as! [String: String])["mimeType"], "audio/pcm;rate=16000")
        let v = obj(LiveProtocol.video(Data([3])))["realtimeInput"] as! [String: Any]
        XCTAssertEqual((v["video"] as! [String: String])["mimeType"], "image/jpeg")
        let t = obj(LiveProtocol.text("hi", respond: false))["clientContent"] as! [String: Any]
        XCTAssertEqual(t["turnComplete"] as? Bool, false)
        XCTAssertTrue(LiveProtocol.url(token: "abc").absoluteString.contains("BidiGenerateContentConstrained?access_token=abc"))
    }

    func testParseServerMessages() {
        let pcm = Data([0, 1, 2, 3]).base64EncodedString()
        let msg = """
        {"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(pcm)"}}]},
         "outputTranscription":{"text":"Sie sind"},"turnComplete":true}}
        """
        XCTAssertEqual(LiveProtocol.parse(Data(msg.utf8)), [.audio(Data([0, 1, 2, 3])), .guideText("Sie sind"), .turnComplete])
        XCTAssertEqual(LiveProtocol.parse(Data(#"{"setupComplete":{}}"#.utf8)), [.setupComplete])
        let tool = #"{"toolCall":{"functionCalls":[{"id":"7","name":"plan_route","args":{"destination":"Marienplatz"}}]}}"#
        XCTAssertEqual(LiveProtocol.parse(Data(tool.utf8)), [.toolCall(id: "7", name: "plan_route", args: ["destination": "Marienplatz"])])
        XCTAssertEqual(LiveProtocol.parse(Data("not json".utf8)), [])
    }
}
