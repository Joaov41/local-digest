@preconcurrency import EventKit
import Foundation

final class CalendarSourceAdapter: SourceAdapter, @unchecked Sendable {
    let source: SourceKind = .calendar
    private let store = EKEventStore()

    func status() async -> SourceStatus {
        let current = EKEventStore.authorizationStatus(for: .event)
        return SourceStatus(source: source, permission: Self.permission(for: current), indexedCount: 0, isIndexing: false, message: nil)
    }

    func requestAccess() async -> SourceStatus {
        do { _ = try await store.requestFullAccessToEvents() }
        catch { return SourceStatus(source: source, permission: .denied, indexedCount: 0, isIndexing: false, message: error.localizedDescription) }
        return await status()
    }

    func fetchRecords() async throws -> [IndexedRecord] {
        guard await status().permission == .authorized else { throw SourceAdapterError.permissionDenied(source, "Allow Calendar access in System Settings.") }
        // EventKit caps a single event predicate at four years. Walk the
        // practical calendar range in smaller windows so indexing is not just
        // a recent-events fetch. The stable occurrence date prevents recurring
        // events from overwriting one another in the local index.
        var recordsByID: [String: IndexedRecord] = [:]
        for range in Self.historyRanges() {
            let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
            for event in store.events(matching: predicate) {
                let occurrence = Int64(event.startDate.timeIntervalSince1970)
                let baseID = event.eventIdentifier ?? event.calendarItemIdentifier
                let id = "event-\(baseID)-\(occurrence)"
                recordsByID[id] = IndexedRecord(id: id, source: .calendar, title: event.title ?? "Untitled event", body: [event.location, event.notes].compactMap { $0 }.joined(separator: "\n"), author: event.calendar?.title, participants: event.attendees?.compactMap { $0.name } ?? [], timestamp: event.startDate, url: event.url, threadID: nil)
            }
        }
        return Array(recordsByID.values)
    }

    static func historyRanges(calendar: Calendar = Calendar(identifier: .gregorian)) -> [DateInterval] {
        guard let first = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1)),
              let last = calendar.date(from: DateComponents(year: 2200, month: 1, day: 1)) else { return [] }
        var ranges: [DateInterval] = []
        var start = first
        while start < last {
            let end = min(calendar.date(byAdding: .year, value: 4, to: start) ?? last, last)
            ranges.append(DateInterval(start: start, end: end))
            start = end
        }
        return ranges
    }

    private static func permission(for status: EKAuthorizationStatus) -> SourcePermission {
        switch status {
        case .fullAccess: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        case .writeOnly: .denied
        @unknown default: .unavailable
        }
    }
}

final class RemindersSourceAdapter: SourceAdapter, @unchecked Sendable {
    let source: SourceKind = .reminders
    private let store = EKEventStore()

    func status() async -> SourceStatus {
        let current = EKEventStore.authorizationStatus(for: .reminder)
        return SourceStatus(source: source, permission: Self.permission(for: current), indexedCount: 0, isIndexing: false, message: nil)
    }

    func requestAccess() async -> SourceStatus {
        do { _ = try await store.requestFullAccessToReminders() }
        catch { return SourceStatus(source: source, permission: .denied, indexedCount: 0, isIndexing: false, message: error.localizedDescription) }
        return await status()
    }

    func fetchRecords() async throws -> [IndexedRecord] {
        guard await status().permission == .authorized else { throw SourceAdapterError.permissionDenied(source, "Allow Reminders access in System Settings.") }
        let predicate = store.predicateForReminders(in: nil)
        var records: [IndexedRecord] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                records = (reminders ?? []).map { reminder in
                    IndexedRecord(id: "reminder-\(reminder.calendarItemIdentifier)", source: .reminders, title: reminder.title, body: reminder.notes ?? "", author: reminder.calendar?.title, participants: [], timestamp: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantPast, url: nil, threadID: nil)
                }
                continuation.resume()
            }
        }
        return records
    }

    private static func permission(for status: EKAuthorizationStatus) -> SourcePermission {
        switch status {
        case .fullAccess: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        case .writeOnly: .denied
        @unknown default: .unavailable
        }
    }
}
