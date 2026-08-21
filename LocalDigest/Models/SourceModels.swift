import Foundation

extension Date {
    var isUsableSourceDate: Bool {
        self != .distantPast && self != .distantFuture && timeIntervalSince1970 > -62_135_596_800
    }
}

enum SourceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case mail
    case messages
    case contacts
    case calendar
    case reminders
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mail: "Mail"
        case .messages: "Messages"
        case .contacts: "Contacts"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .notes: "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .mail: "envelope"
        case .messages: "message"
        case .contacts: "person.2"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .notes: "note.text"
        }
    }

    var refreshPolicyDescription: String {
        switch self {
        case .messages:
            "Incremental by ROWID/date with an overlap; Full Rebuild reconciles deletions."
        case .mail:
            "Incremental by received date with an overlap; Full Rebuild reconciles deletions and older edits."
        case .notes:
            "Incremental by modification date with an overlap; Full Rebuild reconciles deletions."
        case .contacts:
            "Full scan on Sync; use Full Rebuild when reconciling deletions."
        case .calendar:
            "Full scan on Sync; use Full Rebuild when reconciling deletions."
        case .reminders:
            "Full scan on Sync; use Full Rebuild when reconciling deletions."
        }
    }
}

enum SourcePermission: String, Codable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable

    var title: String {
        switch self {
        case .notDetermined: "Permission needed"
        case .authorized: "Available"
        case .denied: "Permission denied"
        case .restricted: "Restricted"
        case .unavailable: "Unavailable"
        }
    }
}

struct SourceStatus: Identifiable, Hashable, Sendable {
    let source: SourceKind
    var permission: SourcePermission
    var indexedCount: Int
    var isIndexing: Bool
    var message: String?
    var lastIndexedAt: Date? = nil

    var id: SourceKind { source }
}

struct IndexedRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let source: SourceKind
    let title: String
    let body: String
    let author: String?
    let participants: [String]
    let timestamp: Date
    let url: URL?
    let threadID: String?

    var searchableText: String {
        [title, body, author, participants.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
    }
}

struct Citation: Identifiable, Hashable, Sendable {
    let id: String
    let source: SourceKind
    let title: String
    let detail: String
    let timestamp: Date
    let url: URL?

    init(record: IndexedRecord) {
        id = record.id
        source = record.source
        title = record.title
        detail = record.author ?? record.source.title
        timestamp = record.timestamp
        url = record.url
    }
}

struct SearchConstraints: Equatable, Sendable {
    var person: String?
    var personTerms: [String]
    var startDate: Date?
    var endDate: Date?
    var sources: Set<SourceKind>

    static let unconstrained = SearchConstraints(person: nil, personTerms: [], startDate: nil, endDate: nil, sources: Set(SourceKind.allCases))
}

struct QueryPlan: Equatable, Sendable {
    let originalQuestion: String
    let keywords: [String]
    let constraints: SearchConstraints
    let needsConversationExpansion: Bool
    let ambiguity: [String]
    let intent: QueryIntent
    let mode: QueryMode
    let lookupScope: LookupScope

    init(
        originalQuestion: String,
        keywords: [String],
        constraints: SearchConstraints,
        needsConversationExpansion: Bool,
        ambiguity: [String],
        intent: QueryIntent = .inherited,
        mode: QueryMode = .questionAnswer,
        lookupScope: LookupScope = .topic
    ) {
        self.originalQuestion = originalQuestion
        self.keywords = keywords
        self.constraints = constraints
        self.needsConversationExpansion = needsConversationExpansion
        self.ambiguity = ambiguity
        self.intent = intent
        self.mode = mode
        self.lookupScope = lookupScope
    }

    var isConstrainedByDate: Bool { constraints.startDate != nil || constraints.endDate != nil }
    var hasExplicitIntentBoundary: Bool { intent.hasExplicitBoundary }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let record: IndexedRecord
    let score: Double
    let matchedSnippet: String?

    init(record: IndexedRecord, score: Double, matchedSnippet: String? = nil) {
        self.record = record
        self.score = score
        self.matchedSnippet = matchedSnippet
    }

    var id: String { record.id }
    var citation: Citation { Citation(record: record) }
}

struct Answer: Identifiable, Sendable {
    let id = UUID()
    var text: String
    var citations: [Citation]
    var provider: AIProvider
    var generatedAt = Date()
}

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case appleLocal
    case privateCloud

    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleLocal: "On-Device"
        case .privateCloud: "Private Cloud Compute"
        }
    }
    var symbol: String {
        switch self {
        case .appleLocal: "desktopcomputer"
        case .privateCloud: "lock.shield"
        }
    }

    var isSupportedOnCurrentOS: Bool {
        switch self {
        case .appleLocal:
            if #available(macOS 26.0, *) { true } else { false }
        case .privateCloud:
            if #available(macOS 27.0, *) { true } else { false }
        }
    }
}
