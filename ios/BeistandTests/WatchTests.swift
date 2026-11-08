import XCTest
@testable import Beistand

final class WatchTests: XCTestCase {
    func testMessagesRoundTrip() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        for m in [WatchMessage.help, .imOK, .wristImpact(at: at), .wristFall(at: at), .cue(.right)] {
            XCTAssertEqual(WatchMessage(m.dict), m)
        }
        XCTAssertNil(WatchMessage(["k": "impact"]))   // missing time
        XCTAssertNil(WatchMessage(["k": "nonsense"]))
    }

    func testStateRoundTrip() {
        let st = WatchState(incident: "contact_responding", ackedBy: "Anna", contactName: "Anna",
                            contactPhone: "+4917000000", personName: "Maria")
        XCTAssertEqual(WatchState(st.dict), st)
        XCTAssertEqual(WatchState([:]).incident, "none")
    }

    func testDirectionCue() {
        XCTAssertEqual(GuideCue.from(direction: "In 15 Metern links abbiegen"), .left)
        XCTAssertEqual(GuideCue.from(direction: "Rechts halten"), .right)
        XCTAssertNil(GuideCue.from(direction: "Geradeaus"))
    }

    /// Feeds `g` at 50 Hz for `seconds`; returns the events seen.
    private func run(_ p: inout WristFallPattern, _ t: inout TimeInterval, g: (Int) -> Double, seconds: Double) -> [WristFallPattern.Event] {
        var out: [WristFallPattern.Event] = []
        for i in 0..<Int(seconds * 50) {
            t += 0.02
            if let e = p.feed(g: g(i), t: t) { out.append(e) }
        }
        return out
    }

    func testHitThenStillArmIsFall() {
        var p = WristFallPattern(), t: TimeInterval = 0
        XCTAssertEqual(run(&p, &t, g: { _ in 1.0 }, seconds: 2), [])
        XCTAssertEqual(run(&p, &t, g: { _ in 4.5 }, seconds: 0.04), [.impact])   // one impact, not two
        XCTAssertEqual(run(&p, &t, g: { $0 < 25 ? 1.8 : 1.0 }, seconds: 0.5), [])  // settling
        XCTAssertEqual(run(&p, &t, g: { $0 % 2 == 0 ? 1.03 : 0.97 }, seconds: 11), [.fall])
    }

    func testHitThenMovingIsNoFall() {
        var p = WristFallPattern(), t: TimeInterval = 0
        _ = run(&p, &t, g: { _ in 4.5 }, seconds: 0.02)
        // Walking on after bumping the arm: swings between 0.6 and 1.5 g.
        XCTAssertEqual(run(&p, &t, g: { $0 % 25 < 12 ? 1.5 : 0.6 }, seconds: 15), [])
    }

    func testHitStillThenGetsUpIsNoFall() {
        var p = WristFallPattern(), t: TimeInterval = 0
        _ = run(&p, &t, g: { _ in 4.5 }, seconds: 0.02)
        XCTAssertEqual(run(&p, &t, g: { _ in 1.0 }, seconds: 5), [])
        XCTAssertEqual(run(&p, &t, g: { _ in 1.6 }, seconds: 0.1), [])   // arm moves: person is fine
        XCTAssertEqual(run(&p, &t, g: { _ in 1.0 }, seconds: 12), [])
    }

    func testClappingReportsImpactsButNoFall() {
        var p = WristFallPattern(), t: TimeInterval = 0
        // A hard clap every 0.5 s for 6 s, arm moving in between.
        let events = run(&p, &t, g: { $0 % 25 == 0 ? 3.5 : ($0 % 25 < 12 ? 1.4 : 0.7) }, seconds: 6)
        XCTAssertFalse(events.contains(.fall))
        XCTAssertLessThanOrEqual(events.count, 3)   // cooldown keeps the phone from being flooded
    }
}

final class SystemAccessibilityTests: XCTestCase {
    typealias F = SystemAccessibility.Flags

    func testNothingOnMeansNoModes() {
        XCTAssertEqual(SystemAccessibility.hints(F()), [])
        XCTAssertEqual(SystemAccessibility.hints(F(boldText: true)), [])   // a taste, not a need
    }

    func testVoiceOverMeansSightNotLowVision() {
        let h = SystemAccessibility.hints(F(voiceOver: true, largeText: true))
        XCTAssertEqual(h.map(\.mode), [.sight])
    }

    func testOtherSettings() {
        XCTAssertEqual(SystemAccessibility.hints(F(largeText: true)).map(\.mode), [.lowVision])
        XCTAssertEqual(SystemAccessibility.hints(F(captions: true)).map(\.mode), [.hearing])
        XCTAssertEqual(SystemAccessibility.hints(F(monoAudio: true, switchControl: true)).map(\.mode), [.hearing, .tremor])
    }
}

