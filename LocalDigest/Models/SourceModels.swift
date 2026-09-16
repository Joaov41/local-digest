import Foundation

extension Date {
    var isUsableSourceDate: Bool {
        self != .distantPast && self != .distantFuture && timeIntervalSince1970 > -62_135_596_800
    }
}

enum AutoSyncInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    case off = 0
    case five = 5
    case fifteen = 15
    case thirty = 30
    case sixty = 60

    var id: Int { rawValue }

    init(minutes: Int) {
        self = AutoSyncInterval(rawValue: minutes) ?? .fifteen
    }

    var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    var title: String {
        switch self {
        case .off: "Off"
        case .five: "Every 5 minutes"
        case .fifteen: "Every 15 minutes"
        case .thirty: "Every 30 minutes"
        case .sixty: "Every hour"
        }
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

enum QueryOrdering: Equatable, Sendable {
    case relevance
    case newestFirst
    case upcomingFirst
}

enum QuerySurface: Equatable, Sendable {
    case ask
    case search
}

enum QueryRetrievalPolicy: Equatable, Sendable {
    /// Every keyword is a literal FTS search term.
    case literalKeywords
    /// Keywords describe a natural-language request but do not gate evidence
    /// inside the plan's validated person/date/source boundaries.
    case scopedSemanticEvidence
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
    let continuesConversation: Bool
    let ordering: QueryOrdering
    let requestedResultCount: Int?
    let retrievalPolicy: QueryRetrievalPolicy
    let surface: QuerySurface
    /// True when the user supplied a person-shaped phrase that did not resolve
    /// to a unique local identity. Ask must not use the remaining topic words
    /// to broaden that request into unrelated records.
    let hasUnresolvedPersonPhrase: Bool

    init(
        originalQuestion: String,
        keywords: [String],
        constraints: SearchConstraints,
        needsConversationExpansion: Bool,
        ambiguity: [String],
        intent: QueryIntent = .inherited,
        mode: QueryMode = .questionAnswer,
        lookupScope: LookupScope = .topic,
        continuesConversation: Bool = false,
        ordering: QueryOrdering = .relevance,
        requestedResultCount: Int? = nil,
        retrievalPolicy: QueryRetrievalPolicy = .literalKeywords,
        hasUnresolvedPersonPhrase: Bool = false,
        surface: QuerySurface = .ask
    ) {
        self.originalQuestion = originalQuestion
        self.keywords = keywords
        self.constraints = constraints
        self.needsConversationExpansion = needsConversationExpansion
        self.ambiguity = ambiguity
        self.intent = intent
        self.mode = mode
        self.lookupScope = lookupScope
        self.continuesConversation = continuesConversation
        self.ordering = ordering
        self.requestedResultCount = requestedResultCount.map { min(50, max(1, $0)) }
        self.retrievalPolicy = retrievalPolicy
        self.hasUnresolvedPersonPhrase = hasUnresolvedPersonPhrase
        self.surface = surface
    }

    var isConstrainedByDate: Bool { constraints.startDate != nil || constraints.endDate != nil }
    var hasExplicitIntentBoundary: Bool { intent.hasExplicitBoundary }
}

/// The deliberately small contract exchanged with the optional Apple model
/// before local planning.  It contains user-language intent only.  In
/// particular, handles, record identifiers, timestamps, and predicates are
/// not representable here and therefore cannot be emitted by the model.
struct StructuredQueryIntent: Equatable, Sendable {
    let sources: Set<SourceKind>?
    let personPhrase: String?
    let topicPhrase: String?
    let timeframePhrase: String?
    let requestedCount: Int?
    let ordering: QueryOrdering?
    let continuesConversation: Bool

    var person: String? { personPhrase }
    var topic: String? { topicPhrase }
    /// Tokenized topic language is derived locally after the model returns a
    /// bounded phrase. It is intentionally not a second model-controlled
    /// query field.
    var topicTerms: [String] { topicPhrase.map(IdentityResolver.tokens) ?? [] }
    var timeframe: String? { timeframePhrase }
    var timeframeIntent: String? { timeframePhrase }
    var count: Int? { requestedCount }
    var followUp: Bool { continuesConversation }

    init(
        sources: Set<SourceKind>? = nil,
        personPhrase: String? = nil,
        topicPhrase: String? = nil,
        timeframePhrase: String? = nil,
        requestedCount: Int? = nil,
        ordering: QueryOrdering? = nil,
        continuesConversation: Bool = false
    ) {
        self.sources = sources?.isEmpty == true ? nil : sources
        self.personPhrase = personPhrase
        self.topicPhrase = topicPhrase
        self.timeframePhrase = timeframePhrase
        self.requestedCount = requestedCount.map { min(50, max(1, $0)) }
        self.ordering = ordering
        self.continuesConversation = continuesConversation
    }

    /// Converts bounded Foundation Models fields into the local contract.
    /// Empty strings and zero are the model's omission values. Unknown enum
    /// values, oversized text, handles, SQL-like source names, and invalid
    /// counts reject the entire result rather than degrading into a broad
    /// search.
    init?(
        modelSources: String,
        modelPersonPhrase: String,
        modelTopicPhrase: String,
        modelTimeframePhrase: String,
        modelRequestedCount: Int,
        modelOrdering: String,
        continuesConversation: Bool
    ) {
        let sourceText = Self.trimmed(modelSources, maximumLength: 120)
        guard sourceText.valid else { return nil }
        let parsedSources: Set<SourceKind>?
        if sourceText.value.isEmpty {
            parsedSources = nil
        } else {
            let pieces = sourceText.value
                .split { $0 == "," || $0 == ";" || $0 == "|" || $0 == "/" }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard !pieces.isEmpty,
                  pieces.allSatisfy({ SourceKind(rawValue: $0) != nil }) else { return nil }
            parsedSources = Set(pieces.compactMap(SourceKind.init(rawValue:)))
        }

        let person = Self.trimmed(modelPersonPhrase, maximumLength: 120)
        let topic = Self.trimmed(modelTopicPhrase, maximumLength: 300)
        let timeframe = Self.trimmed(modelTimeframePhrase, maximumLength: 120)
        guard person.valid, topic.valid, timeframe.valid else { return nil }
        guard Self.isSafeLanguagePhrase(person.value),
              Self.isSafeLanguagePhrase(topic.value),
              Self.isSafeLanguagePhrase(timeframe.value) else { return nil }
        if !person.value.isEmpty {
            let digits = person.value.filter(\.isNumber)
            guard !person.value.contains("@"), digits.count < 7 else { return nil }
        }

        let parsedCount: Int?
        if modelRequestedCount == 0 {
            parsedCount = nil
        } else if (1...50).contains(modelRequestedCount) {
            parsedCount = modelRequestedCount
        } else {
            return nil
        }

        let orderingText = modelOrdering.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsedOrdering: QueryOrdering?
        switch orderingText {
        case "", "none", "relevance", "relevant": parsedOrdering = orderingText.isEmpty || orderingText == "none" ? nil : .relevance
        case "newest", "newestfirst", "newest first", "latest", "recent", "recently": parsedOrdering = .newestFirst
        case "upcoming", "upcomingfirst", "upcoming first", "next": parsedOrdering = .upcomingFirst
        default: return nil
        }

        self.init(
            sources: parsedSources,
            personPhrase: person.value.isEmpty ? nil : person.value,
            topicPhrase: topic.value.isEmpty ? nil : topic.value,
            timeframePhrase: timeframe.value.isEmpty ? nil : timeframe.value,
            requestedCount: parsedCount,
            ordering: parsedOrdering,
            continuesConversation: continuesConversation
        )
    }

    private static func trimmed(_ value: String, maximumLength: Int) -> (value: String, valid: Bool) {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.count <= maximumLength,
              !result.contains("\n"), !result.contains("\r") else { return ("", false) }
        return (result, true)
    }

    /// Model output is language only. Reject values that look like a query,
    /// an internal identifier, a timestamp, or a contact handle before they
    /// can reach the local merge step.
    private static func isSafeLanguagePhrase(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        guard !value.contains("@"),
              !value.contains("`"),
              !value.contains("="),
              !value.contains(";") else { return false }
        let lowered = value.lowercased()
        let words = lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let sqlWords = ["select", "insert", "update", "delete", "drop", "alter", "pragma", "union", "where", "join", "from"]
        guard !sqlWords.contains(where: words.contains) else { return false }
        guard lowered.range(of: #"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#, options: .regularExpression) == nil else { return false }
        // A date-only phrase is allowed (including day-first numeric dates),
        // while an ISO-like date plus clock is a forbidden timestamp.
        guard lowered.range(of: #"\b[0-9]{4}[-/.][0-9]{1,2}[-/.][0-9]{1,2}[t ][0-9]{1,2}:[0-9]{2}"#, options: .regularExpression) == nil else { return false }
        let digits = value.filter(\.isNumber)
        if digits.count >= 7 {
            let isNumericDate = lowered.range(of: #"^\s*[0-9]{1,4}[-/.][0-9]{1,2}[-/.][0-9]{1,4}\s*$"#, options: .regularExpression) != nil
            guard isNumericDate else { return false }
        }
        return true
    }

    /// Person phrases are copied from the user question rather than looked up
    /// from contacts or invented by the model. Topic/timeframe fields may be
    /// normalized language, but the person slot must remain literal.
    func personPhraseIsCopiedFrom(question: String) -> Bool {
        let normalizedQuestion = question.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let personPhrase, !personPhrase.isEmpty else { return true }
        return normalizedQuestion.localizedCaseInsensitiveContains(
            personPhrase.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        )
    }
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
