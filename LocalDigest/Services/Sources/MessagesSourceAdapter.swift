import Foundation
import SQLite3

final class MessagesSourceAdapter: SourceAdapter, @unchecked Sendable {
    let source: SourceKind = .messages
    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    let refreshCapability: SourceRefreshCapability = .incremental("ROWID/date watermark with a 10,000-row and seven-day overlap; Full Rebuild reconciles deletions.")

    func status() async -> SourceStatus {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return SourceStatus(source: source, permission: .unavailable, indexedCount: 0, isIndexing: false, message: "Messages database was not found on this Mac.")
        }
        guard FileManager.default.isReadableFile(atPath: databaseURL.path) else {
            return SourceStatus(source: source, permission: .denied, indexedCount: 0, isIndexing: false, message: "Enable Full Disk Access for Local Digest to search Messages history.")
        }
        return SourceStatus(source: source, permission: .authorized, indexedCount: 0, isIndexing: false, message: "Read-only access through the local Messages database.")
    }

    func requestAccess() async -> SourceStatus { await status() }

    func fetchRecords() async throws -> [IndexedRecord] {
        try await fetchRecords(mode: .fullRebuild, cursor: nil).records
    }

    func fetchRecords(mode: IndexRefreshMode, cursor: SourceCursor?) async throws -> SourceFetchBatch {
        guard await status().permission == .authorized else { throw SourceAdapterError.permissionDenied(source, "Enable Full Disk Access for Local Digest in System Settings.") }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw SourceAdapterError.unavailable(source, "Messages database could not be opened.") }
        defer { sqlite3_close(database) }
        let includesAttributedBody = Self.hasColumn("attributedBody", in: database)
        let incrementalCursor = mode == .incremental ? cursor : nil
        let sql = Self.recordsQuery(includesAttributedBody: includesAttributedBody, cursor: incrementalCursor)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw SourceAdapterError.unavailable(source, "Messages database schema could not be read.") }
        defer { sqlite3_finalize(statement) }
        var records: [IndexedRecord] = []
        var highestRowID = incrementalCursor?.rowID ?? 0
        var highestRawDate = incrementalCursor?.rawWatermark ?? 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            let rawDate = sqlite3_column_double(statement, 8)
            highestRowID = max(highestRowID, rowID)
            highestRawDate = max(highestRawDate, rawDate)
            guard let guid = sqlite3_column_text(statement, 1) else { continue }
            let text = sqlite3_column_text(statement, 2).map(String.init(cString:))
            let attributedBody = Self.data(from: statement, column: 3)
            guard let body = Self.messageBody(text: text, attributedBody: attributedBody) else { continue }
            let handle = sqlite3_column_text(statement, 4).map(String.init(cString:))
            let isFromMe = sqlite3_column_int(statement, 5) != 0
            let author = isFromMe ? "Me" : handle
            let chatID = sqlite3_column_text(statement, 6).map(String.init(cString:))
            let participantHandles = sqlite3_column_text(statement, 7).map {
                String(cString: $0).split(separator: ",").map(String.init)
            } ?? []
            let timestamp = Self.messageDate(from: rawDate)
            let id = String(cString: guid)
            var participants = Set(participantHandles)
            if let handle { participants.insert(handle) }
            if let chatID { participants.insert(chatID) }
            if isFromMe { participants.insert("Me") }
            records.append(IndexedRecord(id: "message-\(id)", source: .messages, title: author ?? "Message", body: body, author: author, participants: participants.sorted(), timestamp: timestamp, url: nil, threadID: chatID))
        }
        let nextCursor: SourceCursor?
        if highestRowID > 0 {
            nextCursor = SourceCursor(
                watermark: Self.messageDate(from: highestRawDate),
                rawWatermark: highestRawDate,
                rowID: highestRowID,
                stableID: nil
            )
        } else {
            nextCursor = incrementalCursor
        }
        return SourceFetchBatch(
            records: Self.deduplicate(records),
            nextCursor: nextCursor,
            isCompleteSnapshot: mode == .fullRebuild || cursor == nil
        )
    }

    static func recordsQuery(includesAttributedBody: Bool, cursor: SourceCursor? = nil) -> String {
        let attributedBody = includesAttributedBody ? "message.attributedBody" : "NULL"
        let bodyPredicate = includesAttributedBody
            ? "(message.text IS NOT NULL AND message.text != '' OR message.attributedBody IS NOT NULL)"
            : "(message.text IS NOT NULL AND message.text != '')"
        let cursorPredicate: String
        if let cursor {
            let rowIDFloor = max(0, (cursor.rowID ?? 0) - 10_000)
            let rawOverlap: Double
            if let rawWatermark = cursor.rawWatermark {
                let unit = abs(rawWatermark) >= 10_000_000_000_000_000 ? 1_000_000_000.0
                    : abs(rawWatermark) >= 10_000_000_000_000 ? 1_000_000.0
                    : abs(rawWatermark) >= 10_000_000_000 ? 1_000.0
                    : 1.0
                rawOverlap = rawWatermark - (7 * 24 * 60 * 60 * unit)
            } else {
                rawOverlap = 0
            }
            cursorPredicate = " AND (message.ROWID >= \(rowIDFloor) OR message.date >= \(rawOverlap))"
        } else {
            cursorPredicate = ""
        }
        return """
        SELECT message.ROWID,
               message.guid,
               COALESCE(message.text, ''),
               \(attributedBody),
               COALESCE(handle.id, ''),
               COALESCE(message.is_from_me, 0),
               COALESCE(chat.chat_identifier, ''),
               COALESCE((
                   SELECT group_concat(DISTINCT participant_handle.id)
                   FROM chat_handle_join participant_join
                   JOIN handle participant_handle ON participant_handle.ROWID = participant_join.handle_id
                   WHERE participant_join.chat_id = chat.ROWID
               ), ''),
               message.date
        FROM message LEFT JOIN handle ON message.handle_id = handle.ROWID LEFT JOIN chat_message_join cmj ON cmj.message_id = message.ROWID LEFT JOIN chat ON chat.ROWID = cmj.chat_id
        WHERE \(bodyPredicate)\(cursorPredicate) ORDER BY message.date DESC;
        """
    }

    static func messageBody(text: String?, attributedBody: Data?) -> String? {
        if let text, !text.isEmpty, !isPlaceholderOnly(text) {
            // Keep text exactly as Messages supplied it, including valid
            // emoji-only messages and mixed text/object-replacement content.
            return text
        }
        guard let attributedBody,
              let object = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSAttributedString.self, NSString.self, NSArray.self, NSDictionary.self, NSNumber.self, NSData.self],
                from: attributedBody
              ),
              let decoded = textValue(from: object),
              !isPlaceholderOnly(decoded) else { return nil }
        return decoded
    }

    static func messageDate(from rawDate: Double) -> Date {
        // chat.db has used seconds, milliseconds, microseconds, and
        // nanoseconds relative to 2001-01-01 across OS generations. Choose
        // the unit by magnitude before constructing the Foundation date.
        let magnitude = abs(rawDate)
        let referenceInterval: Double
        switch magnitude {
        case 10_000_000_000_000_000...:
            referenceInterval = rawDate / 1_000_000_000
        case 10_000_000_000_000...:
            referenceInterval = rawDate / 1_000_000
        case 10_000_000_000...:
            referenceInterval = rawDate / 1_000
        default:
            referenceInterval = rawDate
        }
        return Date(timeIntervalSinceReferenceDate: referenceInterval)
    }

    static func isPlaceholderOnly(_ value: String) -> Bool {
        value.replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    static func deduplicate(_ records: [IndexedRecord]) -> [IndexedRecord] {
        var grouped: [String: IndexedRecord] = [:]
        for record in records.sorted(by: deterministicOrder) {
            guard let existing = grouped[record.id] else {
                grouped[record.id] = record
                continue
            }
            let participants = Set(existing.participants).union(record.participants).sorted()
            let threadID = [existing.threadID, record.threadID].compactMap { $0 }.sorted().first
            let body = existing.body.count >= record.body.count ? existing.body : record.body
            grouped[record.id] = IndexedRecord(
                id: existing.id,
                source: .messages,
                title: existing.title.isEmpty ? record.title : existing.title,
                body: body,
                author: existing.author ?? record.author,
                participants: participants,
                timestamp: min(existing.timestamp, record.timestamp),
                url: existing.url ?? record.url,
                threadID: threadID
            )
        }
        return grouped.values.sorted(by: deterministicOrder)
    }

    private static func textValue(from object: Any) -> String? {
        if let attributed = object as? NSAttributedString { return attributed.string }
        if let string = object as? NSString { return String(string) }
        if let values = object as? [Any] {
            return values.lazy.compactMap(textValue(from:)).first
        }
        if let values = object as? [AnyHashable: Any] {
            return values.values.lazy.compactMap(textValue(from:)).first
        }
        return nil
    }

    private static func data(from statement: OpaquePointer?, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func hasColumn(_ column: String, in database: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(message);", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    private static func deterministicOrder(_ lhs: IndexedRecord, _ rhs: IndexedRecord) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        return lhs.id < rhs.id
    }
}