final class LangTests: XCTestCase {
    override func tearDown() { Lang.override = nil }

    func testEnglishAndGerman() {
        Lang.override = "en"
        XCTAssertEqual(tr("Help", "Hilfe"), "Help")
        XCTAssertEqual(Geo.relative(target: 90, heading: 0), "right")
        XCTAssertEqual(Lang.speech, "en-US")
        Lang.override = "de"
        XCTAssertEqual(tr("Help", "Hilfe"), "Hilfe")
        XCTAssertEqual(Geo.relative(target: 270, heading: 0), "links")
        XCTAssertEqual(Lang.speech, "de-DE")
    }

    func testYesNoBothLanguages() {
        XCTAssertEqual(Listener.yesNo("Yes please"), true)
        XCTAssertEqual(Listener.yesNo("Nein danke"), false)
        XCTAssertEqual(Listener.yesNo("nicht gut"), false)
        XCTAssertNil(Listener.yesNo("I know"))          // "know" is not "no"
        XCTAssertEqual(GuideCue.from(direction: "Turn left in 15 metres"), .left)
    }
}

final class ReadAloudTests: XCTestCase {
    func testExtractAmountAndDate() {
        let de = OnDeviceReader.extract("Mahnung\nBitte zahlen Sie 125,40 € bis zum 03.12.2026 an die Stadtwerke.")
        XCTAssertEqual(de.amount, "125,40 €")
        XCTAssertEqual(de.deadline, "03.12.2026")
        let en = OnDeviceReader.extract("Please pay £42.50 by 3 December 2026.")
        XCTAssertEqual(en.amount, "£42.50")
        XCTAssertEqual(en.deadline, "3 December 2026")
        XCTAssertNil(OnDeviceReader.extract("See you tomorrow").amount)
        XCTAssertEqual(OnDeviceReader.extract("Best before: 03.2028").deadline, "03.2028")
    }

    func testSpokenPutsDateAndAmountFirst() {
        Lang.override = "en"; defer { Lang.override = nil }
        let s = OnDeviceReader.spoken(.init(text: "Pay 10,00 € by 01.02.2027", amount: "10,00 €", deadline: "01.02.2027"))
        XCTAssertTrue(s.hasPrefix("I found a date: 01.02.2027. I found an amount: 10,00 €."))
    }
}

final class LoudnessTests: XCTestCase {
    func testLouderIsBigger() {
        XCTAssertEqual(Loudness.fontSize(-80), 18)          // quieter than quiet: smallest
        XCTAssertEqual(Loudness.fontSize(0), 60)            // louder than loud: biggest
        XCTAssertLessThan(Loudness.fontSize(-40), Loudness.fontSize(-25))
        XCTAssertLessThan(Loudness.fontSize(-25), Loudness.fontSize(-12))
    }

    func testDbfsOfSignals() {
        let full = [Float](repeating: 1, count: 100)
        XCTAssertEqual(full.withUnsafeBufferPointer { Loudness.dbfs($0.baseAddress!, count: 100) }, 0, accuracy: 0.01)
        let tenth = [Float](repeating: 0.1, count: 100)
        XCTAssertEqual(tenth.withUnsafeBufferPointer { Loudness.dbfs($0.baseAddress!, count: 100) }, -20, accuracy: 0.01)
    }

    func testAverageOverWordWindow() {
        let h: [(t: Double, db: Float)] = [(0.0, -60), (0.5, -20), (0.6, -20), (1.5, -60)]
        XCTAssertEqual(Loudness.average(h, from: 0.45, to: 0.65)!, -20, accuracy: 0.01)   // the word was loud
        XCTAssertNil(Loudness.average(h, from: 3, to: 4))
    }
}

import CoreMedia
import Speech

