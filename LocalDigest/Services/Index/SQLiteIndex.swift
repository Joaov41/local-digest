import Foundation
import SQLite3

actor SQLiteIndex {
    private var database: OpaquePointer?
    private let databaseURL: URL
    /// Reads use an independent WAL connection. This keeps a query on the
    /// last committed snapshot while the writer replaces a source snapshot.
    nonisolated private let reader: SQLiteIndexReader

    init(databaseURL: URL? = nil) {
        let base = databaseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Local Digest", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        self.databaseURL = base
        self.reader = SQLiteIndexReader(databaseURL: base)
    }

    func open() throws {
        if database != nil { return }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            defer { if let handle { sqlite3_close(handle) } }
            throw IndexError.open(String(cString: sqlite3_errmsg(handle)))
        }
        database = handle
        try execute("PRAGMA journal_mode=WAL;")
        try execute("CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, source TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, author TEXT, participants TEXT NOT NULL, timestamp REAL NOT NULL, url TEXT, thread_id TEXT);")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(id UNINDEXED, title, body, author, participants, content='records', content_rowid='rowid');")
        try execute("CREATE TRIGGER IF NOT EXISTS records_ai AFTER INSERT ON records BEGIN INSERT INTO records_fts(rowid, id, title, body, author, participants) VALUES (new.rowid, new.id, new.title, new.body, new.author, new.participants); END;")
        try execute("CREATE TRIGGER IF NOT EXISTS records_ad AFTER DELETE ON records BEGIN INSERT INTO records_fts(records_fts, rowid, id, title, body, author, participants) VALUES('delete', old.rowid, old.id, old.title, old.body, old.author, old.participants); END;")
        try execute("CREATE TRIGGER IF NOT EXISTS records_au AFTER UPDATE ON records BEGIN INSERT INTO records_fts(records_fts, rowid, id, title, body, author, participants) VALUES('delete', old.rowid, old.id, old.title, old.body, old.author, old.participants); INSERT INTO records_fts(rowid, id, title, body, author, participants) VALUES (new.rowid, new.id, new.title, new.body, new.author, new.participants); END;")
    }

    /// Creates the schema before a refresh starts so a concurrent first query
    /// sees an empty, valid snapshot rather than a partially initialized file.
    func prepare() throws {
        try open()
    }

    func upsert(_ records: [IndexedRecord]) throws {
        try open()
        guard let database else { throw IndexError.open("Database unavailable") }
        try execute("BEGIN IMMEDIATE;")
        do {
            try insert(records, into: database)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Merges an incremental batch without deleting records that were not in
    /// the source's watermark window. The transaction still makes all writes
    /// visible atomically and keeps the FTS triggers in lockstep.
    func merge(source: SourceKind, with records: [IndexedRecord]) throws {
        guard records.allSatisfy({ $0.source == source }) else {
            throw IndexError.query("Incremental records do not belong to the requested source.")
        }
        try upsert(records)
    }

    /// Atomically replaces one source's complete snapshot. The caller must
    /// only invoke this after a successful full fetch; a failed or cancelled
    /// fetch therefore cannot erase the previous source data.
    func replace(source: SourceKind, with records: [IndexedRecord]) throws {
        guard records.allSatisfy({ $0.source == source }) else {
            throw IndexError.query("Snapshot records do not belong to the requested source.")
        }
        try open()
        guard let database else { throw IndexError.open("Database unavailable") }
        try execute("BEGIN IMMEDIATE;")
        do {
            try delete(source, from: database)
            try insert(records, into: database)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func insert(_ records: [IndexedRecord], into database: OpaquePointer) throws {
        for record in records {
            try insert(record, into: database)
        }
    }

    private func delete(_ source: SourceKind, from database: OpaquePointer) throws {
        let deleteSQL = "DELETE FROM records WHERE source = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, deleteSQL, -1, &statement, nil) == SQLITE_OK else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    private func insert(_ record: IndexedRecord, into database: OpaquePointer) throws {
        let sql = "INSERT INTO records(id, source, title, body, author, participants, timestamp, url, thread_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET source=excluded.source, title=excluded.title, body=excluded.body, author=excluded.author, participants=excluded.participants, timestamp=excluded.timestamp, url=excluded.url, thread_id=excluded.thread_id;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        bind(record.id, to: statement, index: 1)
        bind(record.source.rawValue, to: statement, index: 2)
        bind(record.title, to: statement, index: 3)
        bind(record.body, to: statement, index: 4)
        bind(record.author, to: statement, index: 5)
        bind(record.participants.joined(separator: "\u{1F}"), to: statement, index: 6)
        sqlite3_bind_double(statement, 7, record.timestamp.timeIntervalSince1970)
        bind(record.url?.absoluteString, to: statement, index: 8)
        bind(record.threadID, to: statement, index: 9)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    /// Reads intentionally bypass the writer actor. SQLite WAL gives each
    /// statement a stable view of the last committed generation while a
    /// replacement transaction is in progress.
    nonisolated func search(plan: QueryPlan, limit: Int = 60) async throws -> [SearchHit] {
        try await reader.search(plan: plan, limit: limit)
    }

    nonisolated func allPeople() async throws -> [String] {
        try await reader.allPeople()
    }

    nonisolated func identities() async throws -> [ContactIdentity] {
        try await reader.identities()
    }

    nonisolated func count(source: SourceKind) async throws -> Int {
        try await reader.count(source: source)
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw IndexError.open("Database unavailable") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errorMessage)
            throw IndexError.query(message)
        }
    }

    private func currentError() -> IndexError {
        guard let database else { return .query("SQLite error") }
        return .query(String(cString: sqlite3_errmsg(database)))
    }

    private func bind(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        if let value { sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func record(from statement: OpaquePointer?) -> IndexedRecord? {
        guard let statement,
              let id = sqlite3_column_text(statement, 0),
              let sourceRaw = sqlite3_column_text(statement, 1),
              let source = SourceKind(rawValue: String(cString: sourceRaw)),
              let title = sqlite3_column_text(statement, 2),
              let body = sqlite3_column_text(statement, 3) else { return nil }
        let author = sqlite3_column_text(statement, 4).map(String.init(cString:))
        let participants = sqlite3_column_text(statement, 5).map { String(cString: $0).split(separator: "\u{1F}").map(String.init) } ?? []
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        let url = sqlite3_column_text(statement, 7).flatMap { URL(string: String(cString: $0)) }
        let threadID = sqlite3_column_text(statement, 8).map(String.init(cString:))
        return IndexedRecord(id: String(cString: id), source: source, title: String(cString: title), body: String(cString: body), author: author, participants: participants, timestamp: timestamp, url: url, threadID: threadID)
    }
}

/// Dedicated read connection for the WAL-backed index. It never performs
/// schema or data writes and therefore cannot interrupt a source replacement.
private actor SQLiteIndexReader {
    private let databaseURL: URL
    private var database: OpaquePointer?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func search(plan: QueryPlan, limit: Int) throws -> [SearchHit] {
        guard let database = try openIfAvailable() else { return [] }
        let safeLimit = max(1, limit)
        let ftsQuery = makeFTSQuery(for: plan)
        let selectedSources = plan.constraints.sources.map(\.rawValue).sorted()
        guard !selectedSources.isEmpty else { return [] }
        let sourcePlaceholders = Array(repeating: "?", count: selectedSources.count).joined(separator: ",")
        var predicates = ["records.source IN (\(sourcePlaceholders))"]
        if ftsQuery != nil { predicates.insert("records_fts MATCH ?", at: 0) }
        if plan.constraints.startDate != nil { predicates.append("records.timestamp >= ?") }
        if plan.constraints.endDate != nil { predicates.append("records.timestamp < ?") }
        let join = ftsQuery == nil ? "" : "JOIN records_fts ON records_fts.rowid = records.rowid"
        let score = ftsQuery == nil ? "0.0" : "bm25(records_fts)"
        let ordering = ftsQuery == nil ? "records.timestamp DESC" : "bm25(records_fts) ASC, records.timestamp DESC"
        let sql = "SELECT records.id, records.source, records.title, records.body, records.author, records.participants, records.timestamp, records.url, records.thread_id, \(score) FROM records \(join) WHERE \(predicates.joined(separator: " AND ")) ORDER BY \(ordering) LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        var next: Int32 = 1
        if let ftsQuery { bind(ftsQuery, to: statement, index: next); next += 1 }
        for source in selectedSources {
            bind(source, to: statement, index: next)
            next += 1
        }
        if let startDate = plan.constraints.startDate {
            sqlite3_bind_double(statement, next, startDate.timeIntervalSince1970)
            next += 1
        }
        if let endDate = plan.constraints.endDate {
            sqlite3_bind_double(statement, next, endDate.timeIntervalSince1970)
            next += 1
        }
        sqlite3_bind_int(statement, next, Int32(max(safeLimit * 20, 5000)))

        var hits: [SearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let record = record(from: statement), matches(record, constraints: plan.constraints) else { continue }
            if plan.mode == .exactLookup, !plan.keywords.isEmpty {
                // Lookup/list questions must not surface records that only
                // matched a broad FTS branch. Every topic token must occur in
                // the title or body of the returned record.
                let searchable = record.searchableText
                guard plan.keywords.allSatisfy({ searchable.localizedCaseInsensitiveContains($0) }) else { continue }
            }
            let raw = sqlite3_column_double(statement, 9)
            let exactTitle = plan.mode == .exactLookup && plan.keywords.contains {
                record.title.localizedCaseInsensitiveCompare($0) == .orderedSame
            }
            let exactBody = plan.mode == .exactLookup && plan.keywords.contains {
                record.body.localizedCaseInsensitiveCompare($0) == .orderedSame
            }
            let exactBoost = exactTitle ? 1_000_000.0 : (exactBody ? 100_000.0 : 0.0)
            hits.append(SearchHit(
                record: record,
                score: exactBoost - raw,
                matchedSnippet: matchedSnippet(for: record, terms: plan.keywords)
            ))
        }
        let ranked = Array(hits.sorted {
            if $0.score == $1.score { return $0.record.timestamp > $1.record.timestamp }
            return $0.score > $1.score
        }.prefix(safeLimit))
        let titleExact = plan.mode == .exactLookup
            ? ranked.filter { record in
                let normalizedTitle = record.record.title
                    .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                    .joined(separator: " ")
                    .lowercased()
                let normalizedTopic = plan.keywords.joined(separator: " ").lowercased()
                return !normalizedTopic.isEmpty && normalizedTitle == normalizedTopic
            }
            : []
        let lookupRanked: [SearchHit]
        if plan.mode != .exactLookup {
            lookupRanked = ranked
        } else if plan.lookupScope == .title {
            lookupRanked = titleExact
        } else if plan.lookupScope == .topic, !titleExact.isEmpty {
            lookupRanked = titleExact
        } else {
            lookupRanked = ranked
        }
        guard plan.needsConversationExpansion else { return lookupRanked }
        return try expandConversation(from: lookupRanked, plan: plan, limit: safeLimit, database: database)
    }

    func allPeople() throws -> [String] {
        guard let database = try openIfAvailable() else { return [] }
        let sql = "SELECT DISTINCT author FROM records WHERE author IS NOT NULL AND author != '' ORDER BY author COLLATE NOCASE;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) {
            result.append(String(cString: value))
        }
        return result
    }

    func identities() throws -> [ContactIdentity] {
        guard let database = try openIfAvailable() else { return [] }
        let sql = "SELECT id, title, body, participants FROM records WHERE source = 'contacts' ORDER BY title COLLATE NOCASE;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        var result: [ContactIdentity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0),
                  let title = sqlite3_column_text(statement, 1) else { continue }
            let body = sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? ""
            let participants = sqlite3_column_text(statement, 3).map {
                String(cString: $0).split(separator: "\u{1F}").map(String.init)
            } ?? []
            result.append(ContactIdentity(
                id: String(cString: id),
                displayName: String(cString: title),
                aliases: body.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init),
                handles: participants
            ))
        }
        return result
    }

    func count(source: SourceKind) throws -> Int {
        guard let database = try openIfAvailable() else { return 0 }
        let sql = "SELECT COUNT(*) FROM records WHERE source = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func openIfAvailable() throws -> OpaquePointer? {
        if let database { return database }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            defer { if let handle { sqlite3_close(handle) } }
            throw IndexError.open(String(cString: sqlite3_errmsg(handle)))
        }
        database = handle
        return handle
    }

    private func expandConversation(from initialHits: [SearchHit], plan: QueryPlan, limit: Int, database: OpaquePointer) throws -> [SearchHit] {
        guard !initialHits.isEmpty else { return initialHits }
        let threadIDs = Array(Set(initialHits.compactMap(\.record.threadID))).prefix(12)
        guard !threadIDs.isEmpty else { return initialHits }

        let placeholders = Array(repeating: "?", count: threadIDs.count).joined(separator: ",")
        let expansionCap = max(limit, min(limit * 3, 180))
        let sql = "SELECT records.id, records.source, records.title, records.body, records.author, records.participants, records.timestamp, records.url, records.thread_id, 0.0 FROM records WHERE records.thread_id IN (\(placeholders)) ORDER BY records.timestamp DESC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        var next: Int32 = 1
        for threadID in threadIDs {
            bind(threadID, to: statement, index: next)
            next += 1
        }
        sqlite3_bind_int(statement, next, Int32(expansionCap))

        var combined = Dictionary(uniqueKeysWithValues: initialHits.map { ($0.record.id, $0) })
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let record = record(from: statement), matches(record, constraints: plan.constraints) else { continue }
            if combined[record.id] == nil {
                combined[record.id] = SearchHit(
                    record: record,
                    score: 0,
                    matchedSnippet: matchedSnippet(for: record, terms: plan.keywords)
                )
            }
        }
        return Array(combined.values.sorted {
            if $0.record.timestamp == $1.record.timestamp { return $0.record.id < $1.record.id }
            return $0.record.timestamp < $1.record.timestamp
        }.prefix(expansionCap))
    }

    private func makeFTSQuery(for plan: QueryPlan) -> String? {
        let rawTerms: [String] = (plan.keywords + plan.constraints.personTerms).compactMap { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let terms = rawTerms.reduce(into: [String]()) { result, term in
            if !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                result.append(term)
            }
        }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
    }

    private func matchedSnippet(for record: IndexedRecord, terms: [String]) -> String? {
        for content in [record.title, record.body] where !content.isEmpty {
            for term in terms {
                guard let range = content.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                let start = content.index(range.lowerBound, offsetBy: -80, limitedBy: content.startIndex) ?? content.startIndex
                let end = content.index(range.upperBound, offsetBy: 80, limitedBy: content.endIndex) ?? content.endIndex
                return content[start..<end]
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func matches(_ record: IndexedRecord, constraints: SearchConstraints) -> Bool {
        guard constraints.sources.contains(record.source) else { return false }
        if let start = constraints.startDate, record.timestamp < start { return false }
        if let end = constraints.endDate, record.timestamp >= end { return false }
        if !constraints.personTerms.isEmpty {
            let haystack = record.searchableText
            guard constraints.personTerms.contains(where: { haystack.localizedCaseInsensitiveContains($0) }) else { return false }
        }
        return true
    }

    private func record(from statement: OpaquePointer?) -> IndexedRecord? {
        guard let statement,
              let id = sqlite3_column_text(statement, 0),
              let sourceRaw = sqlite3_column_text(statement, 1),
              let source = SourceKind(rawValue: String(cString: sourceRaw)),
              let title = sqlite3_column_text(statement, 2),
              let body = sqlite3_column_text(statement, 3) else { return nil }
        let author = sqlite3_column_text(statement, 4).map(String.init(cString:))
        let participants = sqlite3_column_text(statement, 5).map {
            String(cString: $0).split(separator: "\u{1F}").map(String.init)
        } ?? []
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        let url = sqlite3_column_text(statement, 7).flatMap { URL(string: String(cString: $0)) }
        let threadID = sqlite3_column_text(statement, 8).map(String.init(cString:))
        return IndexedRecord(
            id: String(cString: id),
            source: source,
            title: String(cString: title),
            body: String(cString: body),
            author: author,
            participants: participants,
            timestamp: timestamp,
            url: url,
            threadID: threadID
        )
    }

    private func bind(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        if let value { sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func currentError() -> IndexError {
        guard let database else { return .query("SQLite error") }
        return .query(String(cString: sqlite3_errmsg(database)))
    }
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum IndexError: LocalizedError, Sendable {
    case open(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .open(let message), .query(let message): message
        }
    }
}
