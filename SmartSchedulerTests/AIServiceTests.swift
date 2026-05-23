import XCTest
import SwiftData
@testable import SmartScheduler

final class AIServiceTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    // Fixed future dates — stable regardless of when tests run
    let startISO = "2030-06-15T09:00:00Z"
    let endISO   = "2030-06-15T10:00:00Z"
    let altISO   = "2030-06-15T14:00:00Z"
    let altEndISO = "2030-06-15T15:00:00Z"

    override func setUp() {
        super.setUp()
        let schema = Schema([Event.self, Category.self, Meal.self, UserPreferences.self])
        container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    func makeService(returning json: String) -> AIService {
        var service = AIService(apiKey: "test-key")
        service._callAPI = { _ in json }
        return service
    }

    func makePrefs() -> UserPreferences {
        let p = UserPreferences()
        context.insert(p)
        return p
    }

    func addJSON() -> String {
        """
        {
          "action": "add",
          "event": { "title": "Gym", "start": "\(startISO)", "end": "\(endISO)", "category": "Health" },
          "conflict_reason": null,
          "alternatives": []
        }
        """
    }

    // MARK: - Message Building

    func testBuildsCorrectUserMessage() async throws {
        var captured = ""
        var service = AIService(apiKey: "test-key")
        service._callAPI = { msg in
            captured = msg
            return self.addJSON()
        }
        let prefs = makePrefs()
        _ = try await service.scheduleEvent(description: "gym tomorrow morning", events: [], preferences: prefs, categories: [])

        XCTAssertTrue(captured.contains("gym tomorrow morning"), "Description missing from message")
        XCTAssertTrue(captured.contains("WorkHours=9-18"),       "Prefs missing from message")
        XCTAssertTrue(captured.contains("Schedule (next 72h)"),  "Schedule header missing")
    }

    // MARK: - Response Parsing

    func testParsesAddDecision() async throws {
        let decision = try await makeService(returning: addJSON())
            .scheduleEvent(description: "gym", events: [], preferences: makePrefs(), categories: [])

        guard case .add(let draft) = decision else { XCTFail("Expected .add, got \(decision)"); return }
        XCTAssertEqual(draft.title, "Gym")
        XCTAssertEqual(draft.categoryName, "Health")
    }

    func testParsesConflictDecision() async throws {
        let json = """
        {
          "action": "conflict",
          "event": null,
          "conflict_reason": "Overlaps with Work 09:00-10:00",
          "alternatives": [{ "start": "\(altISO)", "end": "\(altEndISO)" }]
        }
        """
        let decision = try await makeService(returning: json)
            .scheduleEvent(description: "gym", events: [], preferences: makePrefs(), categories: [])

        guard case .conflict(let reason, let alts) = decision else { XCTFail("Expected .conflict"); return }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(alts.count, 1)
    }

    func testParsesSuggestAlternativeDecision() async throws {
        let json = """
        {
          "action": "suggest_alternative",
          "event": null,
          "conflict_reason": null,
          "alternatives": [
            { "start": "\(startISO)", "end": "\(endISO)" },
            { "start": "\(altISO)", "end": "\(altEndISO)" }
          ]
        }
        """
        let decision = try await makeService(returning: json)
            .scheduleEvent(description: "gym sometime", events: [], preferences: makePrefs(), categories: [])

        guard case .suggestAlternative(let alts) = decision else { XCTFail("Expected .suggestAlternative"); return }
        XCTAssertEqual(alts.count, 2)
    }

    func testThrowsOnMalformedJSON() async {
        let service = makeService(returning: "not json at all {{{}}")
        do {
            _ = try await service.scheduleEvent(description: "gym", events: [], preferences: makePrefs(), categories: [])
            XCTFail("Should have thrown")
        } catch AIServiceError.invalidResponse {
            // expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testThrowsOnUnknownAction() async {
        let json = """
        { "action": "teleport", "event": null, "conflict_reason": null, "alternatives": [] }
        """
        let service = makeService(returning: json)
        do {
            _ = try await service.scheduleEvent(description: "gym", events: [], preferences: makePrefs(), categories: [])
            XCTFail("Should have thrown")
        } catch AIServiceError.invalidResponse {
            // expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testISO8601DateParsing() async throws {
        let decision = try await makeService(returning: addJSON())
            .scheduleEvent(description: "gym", events: [], preferences: makePrefs(), categories: [])

        guard case .add(let draft) = decision else { XCTFail("Expected .add"); return }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: draft.start)
        XCTAssertEqual(comps.year,  2030)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day,   15)
        XCTAssertEqual(comps.hour,  9)
        XCTAssertEqual(comps.minute, 0)
    }
}