final class CaptionEngineTests: XCTestCase {
    func testWordsCarryTheirAudioTime() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("needs iOS 26") }
        var hello = AttributedString("Hello ")
        hello.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                                           end: CMTime(seconds: 1.4, preferredTimescale: 600))
        var world = AttributedString("world")
        world.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1.5, preferredTimescale: 600),
                                           end: CMTime(seconds: 2, preferredTimescale: 600))
        let words = ModernSpeech.words(in: hello + world)
        XCTAssertEqual(words.map(\.text), ["Hello", "world"])
        XCTAssertEqual(words[0].start!, 1, accuracy: 0.01)
        XCTAssertEqual(words[1].end!, 2, accuracy: 0.01)
    }

    func testLineLoudnessIsPowerAverage() {
        let line = CaptionLine(words: [CaptionWord(text: "a", db: -20), CaptionWord(text: "b", db: -20)])
        XCTAssertEqual(line.db, -20, accuracy: 0.01)
        let mixed = CaptionLine(words: [CaptionWord(text: "QUIET", db: -60), CaptionWord(text: "LOUD", db: -10)])
        XCTAssertGreaterThan(mixed.db, -14)      // one shout dominates, as it sounds
        XCTAssertEqual(line.text, "a b")
    }

    func testSpeakerLanguagesExcludeMine() {
        Lang.override = "en"; defer { Lang.override = nil }
        let ids = SpeakerLanguage.all.map(\.id)
        XCTAssertEqual(ids.first, "en-US")                  // "same as mine"
        XCTAssertFalse(ids.dropFirst().contains("en-US"))
        XCTAssertTrue(ids.contains("tr-TR") && ids.contains("de-DE"))
    }
}

final class LiveResumeTests: XCTestCase {
    func testSetupAsksForResumptionAndCompression() throws {
        let fresh = try JSONSerialization.jsonObject(with: LiveProtocol.setup(model: "gemini-3.8-live", systemPrompt: "p",
                                                                              tools: [], language: "en-US")) as! [String: Any]
        let setup = fresh["setup"] as! [String: Any]
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.8-live")
        XCTAssertNotNil(setup["sessionResumption"] as? [String: Any])
        XCTAssertNotNil((setup["contextWindowCompression"] as? [String: Any])?["slidingWindow"])
        let resumed = try JSONSerialization.jsonObject(with: LiveProtocol.setup(model: "m", systemPrompt: "p", tools: [],
                                                                                language: "en-US", resumeHandle: "H1")) as! [String: Any]
        XCTAssertEqual(((resumed["setup"] as! [String: Any])["sessionResumption"] as! [String: Any])["handle"] as? String, "H1")
    }

    func testParsesHandleAndGoAway() {
        let msg = #"{"sessionResumptionUpdate":{"newHandle":"abc","resumable":true},"goAway":{"timeLeft":"10s"}}"#
        XCTAssertEqual(LiveProtocol.parse(Data(msg.utf8)), [.goAway(timeLeft: "10s"), .resumeHandle("abc")])
        let notYet = #"{"sessionResumptionUpdate":{"newHandle":"abc","resumable":false}}"#
        XCTAssertEqual(LiveProtocol.parse(Data(notYet.utf8)), [])
    }

    func testReconnectPolicy() {
        var p = ResumePolicy()
        XCTAssertFalse(p.shouldReconnect(hasHandle: false))           // nothing to resume
        for _ in 0..<5 { XCTAssertTrue(p.shouldReconnect(hasHandle: true)) }
        XCTAssertFalse(p.shouldReconnect(hasHandle: true))            // 5 failures in a row: give up
        p.connected()
        XCTAssertTrue(p.shouldReconnect(hasHandle: true))             // a success resets the count
    }
}

final class CrossingFollowTests: XCTestCase {
    func testCrossingAnnouncedOnceNearIt() {
        let a = Coord(lat: 48.1000, lon: 11.5000), b = Coord(lat: 48.1000, lon: 11.5100)
        var f = RouteFollower(destinationName: "Ziel",
                              steps: [RouteStep(instruction: "Go east", distance_m: 744, lat: a.lat, lon: a.lon),
                                      RouteStep(instruction: "Arrived", distance_m: 0, lat: b.lat, lon: b.lon)],
                              line: [a, b])
        f.crossings = [RouteCrossing(signal: "sound", name: "Test", lat: 48.1000, lon: 11.5050, say: "Crossing with sound ahead.")]
        var events: [RouteFollower.Event] = []
        for i in stride(from: 0.0, through: 0.7, by: 0.02) {          // walk east in ~15 m steps
            let p = Coord(lat: 48.1000, lon: 11.5000 + 0.01 * i)
            if let e = f.update(p, accuracy: 5) { events.append(e) }
        }
        XCTAssertEqual(events.filter { $0 == .crossing("Crossing with sound ahead.") }.count, 1)
        XCTAssertFalse(events.contains { if case .offRoute = $0 { return true }; return false })
    }
}

import simd

final class ObstacleTests: XCTestCase {
    // Phone 1.3 m above the floor, facing north (-z in ARKit world).
    let cam = SIMD3<Float>(0, 1.3, 0)
    let north = SIMD3<Float>(0, -0.3, -1)          // tilted down a little: vertical part must not matter

