import Foundation

typealias ProposedInterval = DateInterval
typealias TimeSlot = DateInterval

struct SchedulerService {

    // MARK: - 1. Conflict Detection

    /// Returns every existing event that overlaps the proposal, respecting buffer on both sides.
    /// Missed events are ignored — they no longer occupy time.
    func conflicts(
        for proposal: ProposedInterval,
        in events: [Event],
        bufferMinutes: Int
    ) -> [Event] {
        let buffer = TimeInterval(bufferMinutes * 60)
        return events.filter { event in
            guard event.status != .missed else { return false }
            let expanded = DateInterval(
                start: event.startTime.addingTimeInterval(-buffer),
                end: event.endTime.addingTimeInterval(buffer)
            )
            return expanded.intersects(proposal)
        }
    }

    // MARK: - 2. Free Slot Finder

    /// Returns available time windows of at least `minutes` duration within the date range.
    /// Respects working hours, buffer after each event, and avoid-scheduling blocks.
    func freeSlots(
        duration minutes: Int,
        in dateRange: ClosedRange<Date>,
        events: [Event],
        preferences: UserPreferences
    ) -> [TimeSlot] {
        let calendar = Calendar.current
        let required = TimeInterval(minutes * 60)
        let buffer = TimeInterval(preferences.bufferMinutes * 60)
        var result: [TimeSlot] = []

        var day = calendar.startOfDay(for: dateRange.lowerBound)
        let lastDay = calendar.startOfDay(for: dateRange.upperBound)

        while day <= lastDay {
            guard
                let workStart = calendar.date(bySettingHour: preferences.workStartHour, minute: 0, second: 0, of: day),
                let workEnd   = calendar.date(bySettingHour: preferences.workEndHour,   minute: 0, second: 0, of: day)
            else {
                day = calendar.date(byAdding: .day, value: 1, to: day)!
                continue
            }

            var blocked: [DateInterval] = []
            let weekday = calendar.component(.weekday, from: day)

            // Events block start → end + buffer
            for event in events where event.status != .missed && calendar.isDate(event.startTime, inSameDayAs: day) {
                blocked.append(DateInterval(
                    start: event.startTime,
                    end:   event.endTime.addingTimeInterval(buffer)
                ))
            }

            // Avoid-scheduling blocks
            for avoid in preferences.avoidScheduling {
                guard avoid.weekdays.isEmpty || avoid.weekdays.contains(weekday) else { continue }
                guard
                    let s = calendar.date(bySettingHour: avoid.startHour, minute: avoid.startMinute, second: 0, of: day),
                    let e = calendar.date(bySettingHour: avoid.endHour,   minute: avoid.endMinute,   second: 0, of: day)
                else { continue }
                blocked.append(DateInterval(start: s, end: e))
            }

            blocked.sort { $0.start < $1.start }
            let merged = merge(blocked)

            // Walk through the merged blocks and collect gaps within working hours
            var cursor = workStart
            for block in merged {
                let blockStart = max(block.start, workStart)
                let blockEnd   = min(block.end,   workEnd)

                if blockStart > cursor && blockStart.timeIntervalSince(cursor) >= required {
                    result.append(DateInterval(start: cursor, end: blockStart))
                }
                if blockEnd > cursor { cursor = blockEnd }
            }

            // Remaining time after the last block
            if workEnd > cursor && workEnd.timeIntervalSince(cursor) >= required {
                result.append(DateInterval(start: cursor, end: workEnd))
            }

            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        return result
    }

    // MARK: - 3. Compact Schedule String

    /// Converts events to the token-efficient format sent to Claude.
    /// Example output:
    ///   MON 09:00-10:00[Work] 12:00-13:00[Meal] FREE:14:00-18:00
    ///   TUE FREE:09:00-18:00
    func compactScheduleString(
        for events: [Event],
        in dateRange: ClosedRange<Date>,
        preferences: UserPreferences
    ) -> String {
        let calendar = Calendar.current
        let timeFmt = makeFormatter("HH:mm")
        let dayFmt  = makeFormatter("EEE")
        let minFree: TimeInterval = 30 * 60
        var lines: [String] = []

        var day = calendar.startOfDay(for: dateRange.lowerBound)
        let lastDay = calendar.startOfDay(for: dateRange.upperBound)

        while day <= lastDay {
            guard
                let workStart = calendar.date(bySettingHour: preferences.workStartHour, minute: 0, second: 0, of: day),
                let workEnd   = calendar.date(bySettingHour: preferences.workEndHour,   minute: 0, second: 0, of: day)
            else {
                day = calendar.date(byAdding: .day, value: 1, to: day)!
                continue
            }

            let abbr = dayFmt.string(from: day).uppercased()
            let dayEvents = events
                .filter { $0.status != .missed && calendar.isDate($0.startTime, inSameDayAs: day) }
                .sorted { $0.startTime < $1.startTime }

            if dayEvents.isEmpty {
                lines.append("\(abbr) FREE:\(timeFmt.string(from: workStart))-\(timeFmt.string(from: workEnd))")
            } else {
                var parts: [String] = []
                for event in dayEvents {
                    let cat = event.category?.name ?? "—"
                    parts.append("\(timeFmt.string(from: event.startTime))-\(timeFmt.string(from: event.endTime))[\(cat)]")
                }
                if let last = dayEvents.last, workEnd.timeIntervalSince(last.endTime) >= minFree {
                    parts.append("FREE:\(timeFmt.string(from: last.endTime))-\(timeFmt.string(from: workEnd))")
                }
                lines.append("\(abbr) \(parts.joined(separator: " "))")
            }

            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 4. Preference String Builder

    /// Builds the compact string stored on UserPreferences and prepended to every Claude API call.
    /// Call this only when the user saves preference changes, not on every API call.
    func compactPreferenceString(
        from preferences: UserPreferences,
        priorityCategories: [Category]
    ) -> String {
        let priority = priorityCategories
            .filter { preferences.priorityCategoryIDs.contains($0.id) }
            .map(\.name)

        var parts = [
            "WorkHours=\(preferences.workStartHour)-\(preferences.workEndHour)",
            "Buffer=\(preferences.bufferMinutes)min",
            "MealsPerDay=\(preferences.mealsPerDay)",
            "AILevel=\(preferences.aiAggressiveness)"
        ]
        if !priority.isEmpty {
            parts.insert("Priority=[\(priority.joined(separator: ","))]", at: 2)
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Private Helpers

    private func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        guard !intervals.isEmpty else { return [] }
        var result = [intervals[0]]
        for interval in intervals.dropFirst() {
            let last = result[result.count - 1]
            if interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private func makeFormatter(_ format: String) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.dateFormat = format
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }
}
