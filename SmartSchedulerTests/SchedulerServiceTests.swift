import XCTest
import SwiftData
@testable import SmartScheduler

final class SchedulerServiceTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let service = SchedulerService()

    override func setUp() {
        super.setUp()
        let schema = Schema([Event.self, Category.self, Meal.self, UserPreferences.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Builds a Date for today at the given hour:minute.
    func at(_ hour: Int, _ minute: Int = 0, daysFromNow: Int = 0) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour; comps.minute = minute; comps.second = 0
        var d = Calendar.current.date(from: comps)!
        if daysFromNow != 0 { d = Calendar.current.date(byAdding: .day, value: daysFromNow, to: d)! }
        return d
    }

    func makeEvent(start: Date, end: Date, status: EventStatus = .pending) -> Event {
        let e = Event(title: "Test", startTime: start, endTime: end)
        e.status = status
        context.insert(e)
        return e
    }

    func makePrefs() -> UserPreferences {
        let p = UserPreferences() // workStart=9, workEnd=18, buffer=15
        context.insert(p)
        return p
    }

    // MARK: - Conflict Detection

    func testNoConflictEmptySchedule() {
        let proposal = DateInterval(start: at(10), end: at(11))
        XCTAssertTrue(service.conflicts(for: proposal, in: [], bufferMinutes: 15).isEmpty)
    }

    func testDirectOverlapDetected() {
        let event = makeEvent(start: at(9), end: at(10))
        let proposal = DateInterval(start: at(9, 30), end: at(10, 30))
        XCTAssertEqual(service.conflicts(for: proposal, in: [event], bufferMinutes: 15).count, 1)
    }

    func testBufferOverlapDetected() {
        // Event ends 10:00, proposal starts 10:05, buffer 15 min → conflict
        let event = makeEvent(start: at(9), end: at(10))
        let proposal = DateInterval(start: at(10, 5), end: at(11))
        XCTAssertEqual(service.conflicts(for: proposal, in: [event], bufferMinutes: 15).count, 1)
    }

    func testBufferGapClear() {
        // Event ends 10:00, proposal starts 10:20, buffer 15 min → no conflict
        let event = makeEvent(start: at(9), end: at(10))
        let proposal = DateInterval(start: at(10, 20), end: at(11))
        XCTAssertTrue(service.conflicts(for: proposal, in: [event], bufferMinutes: 15).isEmpty)
    }

    func testMissedEventIgnored() {
        let event = makeEvent(start: at(9), end: at(10), status: .missed)
        let proposal = DateInterval(start: at(9, 30), end: at(10, 30))
        XCTAssertTrue(service.conflicts(for: proposal, in: [event], bufferMinutes: 15).isEmpty)
    }

    // MARK: - Free Slot Finder

    func testFreeSlotsEmptyDay() {
        let prefs = makePrefs()
        let today = Calendar.current.startOfDay(for: Date())
        let slots = service.freeSlots(duration: 60, in: today...today, events: [], preferences: prefs)
        // Should be one slot: 09:00–18:00 (9 hours)
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].duration, 9 * 3600, accuracy: 1)
    }

    func testFreeSlotsAroundEvents() {
        let prefs = makePrefs() // workStart=9, workEnd=18, buffer=15
        let today = Calendar.current.startOfDay(for: Date())
        let e1 = makeEvent(start: at(10), end: at(11))
        let e2 = makeEvent(start: at(13), end: at(14))
        let slots = service.freeSlots(duration: 30, in: today...today, events: [e1, e2], preferences: prefs)
        // 09:00–10:00 | 11:15–13:00 | 14:15–18:00 → 3 slots
        XCTAssertEqual(slots.count, 3)
    }

    func testNoFreeSlotsFullDay() {
        let prefs = makePrefs()
        let today = Calendar.current.startOfDay(for: Date())
        let event = makeEvent(start: at(9), end: at(18))
        let slots = service.freeSlots(duration: 30, in: today...today, events: [event], preferences: prefs)
        XCTAssertTrue(slots.isEmpty)
    }

    func testFreeSlotsSpanMultipleDays() {
        let prefs = makePrefs()
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        // No events — expect one 9-hour slot per day
        let slots = service.freeSlots(duration: 60, in: today...tomorrow, events: [], preferences: prefs)
        XCTAssertEqual(slots.count, 2)
    }

    // MARK: - Compact Schedule String

    func testCompactStringContainsEventBlock() {
        let prefs = makePrefs()
        let today = Calendar.current.startOfDay(for: Date())
        let event = makeEvent(start: at(10), end: at(11))
        let output = service.compactScheduleString(for: [event], in: today...today, preferences: prefs)
        XCTAssertTrue(output.contains("10:00-11:00"))
    }

    func testCompactStringFreeBlock() {
        let prefs = makePrefs() // workEnd = 18
        let today = Calendar.current.startOfDay(for: Date())
        let event = makeEvent(start: at(9), end: at(11))
        let output = service.compactScheduleString(for: [event], in: today...today, preferences: prefs)
        // 7 hours free after 11:00 → should show FREE block
        XCTAssertTrue(output.contains("FREE:11:00-18:00"))
    }

    func testCompactStringEmptyDayShowsFree() {
        let prefs = makePrefs()
        let today = Calendar.current.startOfDay(for: Date())
        let output = service.compactScheduleString(for: [], in: today...today, preferences: prefs)
        XCTAssertTrue(output.contains("FREE:09:00-18:00"))
    }

    func testCompactStringMissedEventSkipped() {
        let prefs = makePrefs()
        let today = Calendar.current.startOfDay(for: Date())
        let event = makeEvent(start: at(10), end: at(11), status: .missed)
        let output = service.compactScheduleString(for: [event], in: today...today, preferences: prefs)
        // Missed event should not appear — day should show as fully free
        XCTAssertTrue(output.contains("FREE:09:00-18:00"))
        XCTAssertFalse(output.contains("10:00-11:00"))
    }

    // MARK: - Preference String Builder

    func testPreferenceStringContainsWorkHours() {
        let prefs = makePrefs()
        let output = service.compactPreferenceString(from: prefs, priorityCategories: [])
        XCTAssertTrue(output.contains("WorkHours=9-18"))
    }

    func testPreferenceStringContainsBuffer() {
        let prefs = makePrefs()
        let output = service.compactPreferenceString(from: prefs, priorityCategories: [])
        XCTAssertTrue(output.contains("Buffer=15min"))
    }

    func testPreferenceStringIncludesPriorityCategories() {
        let prefs = makePrefs()
        let cat = Category(name: "Work", colorHex: "#FF0000")
        context.insert(cat)
        prefs.priorityCategoryIDs = [cat.id]
        let output = service.compactPreferenceString(from: prefs, priorityCategories: [cat])
        XCTAssertTrue(output.contains("Priority=[Work]"))
    }
}
