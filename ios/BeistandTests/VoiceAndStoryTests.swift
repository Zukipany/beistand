import XCTest
@testable import Beistand

final class CommandParserTests: XCTestCase {
    func testEnglishCommands() {
        XCTAssertEqual(CommandParser.parse("Help!"), .help)
        XCTAssertEqual(CommandParser.parse("call my daughter"), .callFamily)
        XCTAssertEqual(CommandParser.parse("Is this a scam call?"), .scam)
        XCTAssertEqual(CommandParser.parse("where am I"), .whereAmI)
        XCTAssertEqual(CommandParser.parse("I'm lost"), .guide)
        XCTAssertEqual(CommandParser.parse("take the U-Bahn to Odeonsplatz"), .ride(to: "Odeonsplatz"))
        XCTAssertEqual(CommandParser.parse("when does the next train go"), .departures)
        XCTAssertEqual(CommandParser.parse("I want ice cream")?.isFind, true)
        XCTAssertEqual(CommandParser.parse("find Rossmann"), .find("Rossmann"))
        XCTAssertEqual(CommandParser.parse("turn on captions"), .captions)
        XCTAssertEqual(CommandParser.parse("read this letter"), .read)
        XCTAssertEqual(CommandParser.parse("go back"), .back)
        XCTAssertNil(CommandParser.parse("banana"))
    }

    func testGermanCommands() {
        XCTAssertEqual(CommandParser.parse("Hilfe"), .help)
        XCTAssertEqual(CommandParser.parse("Ruf meine Tochter an"), .callFamily)
        XCTAssertEqual(CommandParser.parse("Wo bin ich?"), .whereAmI)
        XCTAssertEqual(CommandParser.parse("Ich habe mich verlaufen"), .guide)
        XCTAssertEqual(CommandParser.parse("Mit der U-Bahn nach Münchner Freiheit"), .ride(to: "Münchner Freiheit"))
        XCTAssertEqual(CommandParser.parse("Wo ist eine Apotheke")?.isFind, true)
        XCTAssertEqual(CommandParser.parse("Untertitel"), .captions)
        XCTAssertEqual(CommandParser.parse("Brief vorlesen"), .read)
        XCTAssertEqual(CommandParser.parse("zurück"), .back)
    }
}

private extension Destination {
    var isFind: Bool { if case .find = self { return true }; return false }
}

final class StoryTests: XCTestCase {
    func testEveryAnswerLeadsSomewhere() {
        let steps = Story.steps
        XCTAssertNotNil(steps[Story.start])
        for step in steps.values {
            XCTAssertFalse(step.answers.isEmpty, step.id)
            for a in step.answers {
                if case .step(let next) = a.then { XCTAssertNotNil(steps[next], "\(step.id) → \(next) is missing") }
            }
        }
    }

    func testEveryStepCanBeReachedFromTheStart() {
        let steps = Story.steps
        var seen: Set<String> = [], queue = [Story.start]
        while let id = queue.popLast() {
            guard seen.insert(id).inserted, let s = steps[id] else { continue }
            for a in s.answers { if case .step(let n) = a.then { queue.append(n) } }
        }
        XCTAssertEqual(seen, Set(steps.keys))
    }
}

final class VoicesTests: XCTestCase {
    func testNoveltyVoicesAreHidden() {
        XCTAssertTrue(Voices.isNovelty("com.apple.speech.synthesis.voice.Bahh"))
        XCTAssertTrue(Voices.isNovelty("com.apple.eloquence.en-US.Grandpa"))
        XCTAssertFalse(Voices.isNovelty("com.apple.voice.premium.en-US.Ava"))
        XCTAssertFalse(Voices.isNovelty("com.apple.voice.compact.de-DE.Anna"))
    }

    func testListedVoicesAreSortedByQuality() {
        for lang in ["en", "de"] {
            let ranks = Voices.list(for: lang).filter { !Voices.personal($0) }.map { Voices.rank($0.quality) }
            XCTAssertEqual(ranks, ranks.sorted(by: >), lang)
        }
    }

    func testPaceIsCalmByDefault() {
        XCTAssertLessThan(SpeechPace.calm.rate, SpeechPace.normal.rate)
        XCTAssertLessThan(SpeechPace.normal.rate, SpeechPace.quick.rate)
    }
}
