import Foundation

struct DatePhraseParser: Sendable {
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    /// A bounded list of observed relative-date typos. Corrections are
    /// applied only to complete temporal tokens, never to arbitrary search
    /// language or concrete dates.
    private static let temporalTypoAllowlist: [String: String] = [
        "toyda": "today"
    ]

    static let temporalTypoTokens: Set<String> = Set(temporalTypoAllowlist.keys)

    init(calendar: Calendar = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
    }

    func parse(_ text: String, referenceDate: Date? = nil) -> DateParseResult? {
        let normalized = Self.normalizeTemporalTypos(in: text.lowercased())
        let reference = referenceDate ?? now()
        if let explicit = parseExplicitDate(normalized, reference: reference) {
            return explicit
        }
        if normalized.contains("last night") {
            let day = calendar.date(byAdding: .day, value: -1, to: reference) ?? reference
            let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
            let end = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: reference) ?? reference
            return DateParseResult(start: start, end: end, phrase: "last night")
        }
        if normalized.contains("yesterday") {
            let day = calendar.date(byAdding: .day, value: -1, to: reference) ?? reference
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? reference
            return DateParseResult(start: start, end: end, phrase: "yesterday")
        }
        if normalized.contains("today") {
            let start = calendar.startOfDay(for: reference)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? reference
            return DateParseResult(start: start, end: end, phrase: "today")
        }
        if normalized.contains("tomorrow") {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)) ?? reference
            let end = calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow
            return DateParseResult(start: tomorrow, end: end, phrase: "tomorrow")
        }
        if normalized.contains("tonight") {
            let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: reference) ?? reference
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)) ?? reference
            let end = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow) ?? tomorrow
            return DateParseResult(start: start, end: end, phrase: "tonight")
        }
        if normalized.contains("last weekend") {
            return weekendInterval(reference: reference, offset: -1, phrase: "last weekend")
        }
        if normalized.contains("this weekend") || normalized == "weekend" || normalized.contains(" weekend") {
            return weekendInterval(reference: reference, offset: 0, phrase: "weekend")
        }
        if normalized.contains("this morning") {
            let start = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: reference) ?? reference
            let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: reference) ?? reference
            return DateParseResult(start: start, end: end, phrase: "this morning")
        }
        if normalized.contains("this week") {
            let interval = calendar.dateInterval(of: .weekOfYear, for: reference)
            if let interval { return DateParseResult(start: interval.start, end: interval.end, phrase: "this week") }
        }
        if normalized.contains("next week"),
           let interval = calendar.dateInterval(of: .weekOfYear, for: reference),
           let start = calendar.date(byAdding: .weekOfYear, value: 1, to: interval.start),
           let end = calendar.date(byAdding: .weekOfYear, value: 1, to: interval.end) {
            return DateParseResult(start: start, end: end, phrase: "next week")
        }
        if normalized.contains("last week"),
           let interval = calendar.dateInterval(of: .weekOfYear, for: reference),
           let start = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start),
           let end = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.end) {
            return DateParseResult(start: start, end: end, phrase: "last week")
        }
        if let weekday = parseWeekday(normalized, reference: reference) {
            return weekday
        }
        return nil
    }

    private func weekendInterval(reference: Date, offset: Int, phrase: String) -> DateParseResult {
        let day = calendar.startOfDay(for: reference)
        let weekday = calendar.component(.weekday, from: day)
        let daysUntilSaturday: Int
        if weekday == 7 || weekday == 1 {
            daysUntilSaturday = weekday == 7 ? 0 : -1
        } else {
            daysUntilSaturday = 7 - weekday
        }
        let currentWeekend = calendar.date(byAdding: .day, value: daysUntilSaturday, to: day) ?? day
        let start = calendar.date(byAdding: .day, value: offset * 7, to: currentWeekend) ?? currentWeekend
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? start
        return DateParseResult(start: start, end: end, phrase: phrase)
    }

    private static func normalizeTemporalTypos(in text: String) -> String {
        temporalTypoAllowlist.reduce(text) { text, entry in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: entry.key) + "\\b"
            return text.replacingOccurrences(of: pattern, with: entry.value, options: .regularExpression)
        }
    }

    private func parseWeekday(_ text: String, reference: Date) -> DateParseResult? {
        let pattern = #"\b(last|next|this)?\s*(monday|mon|tuesday|tue|wednesday|wed|thursday|thu|friday|fri|saturday|sat|sunday|sun)\b"#
        guard let match = firstMatch(pattern, in: text),
              let weekdayText = capture(match, in: text, at: 2),
              let target = weekdayNumber(for: weekdayText) else { return nil }
        let modifier = capture(match, in: text, at: 1)?.lowercased()
        let currentDay = calendar.startOfDay(for: reference)
        let current = calendar.component(.weekday, from: currentDay)
        let delta = (target - current + 7) % 7
        let offset: Int
        switch modifier {
        case "next": offset = delta == 0 ? 7 : delta
        case "last": offset = delta == 0 ? -7 : delta - 7
        case "this":
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: currentDay)?.start ?? currentDay
            let weekStartDay = calendar.component(.weekday, from: weekStart)
            offset = (target - weekStartDay + 7) % 7
        default: offset = delta
        }
        guard let date = calendar.date(byAdding: .day, value: offset, to: currentDay) else { return nil }
        return dayInterval(for: date, phrase: String(text[Range(match.range, in: text)!]))
    }

    private func parseExplicitDate(_ text: String, reference: Date) -> DateParseResult? {
        let monthPattern = #"\b(january|jan(?:uary)?|february|feb(?:ruary)?|march|mar(?:ch)?|april|apr(?:il)?|may|june|jun(?:e)?|july|jul(?:y)?|august|aug(?:ust)?|september|sep(?:tember)?|october|oct(?:ober)?|november|nov(?:ember)?|december|dec(?:ember)?)\s+([0-9]{1,2})(?:st|nd|rd|th)?(?:\s*,?\s*([0-9]{4}))?\b"#
        if let match = firstMatch(monthPattern, in: text),
           let monthName = capture(match, in: text, at: 1),
           let dayText = capture(match, in: text, at: 2),
           let day = Int(dayText) {
            let month = monthNumber(for: monthName)
            let year = Int(capture(match, in: text, at: 3) ?? "") ?? calendar.component(.year, from: reference)
            if let month, let date = validatedDate(year: year, month: month, day: day) {
                return dayInterval(for: date, phrase: String(text[Range(match.range, in: text)!]))
            }
        }

        // Day-first numeric dates are common in the user's locale. A missing
        // year means the year of the fixed reference date used by the planner.
        let dayFirstPattern = #"\b([0-9]{1,2})[/.]([0-9]{1,2})(?:[/.]([0-9]{4}))?\b"#
        if let match = firstMatch(dayFirstPattern, in: text),
           let day = Int(capture(match, in: text, at: 1) ?? ""),
           let month = Int(capture(match, in: text, at: 2) ?? "") {
            let year = Int(capture(match, in: text, at: 3) ?? "") ?? calendar.component(.year, from: reference)
            if let date = validatedDate(year: year, month: month, day: day) {
                return dayInterval(for: date, phrase: String(text[Range(match.range, in: text)!]))
            }
            return nil
        }

        let dayFirstDashPattern = #"\b([0-9]{1,2})-([0-9]{1,2})-([0-9]{4})\b"#
        if let match = firstMatch(dayFirstDashPattern, in: text),
           let day = Int(capture(match, in: text, at: 1) ?? ""),
           let month = Int(capture(match, in: text, at: 2) ?? ""),
           let year = Int(capture(match, in: text, at: 3) ?? ""),
           let date = validatedDate(year: year, month: month, day: day) {
            return dayInterval(for: date, phrase: String(text[Range(match.range, in: text)!]))
        }

        let isoPattern = #"\b([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})\b"#
        if let match = firstMatch(isoPattern, in: text),
           let year = Int(capture(match, in: text, at: 1) ?? ""),
           let month = Int(capture(match, in: text, at: 2) ?? ""),
           let day = Int(capture(match, in: text, at: 3) ?? ""),
           let date = validatedDate(year: year, month: month, day: day) {
            return dayInterval(for: date, phrase: String(text[Range(match.range, in: text)!]))
        }
        return nil
    }

    private func validatedDate(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.era = 1
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard resolved.era == 1, resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
        return date
    }

    private func dayInterval(for date: Date, phrase: String) -> DateParseResult {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateParseResult(start: start, end: end, phrase: phrase)
    }

    private func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func capture(_ match: NSTextCheckingResult, in text: String, at index: Int) -> String? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private func monthNumber(for value: String) -> Int? {
        switch String(value.prefix(3)) {
        case "jan": 1
        case "feb": 2
        case "mar": 3
        case "apr": 4
        case "may": 5
        case "jun": 6
        case "jul": 7
        case "aug": 8
        case "sep": 9
        case "oct": 10
        case "nov": 11
        case "dec": 12
        default: nil
        }
    }

    private func weekdayNumber(for value: String) -> Int? {
        switch String(value.prefix(3)) {
        case "sun": 1
        case "mon": 2
        case "tue": 3
        case "wed": 4
        case "thu": 5
        case "fri": 6
        case "sat": 7
        default: nil
        }
    }
}