    func testLanesAndHeights() {
        let pts: [SIMD3<Float>] = [
            SIMD3(0.1, 1.0, -1.5),     // pole ahead, 1.5 m
            SIMD3(0.0, 0.05, -0.8),    // ground ahead: ignored
            SIMD3(0.0, 2.6, -1.0),     // sign overhead: ignored
            SIMD3(-0.9, 0.8, -2.0),    // bike on the left, 2 m
            SIMD3(1.5, 0.8, -1.0),     // too far right: ignored
            SIMD3(0.0, 1.0, 1.0),      // behind: ignored
        ]
        let z = ObstacleGeometry.zones(points: pts, camera: cam, forward: north, floorY: 0)
        XCTAssertEqual(z.centre!, 1.5, accuracy: 0.01)
        XCTAssertEqual(z.left!, 2.0, accuracy: 0.01)
        XCTAssertNil(z.right)
    }

    func testUnprojectCentrePixelGoesStraightAhead() {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(0, 1.3, 0, 1)
        let p = ObstacleGeometry.worldPoint(u: 128, v: 96, depth: 2, fx: 200, fy: 200, cx: 128, cy: 96, cameraTransform: t)
        XCTAssertEqual(p, SIMD3<Float>(0, 1.3, -2))
        let up = ObstacleGeometry.worldPoint(u: 128, v: 0, depth: 2, fx: 200, fy: 200, cx: 128, cy: 96, cameraTransform: t)
        XCTAssertGreaterThan(up.y, 1.3)                // image row 0 is above the centre
    }

    func testBeepsGetFasterWhenCloser() {
        XCTAssertNil(BeepTiming.interval(for: nil))
        XCTAssertNil(BeepTiming.interval(for: 2.5))
        XCTAssertEqual(BeepTiming.interval(for: 0.3)!, 0.1, accuracy: 0.001)
        XCTAssertGreaterThan(BeepTiming.interval(for: 1.8)!, BeepTiming.interval(for: 1.0)!)
    }

    func testAlertsNearestInPathFirstAndNoRepeats() {
        Lang.override = "en"; defer { Lang.override = nil }
        var a = ObjectAlerts()
        let bike = SeenObject(label: "bicycle", distance: 2.2, side: .left)
        let pole = SeenObject(label: "pole", distance: 2.6, side: .ahead)
        XCTAssertEqual(a.feed([bike, pole], at: 0), "Pole, 3 metres, ahead.")       // in the path wins
        XCTAssertNil(a.feed([bike, pole], at: 1))                                   // 2 s between warnings
        XCTAssertEqual(a.feed([bike, pole], at: 3), "Bike, 2 metres, left.")
        XCTAssertNil(a.feed([bike, pole], at: 6))                                   // both said recently
        XCTAssertEqual(a.feed([pole], at: 11), "Pole, 3 metres, ahead.")            // again after 8 s
        XCTAssertNil(a.feed([SeenObject(label: "person", distance: 3, side: .ahead)], at: 20))   // people only when close
    }

    func testClassifierLabelsMap() {
        XCTAssertEqual(ObjectAlerts.normalise("bicycle"), "bicycle")
        XCTAssertEqual(ObjectAlerts.normalise("motor_scooter"), "scooter")
        XCTAssertEqual(ObjectAlerts.normalise("streetcar"), "tram")
        XCTAssertNil(ObjectAlerts.normalise("sky"))
    }

    /// A recorded walk (as the phone writes it) replayed through the same rules.
    func testReplayRecordedWalk() {
        Lang.override = "en"; defer { Lang.override = nil }
        let recorded = """
        {"t":0.5,"kind":"fix","lat":48.14,"lon":11.56,"acc":5}
        {"t":1.0,"kind":"zones","zones":{"centre":1.8}}
        {"t":1.2,"kind":"objects","objects":[{"label":"scooter","distance":1.9,"side":"ahead"}]}
        {"t":1.7,"kind":"objects","objects":[{"label":"scooter","distance":1.4,"side":"ahead"}]}
        {"t":2.0,"kind":"zones","zones":{"centre":0.4}}
        {"t":4.0,"kind":"objects","objects":[{"label":"person","distance":1.2,"side":"right"}]}
        broken line is skipped
        """
        let walk = WalkRecorder.read(recorded)
        XCTAssertEqual(walk.count, 6)
        var alerts = ObjectAlerts()
        var said: [String] = []
        var beeps: [TimeInterval?] = []
        for e in walk {
            if let z = e.zones { beeps.append(BeepTiming.interval(for: z.centre)) }
            if let o = e.objects, let s = alerts.feed(o, at: e.t) { said.append(s) }
        }
        XCTAssertEqual(said, ["Scooter, 2 metres, ahead.", "Person, 1 metre, right."])
        XCTAssertEqual(beeps.last!!, 0.1, accuracy: 0.001)
        XCTAssertGreaterThan(beeps.first!!, 0.5)
    }
}
