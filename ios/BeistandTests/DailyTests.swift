import XCTest
@testable import Beistand

final class DailyTests: XCTestCase {
    override func setUp() { Lang.override = "en" }
    override func tearDown() { Lang.override = nil }

    func testColourNames() {
        XCTAssertEqual(ColorName.name(r: 0.85, g: 0.1, b: 0.1), "red")
        XCTAssertEqual(ColorName.name(r: 0.1, g: 0.15, b: 0.45), "dark blue")
        XCTAssertEqual(ColorName.name(r: 0.2, g: 0.6, b: 0.25), "green")
        XCTAssertEqual(ColorName.name(r: 0.45, g: 0.28, b: 0.12), "brown")
        XCTAssertEqual(ColorName.name(r: 0.95, g: 0.85, b: 0.2), "yellow")
        XCTAssertEqual(ColorName.name(r: 0.05, g: 0.05, b: 0.05), "black")
        XCTAssertEqual(ColorName.name(r: 0.97, g: 0.97, b: 0.96), "white")
        XCTAssertEqual(ColorName.name(r: 0.5, g: 0.5, b: 0.52), "grey")
        XCTAssertEqual(ColorName.name(r: 0.98, g: 0.7, b: 0.8), "pink")
        Lang.override = "de"
        XCTAssertEqual(ColorName.name(r: 0.1, g: 0.15, b: 0.45), "dunkelblau")
    }

    func testIsThisMyTrain() {
        XCTAssertEqual(TrainCheck.verdict(["U3 Moosach"], line: "U3", direction: "Moosach"), .yours)
        XCTAssertEqual(TrainCheck.verdict(["U 6", "Garching-Forschungszentrum"], line: "U3", direction: "Moosach"), .otherLine("U6"))
        XCTAssertEqual(TrainCheck.verdict(["MOOSACH"], line: "U3", direction: "Moosach"), .yours)          // direction only
        XCTAssertEqual(TrainCheck.verdict(["Tram 19 Pasing"], line: "19", direction: "Pasing"), .yours)
        XCTAssertNil(TrainCheck.verdict(["Bitte zurückbleiben"], line: "U3", direction: "Moosach"))
        XCTAssertEqual(TrainCheck.lines(in: "S8 Flughafen · U2 Feldmoching"), ["s8", "u2"])
    }

    func testMedicineSchedule() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let pill = Medicine(name: "Ramipril", times: [DateComponents(hour: 8, minute: 0), DateComponents(hour: 20, minute: 0)])
        let morning = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 8, minute: 30))!
        let due = MedicineSchedule.current([pill], taken: [], now: morning, calendar: cal)!
        XCTAssertTrue(due.due)                                                            // 8:00 not taken yet
        let taken: Set<String> = [MedicineSchedule.key(pill, due.1)]
        let next = MedicineSchedule.current([pill], taken: taken, now: morning, calendar: cal)!
        XCTAssertFalse(next.due)
        XCTAssertEqual(cal.component(.hour, from: next.1), 20)                            // next is the evening dose
        let late = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 22, minute: 30))!
        XCTAssertTrue(MedicineSchedule.current([pill], taken: [], now: late, calendar: cal)!.due)   // 20:00 missed, still shown
        let tooLate = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 30))!
        XCTAssertNil(MedicineSchedule.current([pill], taken: [], now: tooLate, calendar: cal))       // > 3 h: no longer shown
        let veryLate = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 0, minute: 30))!
        XCTAssertFalse(MedicineSchedule.current([pill], taken: [], now: veryLate, calendar: cal)!.due) // a new day: next is 8:00
    }

    func testCheckInOncePerDayFromSeven() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func at(_ d: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))! }
        XCTAssertFalse(CheckIn.shouldAsk(now: at(10, 6), lastAnswered: nil, calendar: cal))
        XCTAssertTrue(CheckIn.shouldAsk(now: at(10, 8), lastAnswered: at(9, 9), calendar: cal))
        XCTAssertFalse(CheckIn.shouldAsk(now: at(10, 15), lastAnswered: at(10, 8), calendar: cal))
    }

    func testDayAnchor() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let mon = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 15))!
        let s = DayAnchor.sentence(now: mon, place: "You are at home.", calendar: cal)
        XCTAssertTrue(s.contains("Monday"), s)
        XCTAssertTrue(s.contains("It is afternoon."), s)
        XCTAssertTrue(s.hasSuffix("You are at home."), s)
    }
}
