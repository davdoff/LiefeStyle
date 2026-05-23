import Foundation

// MARK: - Public Output Types

enum SchedulingDecision {
    case add(EventDraft)
    case conflict(reason: String, alternatives: [EventDraft])
    case suggestAlternative([EventDraft])
}

struct EventDraft {
    var title: String
    var start: Date
    var end: Date
    var categoryName: String
}

enum AIServiceError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:          return "The AI returned an unexpected response."
        case .apiError(let code):       return "API error (HTTP \(code))."
        case .networkError(let error):  return error.localizedDescription
        }
    }
}

// MARK: - Service

struct AIService {
    let apiKey: String
    private let scheduler = SchedulerService()

    /// Swap this in tests to avoid hitting the real API.
    var _callAPI: ((String) async throws -> String)?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func scheduleEvent(
        description: String,
        events: [Event],
        preferences: UserPreferences,
        categories: [Category]
    ) async throws -> SchedulingDecision {
        let message = buildUserMessage(
            description: description,
            events: events,
            preferences: preferences,
            categories: categories
        )
        let rawJSON = try await (_callAPI?(message) ?? callClaude(userMessage: message))
        return try parseResponse(rawJSON)
    }
}

// MARK: - Message Builder

private extension AIService {
    func buildUserMessage(
        description: String,
        events: [Event],
        preferences: UserPreferences,
        categories: [Category]
    ) -> String {
        let now = Date.now
        let window = now...now.addingTimeInterval(72 * 3600)
        let prefsLine    = scheduler.compactPreferenceString(from: preferences, priorityCategories: categories)
        let scheduleLine = scheduler.compactScheduleString(for: events, in: window, preferences: preferences)

        return """
        Prefs: \(prefsLine)

        Schedule (next 72h):
        \(scheduleLine)

        Request: \(description)
        """
    }
}

// MARK: - Network

private extension AIService {
    func callClaude(userMessage: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey,        forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",  forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body = ClaudeRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 300,
            system: AIService.systemPrompt,
            messages: [.init(role: "user", content: userMessage)]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AIServiceError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw AIServiceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw AIServiceError.apiError(statusCode: http.statusCode) }

        let envelope = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        guard let text = envelope.content.first?.text else { throw AIServiceError.invalidResponse }
        return text
    }
}

// MARK: - Response Parsing

private extension AIService {
    func parseResponse(_ json: String) throws -> SchedulingDecision {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawDecision.self, from: data)
        else { throw AIServiceError.invalidResponse }

        let iso = ISO8601DateFormatter()

        func draft(title: String, start: String, end: String, category: String) throws -> EventDraft {
            guard let s = iso.date(from: start), let e = iso.date(from: end) else {
                throw AIServiceError.invalidResponse
            }
            return EventDraft(title: title, start: s, end: e, categoryName: category)
        }

        func slot(start: String, end: String) throws -> EventDraft {
            guard let s = iso.date(from: start), let e = iso.date(from: end) else {
                throw AIServiceError.invalidResponse
            }
            return EventDraft(title: "", start: s, end: e, categoryName: "")
        }

        switch raw.action {
        case "add":
            guard let ev = raw.event else { throw AIServiceError.invalidResponse }
            return .add(try draft(title: ev.title, start: ev.start, end: ev.end, category: ev.category))

        case "conflict":
            let alts = try raw.alternatives.map { try slot(start: $0.start, end: $0.end) }
            return .conflict(reason: raw.conflict_reason ?? "", alternatives: alts)

        case "suggest_alternative":
            let alts = try raw.alternatives.map { try slot(start: $0.start, end: $0.end) }
            return .suggestAlternative(alts)

        default:
            throw AIServiceError.invalidResponse
        }
    }
}

// MARK: - Private Codable Types

private struct ClaudeRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ClaudeAPIResponse: Decodable {
    let content: [ContentBlock]
    struct ContentBlock: Decodable { let text: String }
}

private struct RawDecision: Decodable {
    let action: String
    let event: RawEvent?
    let conflict_reason: String?
    let alternatives: [RawSlot]

    struct RawEvent: Decodable {
        let title: String
        let start: String
        let end: String
        let category: String
    }
    struct RawSlot: Decodable {
        let start: String
        let end: String
    }
}
